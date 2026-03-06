# Embeddings API (VPS)

Minimal Node service intended to run behind Caddy at `https://embeddings.shiro.codes`.

## Endpoints

- `GET /healthz` (no auth)
- `GET /v1/embeddings/:uid` (auth; self OR `instructor`/`admin` custom claim)
- `PUT /v1/embeddings/:uid` (auth; self OR `admin` custom claim)

## Auth

This verifies Firebase ID tokens using Google's public JWKS (no service-account JSON needed).

Set `FIREBASE_PROJECT_ID`.

## Storage

File-based JSON storage under `DATA_DIR` (default: `/var/lib/embeddings-api/data`).

## Local run

```bash
cd vps/embeddings-api
npm i
cp .env.example .env
# edit .env
export $(cat .env | xargs)
npm start
```

## VPS deploy (Ubuntu + systemd)

High-level steps (run on the VPS):

1. Copy this folder to `/opt/embeddings-api`
2. Install deps with `npm ci` or `npm i --omit=dev`
3. Create an `embeddings` user
4. Create `/etc/embeddings-api.env`
5. Install and start the systemd service from `deploy/embeddings-api.service`

See the assistant message in chat for exact commands.
