import fs from 'node:fs/promises';
import path from 'node:path';

function safeUid(uid) {
  if (typeof uid !== 'string' || uid.length < 1 || uid.length > 128) {
    throw new Error('Invalid uid');
  }
  // Firebase uids are URL-safe-ish, but we still strictly whitelist.
  if (!/^[A-Za-z0-9_-]+$/.test(uid)) {
    throw new Error('Invalid uid');
  }
  return uid;
}

async function ensureDir(dir) {
  await fs.mkdir(dir, { recursive: true });
}

async function atomicWriteJson(filePath, json) {
  const dir = path.dirname(filePath);
  const tmpPath = path.join(dir, `.${path.basename(filePath)}.${process.pid}.${Date.now()}.tmp`);
  await fs.writeFile(tmpPath, JSON.stringify(json) + '\n', { encoding: 'utf8', mode: 0o600 });
  await fs.rename(tmpPath, filePath);
}

export function createStorage({ dataDir }) {
  if (!dataDir) throw new Error('DATA_DIR is required');

  async function getEmbedding(uid) {
    uid = safeUid(uid);
    const recordPath = path.join(dataDir, 'embeddings', `${uid}.json`);
    try {
      const raw = await fs.readFile(recordPath, 'utf8');
      return JSON.parse(raw);
    } catch (e) {
      if (e && (e.code === 'ENOENT' || e.code === 'ENOTDIR')) return null;
      throw e;
    }
  }

  async function putEmbedding(uid, record) {
    uid = safeUid(uid);
    const embeddingsDir = path.join(dataDir, 'embeddings');
    await ensureDir(embeddingsDir);
    const recordPath = path.join(embeddingsDir, `${uid}.json`);
    await atomicWriteJson(recordPath, record);
    return true;
  }

  return {
    getEmbedding,
    putEmbedding,
  };
}
