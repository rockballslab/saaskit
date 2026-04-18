---
name: saas-kit-stack
description: >
  Use this skill whenever working with the saas-kit self-hosted stack:
  n8n, Baserow, MinIO, PostgreSQL, Dragonfly, Redis, n8n-MCP.
  Triggers: any mention of these services by name, questions about containers,
  ports, credentials, inter-service connections, docker compose operations,
  debugging a saas-kit service, or building workflows that connect these tools.
  Also triggers for: "my stack", "the kit", "saas-kit", "my VPS services".
  DO NOT use for: generic Docker questions unrelated to this stack,
  vps-secure hardening, Caddy configuration outside of saas-kit context.
---

# saas-kit-stack — Skill

## Stack overview

Self-hosted SaaS stack installed by `setup.sh` on Ubuntu 24.04 LTS.
Reverse proxy: `vps-monitor-caddy` (network_mode:host) — NOT managed by this stack.
All containers on bridge network `saaskit-net`.
Kit root: `/opt/saas-kit/`
Credentials: `/etc/vps-secure/saas-kit.conf` (chmod 600)

## Services & ports

| Service | Container | Host binding | Internal |
|---|---|---|---|
| PostgreSQL 16 | `saaskit-postgres` | internal only | `postgres:5432` |
| Dragonfly | `saaskit-dragonfly` | internal only | `dragonfly:6379` |
| Redis 7 | `saaskit-redis` | internal only | `redis:6379` |
| n8n | `saaskit-n8n` | `127.0.0.1:5678` | `saaskit-n8n:5678` |
| n8n-MCP | `saaskit-n8n-mcp` | `127.0.0.1:5679` | `saaskit-n8n-mcp:3000` |
| Baserow | `saaskit-baserow` | `127.0.0.1:5680` | `saaskit-baserow:80` |
| MinIO API | `saaskit-minio` | `127.0.0.1:9000` | `saaskit-minio:9000` |
| MinIO Console | `saaskit-minio` | `127.0.0.1:9001` | `saaskit-minio:9001` |

## Inter-service connection patterns

### n8n → PostgreSQL
```
Host: postgres
Port: 5432
Database: n8n_db
User: saaskit
```

### n8n → Dragonfly (queue/cache)
```
Host: dragonfly
Port: 6379
No password (internal network only)
```

### n8n → MinIO (S3)
In n8n S3 credentials:
```
Endpoint: http://saaskit-minio:9000
Bucket: <your-bucket>
Access Key: admin
Secret Key: (read from /etc/vps-secure/saas-kit.conf → MINIO_PASSWORD)
Force path style: true
```

### n8n → Baserow (HTTP)
```
Base URL: http://saaskit-baserow:80
Auth: Baserow API token (generate in Baserow UI → Settings → API tokens)
```

### n8n-MCP → n8n
```
N8N_API_URL: http://saaskit-n8n:5678
N8N_API_KEY: (set via sudo saaskit-mcp-apikey.sh <key>)
```

### Baserow → PostgreSQL
```
DATABASE_URL: postgresql://saaskit:<password>@postgres:5432/baserow_db
```

### External app → MinIO (S3-compatible)
```
Endpoint: https://minio.<domain>
Port: 443 (via Caddy)
Access Key: admin
Secret Key: (from saas-kit.conf)
Force path style: true
SSL: true
```

## PostgreSQL — useful commands

```bash
# Connect to n8n database
docker exec -it saaskit-postgres psql -U saaskit -d n8n_db

# Connect to Baserow database
docker exec -it saaskit-postgres psql -U saaskit -d baserow_db

# List databases
docker exec -it saaskit-postgres psql -U saaskit -c "\l"

# Dump n8n database
docker exec saaskit-postgres pg_dump -U saaskit n8n_db > /opt/saas-kit/backup_n8n_$(date +%F).sql
```

## MinIO — useful commands

```bash
# List buckets
docker exec saaskit-minio mc ls local

# Create a bucket
docker exec saaskit-minio mc mb local/<bucket-name>

# Set bucket public read
docker exec saaskit-minio mc anonymous set download local/<bucket-name>

# Upload a file
docker exec saaskit-minio mc cp /path/to/file local/<bucket-name>/
```

## Docker compose operations

```bash
cd /opt/saas-kit

# Start all
docker compose --env-file .env up -d

# Stop all
docker compose down

# Restart one service
docker compose restart saaskit-n8n

# View logs
docker compose logs -f saaskit-n8n

# Check health
docker inspect --format='{{.State.Health.Status}}' saaskit-postgres
```

## Reading credentials safely

```bash
# Generic pattern
grep <KEY> /etc/vps-secure/saas-kit.conf | cut -d'"' -f2

# Examples
grep N8N_PASSWORD /etc/vps-secure/saas-kit.conf | cut -d'"' -f2
grep MINIO_PASSWORD /etc/vps-secure/saas-kit.conf | cut -d'"' -f2
grep POSTGRES_PASSWORD /etc/vps-secure/saas-kit.conf | cut -d'"' -f2
grep MCP_TOKEN /etc/vps-secure/saas-kit.conf | cut -d'"' -f2
```

## Known gotchas

- **Dragonfly ≠ Redis for Baserow** — Baserow uses Lua scripts, incompatible with Dragonfly. Baserow always points to `redis:6379`, never `dragonfly:6379`.
- **n8n-MCP needs a manual API key** — the container starts without `N8N_API_KEY`. Run `sudo saaskit-mcp-apikey.sh <key>` after generating a key in n8n UI.
- **MinIO path style** — always use `force path style: true` in S3 clients. MinIO does not support virtual-hosted-style by default in self-hosted mode.
- **Baserow admin account** — not created automatically. Must register manually at `https://baserow.<domain>` on first visit.
- **Caddy reload** — after any Caddyfile change: `docker exec vps-monitor-caddy caddy reload --config /etc/caddy/Caddyfile`
- **n8n volume permissions** — `/opt/saas-kit/data/n8n` must be owned by uid 1000. If n8n fails to start: `sudo chown -R 1000:1000 /opt/saas-kit/data/n8n`

## n8n templates

```
/opt/saas-kit/templates/awesome-n8n-templates/   # 100+ ready-to-import JSON workflows
/opt/saas-kit/templates/n8n-skills/              # Claude Code skillset for building n8n workflows
```

Import a workflow into n8n:
1. Go to `https://n8n.<domain>`
2. New workflow → ⋮ → Import from file
3. Select any `.json` from `awesome-n8n-templates/`
