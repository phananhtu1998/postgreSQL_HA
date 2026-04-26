require("dotenv").config();

const express = require("express");
const { Pool } = require("pg");
const swaggerJSDoc = require("swagger-jsdoc");
const swaggerUi = require("swagger-ui-express");

const app = express();
const port = Number(process.env.API_PORT || 3001);

app.use(express.json());

const baseDbConfig = {
  host: process.env.DB_HOST || process.env.PGHOST || "localhost",
  port: Number(process.env.DB_PORT || process.env.PGBOUNCER_PORT || process.env.PGPORT || 6432),
  user: process.env.DB_USER || process.env.APP_DB_USER || "app_user",
  password: process.env.DB_PASSWORD || process.env.APP_DB_PASSWORD,
  max: Number(process.env.DB_POOL_MAX || 10),
  idleTimeoutMillis: Number(process.env.DB_IDLE_TIMEOUT_MS || 30000),
  connectionTimeoutMillis: Number(process.env.DB_CONNECTION_TIMEOUT_MS || 5000)
};

const appDbName = process.env.DB_NAME || process.env.APP_DB_NAME || "app_db";
const writePool = new Pool({
  ...baseDbConfig,
  database: process.env.DB_WRITE_NAME || `${appDbName}_rw`
});
const readPool = new Pool({
  ...baseDbConfig,
  database: process.env.DB_READ_NAME || `${appDbName}_ro`
});

const swaggerSpec = swaggerJSDoc({
  definition: {
    openapi: "3.0.0",
    info: {
      title: "PostgreSQL HA Express CRUD API",
      version: "1.0.0",
      description: "API doc cho thao tac doc, ghi, sua, xoa du lieu bang Express va PostgreSQL."
    },
    servers: [
      {
        url: `http://localhost:${port}`,
        description: "Local server"
      }
    ],
    components: {
      schemas: {
        Item: {
          type: "object",
          properties: {
            id: { type: "integer", example: 1 },
            name: { type: "string", example: "Demo item" },
            description: { type: "string", nullable: true, example: "Noi dung mo ta" },
            created_at: { type: "string", format: "date-time" },
            updated_at: { type: "string", format: "date-time" }
          }
        },
        ItemInput: {
          type: "object",
          required: ["name"],
          properties: {
            name: { type: "string", minLength: 1, example: "Demo item" },
            description: { type: "string", nullable: true, example: "Noi dung mo ta" }
          }
        },
        ItemPatch: {
          type: "object",
          properties: {
            name: { type: "string", minLength: 1, example: "Ten moi" },
            description: { type: "string", nullable: true, example: "Mo ta moi" }
          }
        },
        Error: {
          type: "object",
          properties: {
            error: { type: "string", example: "Item not found" }
          }
        }
      }
    }
  },
  apis: [__filename]
});

app.use("/api-docs", swaggerUi.serve, swaggerUi.setup(swaggerSpec));

async function initDb() {
  await writePool.query(`
    CREATE TABLE IF NOT EXISTS items (
      id SERIAL PRIMARY KEY,
      name VARCHAR(255) NOT NULL,
      description TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
}

function asyncHandler(handler) {
  return (req, res, next) => {
    Promise.resolve(handler(req, res, next)).catch(next);
  };
}

function validateItemInput(body, { partial = false } = {}) {
  const errors = [];
  const hasName = Object.prototype.hasOwnProperty.call(body, "name");
  const hasDescription = Object.prototype.hasOwnProperty.call(body, "description");

  if (!partial || hasName) {
    if (typeof body.name !== "string" || body.name.trim() === "") {
      errors.push("name is required and must be a non-empty string");
    }
  }

  if (hasDescription && body.description !== null && typeof body.description !== "string") {
    errors.push("description must be a string or null");
  }

  if (partial && !hasName && !hasDescription) {
    errors.push("at least one of name or description is required");
  }

  return errors;
}

function parseInteger(value, name, { min, max } = {}) {
  const parsed = Number(value);

  if (!Number.isInteger(parsed)) {
    const error = new Error(`${name} must be an integer`);
    error.status = 400;
    throw error;
  }

  if (min !== undefined && parsed < min) {
    const error = new Error(`${name} must be greater than or equal to ${min}`);
    error.status = 400;
    throw error;
  }

  if (max !== undefined && parsed > max) {
    const error = new Error(`${name} must be less than or equal to ${max}`);
    error.status = 400;
    throw error;
  }

  return parsed;
}

/**
 * @swagger
 * /health:
 *   get:
 *     summary: Kiem tra server va ket noi database
 *     responses:
 *       200:
 *         description: Server dang hoat dong
 */
app.get("/health", asyncHandler(async (_req, res) => {
  await Promise.all([
    writePool.query("SELECT 1"),
    readPool.query("SELECT 1")
  ]);
  res.json({
    status: "ok",
    writeDatabase: process.env.DB_WRITE_NAME || `${appDbName}_rw`,
    readDatabase: process.env.DB_READ_NAME || `${appDbName}_ro`
  });
}));

/**
 * @swagger
 * /items:
 *   get:
 *     summary: Lay danh sach item
 *     parameters:
 *       - in: query
 *         name: limit
 *         schema:
 *           type: integer
 *           default: 50
 *       - in: query
 *         name: offset
 *         schema:
 *           type: integer
 *           default: 0
 *     responses:
 *       200:
 *         description: Danh sach item
 *         content:
 *           application/json:
 *             schema:
 *               type: object
 *               properties:
 *                 data:
 *                   type: array
 *                   items:
 *                     $ref: '#/components/schemas/Item'
 */
app.get("/items", asyncHandler(async (req, res) => {
  const limit = parseInteger(req.query.limit || 50, "limit", { min: 1, max: 100 });
  const offset = parseInteger(req.query.offset || 0, "offset", { min: 0 });
  const result = await readPool.query(
    "SELECT id, name, description, created_at, updated_at FROM items ORDER BY id DESC LIMIT $1 OFFSET $2",
    [limit, offset]
  );

  res.json({ data: result.rows });
}));

/**
 * @swagger
 * /items/{id}:
 *   get:
 *     summary: Lay chi tiet item theo id
 *     parameters:
 *       - in: path
 *         name: id
 *         required: true
 *         schema:
 *           type: integer
 *     responses:
 *       200:
 *         description: Chi tiet item
 *         content:
 *           application/json:
 *             schema:
 *               $ref: '#/components/schemas/Item'
 *       404:
 *         description: Khong tim thay item
 */
app.get("/items/:id", asyncHandler(async (req, res) => {
  const id = parseInteger(req.params.id, "id", { min: 1 });
  const result = await readPool.query(
    "SELECT id, name, description, created_at, updated_at FROM items WHERE id = $1",
    [id]
  );

  if (result.rowCount === 0) {
    return res.status(404).json({ error: "Item not found" });
  }

  return res.json(result.rows[0]);
}));

/**
 * @swagger
 * /items:
 *   post:
 *     summary: Tao item moi
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             $ref: '#/components/schemas/ItemInput'
 *     responses:
 *       201:
 *         description: Item da tao
 */
app.post("/items", asyncHandler(async (req, res) => {
  const errors = validateItemInput(req.body);
  if (errors.length > 0) {
    return res.status(400).json({ error: errors.join(", ") });
  }

  const result = await writePool.query(
    `INSERT INTO items (name, description)
     VALUES ($1, $2)
     RETURNING id, name, description, created_at, updated_at`,
    [req.body.name.trim(), req.body.description ?? null]
  );

  return res.status(201).json(result.rows[0]);
}));

/**
 * @swagger
 * /items/{id}:
 *   put:
 *     summary: Cap nhat toan bo item
 *     parameters:
 *       - in: path
 *         name: id
 *         required: true
 *         schema:
 *           type: integer
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             $ref: '#/components/schemas/ItemInput'
 *     responses:
 *       200:
 *         description: Item da cap nhat
 *       404:
 *         description: Khong tim thay item
 */
app.put("/items/:id", asyncHandler(async (req, res) => {
  const id = parseInteger(req.params.id, "id", { min: 1 });
  const errors = validateItemInput(req.body);
  if (errors.length > 0) {
    return res.status(400).json({ error: errors.join(", ") });
  }

  const result = await writePool.query(
    `UPDATE items
     SET name = $1, description = $2, updated_at = NOW()
     WHERE id = $3
     RETURNING id, name, description, created_at, updated_at`,
    [req.body.name.trim(), req.body.description ?? null, id]
  );

  if (result.rowCount === 0) {
    return res.status(404).json({ error: "Item not found" });
  }

  return res.json(result.rows[0]);
}));

/**
 * @swagger
 * /items/{id}:
 *   patch:
 *     summary: Cap nhat mot phan item
 *     parameters:
 *       - in: path
 *         name: id
 *         required: true
 *         schema:
 *           type: integer
 *     requestBody:
 *       required: true
 *       content:
 *         application/json:
 *           schema:
 *             $ref: '#/components/schemas/ItemPatch'
 *     responses:
 *       200:
 *         description: Item da cap nhat
 *       404:
 *         description: Khong tim thay item
 */
app.patch("/items/:id", asyncHandler(async (req, res) => {
  const id = parseInteger(req.params.id, "id", { min: 1 });
  const errors = validateItemInput(req.body, { partial: true });
  if (errors.length > 0) {
    return res.status(400).json({ error: errors.join(", ") });
  }

  const result = await writePool.query(
    `UPDATE items
     SET
       name = COALESCE($1, name),
       description = CASE WHEN $2 THEN $3 ELSE description END,
       updated_at = NOW()
     WHERE id = $4
     RETURNING id, name, description, created_at, updated_at`,
    [
      typeof req.body.name === "string" ? req.body.name.trim() : null,
      Object.prototype.hasOwnProperty.call(req.body, "description"),
      req.body.description ?? null,
      id
    ]
  );

  if (result.rowCount === 0) {
    return res.status(404).json({ error: "Item not found" });
  }

  return res.json(result.rows[0]);
}));

/**
 * @swagger
 * /items/{id}:
 *   delete:
 *     summary: Xoa item theo id
 *     parameters:
 *       - in: path
 *         name: id
 *         required: true
 *         schema:
 *           type: integer
 *     responses:
 *       204:
 *         description: Xoa thanh cong
 *       404:
 *         description: Khong tim thay item
 */
app.delete("/items/:id", asyncHandler(async (req, res) => {
  const id = parseInteger(req.params.id, "id", { min: 1 });
  const result = await writePool.query("DELETE FROM items WHERE id = $1", [id]);

  if (result.rowCount === 0) {
    return res.status(404).json({ error: "Item not found" });
  }

  return res.status(204).send();
}));

app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(err.status || 500).json({ error: err.status ? err.message : "Internal server error" });
});

process.on("SIGINT", async () => {
  await Promise.all([writePool.end(), readPool.end()]);
  process.exit(0);
});

initDb()
  .then(() => {
    app.listen(port, () => {
      console.log(`API server listening on http://localhost:${port}`);
      console.log(`Swagger UI available at http://localhost:${port}/api-docs`);
    });
  })
  .catch((err) => {
    console.error("Failed to initialize database", err);
    process.exit(1);
  });
