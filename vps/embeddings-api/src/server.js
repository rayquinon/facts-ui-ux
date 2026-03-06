import http from 'node:http';
import { URL } from 'node:url';

import helmet from 'helmet';
import { z } from 'zod';

import { verifyFirebaseIdToken } from './firebase_verify.js';
import { createStorage } from './storage.js';

const env = {
  port: parseInt(process.env.PORT ?? '8080', 10),
  projectId: process.env.FIREBASE_PROJECT_ID ?? '',
  dataDir: process.env.DATA_DIR ?? '/var/lib/embeddings-api/data',
};

if (!Number.isFinite(env.port) || env.port < 1 || env.port > 65535) {
  throw new Error('Invalid PORT');
}

const storage = createStorage({ dataDir: env.dataDir });

const putBodySchema = z
  .object({
    embedding: z.array(z.number().finite()).min(1),
    model: z.string().min(1).optional(),
  })
  .strict();

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.statusCode = status;
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.setHeader('content-length', Buffer.byteLength(payload));
  res.end(payload);
}

function text(res, status, body) {
  res.statusCode = status;
  res.setHeader('content-type', 'text/plain; charset=utf-8');
  res.end(body);
}

async function readJsonBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw) return null;
  return JSON.parse(raw);
}

function getBearerToken(req) {
  const auth = req.headers.authorization;
  if (!auth) return null;
  const m = auth.match(/^Bearer\s+(.+)$/i);
  return m ? m[1] : null;
}

function hasRole(claims, role) {
  return claims && claims[role] === true;
}

async function requireAuth(req) {
  const token = getBearerToken(req);
  if (!token) {
    const err = new Error('Missing Authorization: Bearer <token>');
    err.status = 401;
    throw err;
  }

  try {
    return await verifyFirebaseIdToken(token, { projectId: env.projectId });
  } catch (e) {
    const err = new Error('Invalid or expired token');
    err.status = 401;
    err.cause = e;
    throw err;
  }
}

// Minimal middleware-like headers. (We use helmet for some defaults.)
const helmetMiddleware = helmet({
  contentSecurityPolicy: false,
});

const server = http.createServer(async (req, res) => {
  try {
    helmetMiddleware(req, res, () => undefined);

    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
    const pathname = url.pathname;

    // Public health check for systemd/Caddy.
    if ((req.method === 'GET' || req.method === 'HEAD') && pathname === '/healthz') {
      if (req.method === 'HEAD') {
        res.statusCode = 200;
        res.setHeader('content-type', 'application/json; charset=utf-8');
        res.setHeader('content-length', '0');
        return res.end();
      }
      return json(res, 200, { ok: true });
    }

    // Everything else requires auth.
    const auth = await requireAuth(req);

    // Simple routing: /v1/embeddings/:uid
    const match = pathname.match(/^\/v1\/embeddings\/([A-Za-z0-9_-]+)$/);
    if (match) {
      const targetUid = match[1];

      const isSelf = auth.uid === targetUid;
      const isInstructorOrAdmin = hasRole(auth.claims, 'instructor') || hasRole(auth.claims, 'admin');

      if (req.method === 'GET') {
        if (!isSelf && !isInstructorOrAdmin) {
          return json(res, 403, { error: 'forbidden' });
        }

        const record = await storage.getEmbedding(targetUid);
        if (!record) {
          return json(res, 404, { error: 'not_found' });
        }
        return json(res, 200, record);
      }

      if (req.method === 'PUT') {
        if (!isSelf && !hasRole(auth.claims, 'admin')) {
          return json(res, 403, { error: 'forbidden' });
        }

        const body = await readJsonBody(req);
        const parsed = putBodySchema.safeParse(body);
        if (!parsed.success) {
          return json(res, 400, { error: 'invalid_body', details: parsed.error.flatten() });
        }

        const record = {
          uid: targetUid,
          embedding: parsed.data.embedding,
          model: parsed.data.model ?? null,
          updatedAt: new Date().toISOString(),
          updatedBy: auth.uid,
        };

        await storage.putEmbedding(targetUid, record);
        return json(res, 200, { ok: true });
      }

      res.setHeader('allow', 'GET, PUT');
      return json(res, 405, { error: 'method_not_allowed' });
    }

    return json(res, 404, { error: 'not_found' });
  } catch (e) {
    const status = typeof e?.status === 'number' ? e.status : 500;
    if (status >= 500) {
      console.error('request error', e);
    }
    if (req.method === 'HEAD') return text(res, status, '');
    return json(res, status, { error: status === 500 ? 'internal' : 'unauthorized' });
  }
});

server.listen(env.port, '127.0.0.1', () => {
  console.log(`embeddings-api listening on http://127.0.0.1:${env.port}`);
  console.log(`FIREBASE_PROJECT_ID=${env.projectId || '(missing)'}`);
  console.log(`DATA_DIR=${env.dataDir}`);
});
