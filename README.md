# SAASKIT

**One-script SaaS stack installer for self-hosted indie builders.**

n8n · Baserow · MinIO · PostgreSQL · Dragonfly · Claude Code

Built on top of [vps-secure](https://github.com/rockballslab/vps-secure). Free and open source.

---

## What it installs

| Service | Role | URL |
|---|---|---|
| **n8n** | Workflow automation | `https://n8n.<domain>` |
| **n8n-MCP** | MCP server for Claude | `https://mcpn8n.<domain>` |
| **Baserow** | No-code database | `https://baserow.<domain>` |
| **MinIO** | S3-compatible object storage | `https://minio.<domain>` |
| **PostgreSQL 16** | Shared relational database | internal |
| **Dragonfly** | Redis-compatible cache (n8n) | internal |
| **Redis 7** | Cache dedicated to Baserow | internal |
| **Claude Code** | AI coding CLI | installed globally |

Plus **100+ n8n workflow templates** and the **n8n-skills** Claude Code skillset, cloned locally.

---

## Prerequisites

- Ubuntu 24.04 LTS VPS
- [vps-secure](https://github.com/rockballslab/vps-secure) installed (`install-secure.sh` + `install-dashboard.sh`)
- DNS A records pointing to your VPS for all subdomains:

```
n8n.<domain>          → VPS IP
mcpn8n.<domain>       → VPS IP
baserow.<domain>      → VPS IP
minio.<domain>        → VPS IP
minio-console.<domain> → VPS IP
```

- Minimum **8GB RAM** recommended (16GB comfortable)

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/rockballslab/saas-kit/main/setup.sh | sudo bash
```

Or clone and run:

```bash
git clone https://github.com/rockballslab/saas-kit.git
cd saas-kit
sudo ./setup.sh
```

The script is fully interactive. It will ask for:
- Your root domain (e.g. `mydomain.com`)
- Admin email
- Passwords for n8n, Baserow, MinIO (or auto-generate them)

Everything else (Postgres password, encryption keys, MCP token) is auto-generated.

---

## What the script does

```
[1/8] Configuration        — interactive prompts, generates all secrets
[2/8] DNS verification     — checks all subdomains resolve to this VPS
[3/8] Environment          — creates /opt/saas-kit/, .env, init SQL
[4/8] docker-compose.yml   — generates compose file from template
[5/8] Caddy                — injects reverse proxy blocks into vps-monitor Caddyfile
[6/8] Containers           — pulls images, starts services in dependency order
[7/8] n8n templates        — clones awesome-n8n-templates + n8n-skills
[8/8] Claude Code          — installs Node.js 22 + @anthropic/claude-code globally
```

All generated files land in `/opt/saas-kit/`. All credentials are saved to `/etc/vps-secure/saas-kit.conf` (chmod 600).

---

## Post-install (required)

### 1. Configure n8n-MCP API key

n8n-MCP needs a key to communicate with n8n. Generate one in the n8n UI, then:

```bash
# In n8n: Settings → API → Create API Key
sudo saaskit-mcp-apikey.sh <your-api-key>
```

### 2. Create Baserow admin account

Baserow does not auto-create accounts. Go to `https://baserow.<domain>` and register with your admin email.

### 3. Verify MinIO

Go to `https://minio-console.<domain>` and log in with `admin` / your MinIO password.

---

## Connect Claude Desktop to n8n-MCP

Add to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "n8n-mcp": {
      "command": "npx",
      "args": ["n8n-mcp"],
      "env": {
        "MCP_MODE": "http",
        "N8N_API_URL": "https://mcpn8n.<domain>",
        "AUTH_TOKEN": "<your-mcp-token>",
        "LOG_LEVEL": "error"
      }
    }
  }
}
```

MCP token is in `/etc/vps-secure/saas-kit.conf`.

---

## Architecture

```
                    Internet
                       │
              vps-monitor-caddy
              (network_mode:host)
                       │
        ┌──────────────┼──────────────┐
        │              │              │
   127.0.0.1:5678  127.0.0.1:5680  127.0.0.1:9000
        │              │              │
    saaskit-n8n   saaskit-baserow  saaskit-minio
        │              │
        └──────┬────────┘
               │  saaskit-net (bridge)
        ┌──────┼──────┐
        │      │      │
   postgres  dragonfly  redis
```

All saas-kit containers communicate internally on `saaskit-net`. Only n8n, Baserow, MinIO, and n8n-MCP are exposed on `127.0.0.1` for Caddy to proxy.

---

## Useful commands

```bash
cd /opt/saas-kit

# Status
docker compose ps

# Logs
docker compose logs -f n8n
docker compose logs -f baserow

# Restart a service
docker compose restart n8n

# Full restart
docker compose down && docker compose --env-file .env up -d

# Read credentials
grep N8N_PASSWORD /etc/vps-secure/saas-kit.conf | cut -d'"' -f2

# Reconfigure n8n-MCP after API key change
sudo saaskit-mcp-apikey.sh <new-key>
```

---

## n8n templates

After install, two template collections are available locally:

```
/opt/saas-kit/templates/awesome-n8n-templates/   # 100+ workflow JSON files
/opt/saas-kit/templates/n8n-skills/              # Claude Code skillset for n8n
```

Import a workflow: n8n UI → New workflow → ⋮ → Import from file.

To use n8n-skills with Claude Code, point to the skill:
```bash
cat /opt/saas-kit/templates/n8n-skills/SKILL.md
```

---

## Claude Code integration

This repo includes a `CLAUDE.md` (loaded automatically by Claude Code) and a skill at `.claude/skills/saas-kit-stack/SKILL.md`.

The skill auto-triggers when working with any saas-kit service and provides:
- Inter-service connection strings
- PostgreSQL and MinIO commands
- Credential reading patterns
- Known gotchas (Dragonfly/Lua, n8n uid, MinIO path style...)

---

## Stack ports reference

| Service | Host port | Notes |
|---|---|---|
| n8n | 5678 | Official n8n port |
| n8n-MCP | 5679 | |
| Baserow | 5680 | |
| MinIO API | 9000 | Standard S3 port |
| MinIO Console | 9001 | Standard MinIO console port |
| PostgreSQL | internal | Container name: `postgres` |
| Dragonfly | internal | Container name: `dragonfly` |
| Redis | internal | Container name: `redis` |

---

## Built with

- [vps-secure](https://github.com/rockballslab/vps-secure) — VPS hardening baseline
- [n8n](https://n8n.io) — workflow automation
- [n8n-mcp](https://github.com/czlonkowski/n8n-mcp) — MCP server by czlonkowski
- [Baserow](https://baserow.io) — open source no-code database
- [MinIO](https://min.io) — S3-compatible object storage
- [PostgreSQL](https://postgresql.org) — relational database
- [DragonflyDB](https://dragonflydb.io) — Redis-compatible cache
- [Caddy](https://caddyserver.com) — reverse proxy (via vps-secure)
- [awesome-n8n-templates](https://github.com/enescingoz/awesome-n8n-templates) — n8n workflow templates
- [n8n-skills](https://github.com/czlonkowski/n8n-skills) — Claude Code skillset for n8n

---

## License

MIT — use it, fork it, build on it.

---

*by [rockballslab](https://github.com/rockballslab)*
