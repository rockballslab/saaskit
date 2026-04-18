# SAASKIT

**One-script SaaS stack installer for self-hosted indie builders.**

> n8n · Baserow · MinIO · PostgreSQL · Dragonfly · Claude Code

Built on top of [vps-secure](https://github.com/rockballslab/vps-secure) — free, open source, and yours forever.

---

## Why self-host your SaaS stack?

Because the tools you already pay for every month have a free, production-grade, open-source equivalent — and they're better.

| You probably pay for... | Self-hosted with SAASKIT | Monthly savings |
|---|---|---|
| **Airtable** Pro ($20/user/mo) | **Baserow** — same no-code UX, unlimited rows, unlimited users | ~$60–200/mo |
| **n8n Cloud** Starter ($20/mo, 5k executions) | **n8n** self-hosted — unlimited executions, unlimited workflows | ~$20–50/mo |
| **AWS S3** (~$25/mo for 100GB + requests) | **MinIO** — S3-compatible, on your VPS, zero storage fees | ~$25/mo |
| **AWS RDS** PostgreSQL (db.t3.micro: ~$15/mo) | **PostgreSQL 16** — shared between all services | ~$15/mo |
| **Zapier** Pro ($49/mo) | Replaced by n8n self-hosted (see above) | — |
| **Make** Core ($9/mo) | Replaced by n8n self-hosted | — |

> [!IMPORTANT]
> **At current cloud pricing, this stack replaces $80 to $300/month of SaaS costs.** Your VPS costs $5–20/month. The math is obvious.

---

## What is SAASKIT?

A single bash script that installs, wires, and secures a complete self-hosted SaaS infrastructure on your VPS in under 15 minutes.

No Docker knowledge required. No manual config. One command.

```bash
sudo ./saaskit.sh install
```

You answer two questions (domain + email). Everything else is generated automatically — passwords, encryption keys, reverse proxy config, TLS certificates.

> [!NOTE]
> SAASKIT is designed to run **on top of vps-secure**. If your VPS is not hardened yet, start there first — it takes 15 minutes too. See [Prerequisites](#prerequisites).

---

## What you get

| Service | What it does | Open-source alternative to |
|---|---|---|
| **[n8n](https://n8n.io)** | Visual workflow automation — APIs, webhooks, AI agents | Zapier, Make, n8n Cloud |
| **[n8n-MCP](https://github.com/czlonkowski/n8n-mcp)** | MCP server — lets Claude control your n8n workflows | — |
| **[Baserow](https://baserow.io)** | No-code database with a spreadsheet-like UI | Airtable, Notion databases |
| **[MinIO](https://min.io)** | S3-compatible object storage — files, backups, assets | AWS S3, Cloudflare R2 |
| **[PostgreSQL 16](https://postgresql.org)** | Production-grade relational database, shared by all services | AWS RDS, Supabase |
| **[Dragonfly](https://dragonflydb.io)** | Redis-compatible cache, 25× faster than Redis | Redis Cloud |
| **[Redis 7](https://redis.io)** | Cache dedicated to Baserow | Redis Cloud |
| **[Claude Code](https://claude.ai/code)** | AI coding CLI, pre-connected to your stack via MCP | GitHub Copilot, Cursor |

**Bonus:** 100+ n8n workflow templates + the n8n-skills Claude Code skillset — cloned locally at install.

---

## Why n8n over Zapier or Make?

> [!TIP]
> **The killer feature of self-hosted n8n: unlimited executions.** Zapier Pro at $49/month gives you 2,000 tasks. n8n self-hosted gives you infinite — for the cost of your VPS.

- **Zapier** charges per *task* (each action in a workflow). A workflow with 5 steps that runs 1,000 times = 5,000 tasks. That's $50/month on the Pro plan.
- **Make** is cheaper but still caps by *operations* (each module execution).
- **n8n self-hosted** runs on your server. 10 million executions? Same cost.

n8n also has a built-in **AI Agent node** — you can wire Claude, GPT-4, or your local Ollama directly into your automations without a separate AI platform.

---

## Why Baserow over Airtable?

> [!TIP]
> **Airtable's free tier limits you to 1,200 rows per base.** A serious project hits that in a week. Baserow self-hosted has no row limit, no user limit, no base limit.

| Feature | Airtable Free | Airtable Pro ($20/user/mo) | Baserow self-hosted |
|---|---|---|---|
| Rows per base | 1,200 | 50,000 | **Unlimited** |
| Users | 5 | Unlimited | **Unlimited** |
| API access | ✅ | ✅ | ✅ |
| Automations | Limited | ✅ | ✅ |
| Monthly cost | $0 | $20/user | **$0** |
| Your data stays yours | ❌ | ❌ | **✅** |

Baserow uses a standard PostgreSQL backend — your data is in a real database you own and can query directly.

---

## Why MinIO over AWS S3?

AWS S3 looks cheap per GB ($0.023/GB/month) but the costs add up fast:
- Data transfer OUT: $0.09/GB
- PUT/GET requests: billed per 1,000 operations
- A media-heavy app can easily hit $50–100/month

MinIO on your VPS:
- **Storage**: unlimited (bound by your VPS disk)
- **Bandwidth**: included in your VPS plan
- **API**: 100% S3-compatible — any tool that works with S3 works with MinIO, zero code changes

> [!NOTE]
> Your existing AWS S3 code works with MinIO without modification. Change the endpoint URL and credentials in your `.env`. That's it.

---

## Prerequisites

### 1. Harden your VPS first with vps-secure

> [!IMPORTANT]
> **Do not expose this stack on a raw, unhardened VPS.** n8n, Baserow, and MinIO have web interfaces accessible from the internet. Before installing SAASKIT, your VPS needs:
> - A firewall (UFW configured)
> - SSH hardening (key-based auth, non-standard port)
> - Fail-safe Docker isolation
>
> **[vps-secure](https://github.com/rockballslab/vps-secure) handles all of this in 15 minutes.** It's the required foundation for SAASKIT.

```bash
# Step 1 — harden your VPS (takes ~15 min)
curl -fsSL https://raw.githubusercontent.com/rockballslab/vps-secure/main/install.sh -o install.sh
chmod +x install.sh && sudo ./install.sh

# Step 2 — install SAASKIT (takes ~5 min)
curl -fsSL https://raw.githubusercontent.com/rockballslab/SAASKIT/main/saaskit.sh -o saaskit.sh
chmod +x saaskit.sh && sudo ./saaskit.sh install
```

### 2. Server requirements

| Requirement | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| RAM | 8 GB | **16 GB** |
| Disk | 20 GB | 50 GB+ |
| CPU | 2 vCPU | 4 vCPU |

> [!NOTE]
> Tested on Hostinger KVM2 (16GB RAM, 8 vCPU, 200GB NVMe). Total install time: ~8 minutes.

### 3. DNS records (required before install)

Point all subdomains to your VPS IP **before** running the script. The installer checks DNS and will warn you if records are missing.

```
n8n.<yourdomain.com>           → YOUR_VPS_IP
mcpn8n.<yourdomain.com>        → YOUR_VPS_IP
baserow.<yourdomain.com>       → YOUR_VPS_IP
minio.<yourdomain.com>         → YOUR_VPS_IP
minio-console.<yourdomain.com> → YOUR_VPS_IP
listmonk.<yourdomain.com>      → YOUR_VPS_IP   # only if installing Listmonk
```

> [!TIP]
> DNS propagation takes 0–48 hours depending on your registrar. Most modern registrars (Cloudflare, Namecheap) propagate within 1–5 minutes.

---

## Install

```bash
# Download first — never pipe unknown scripts directly to bash
curl -fsSL https://raw.githubusercontent.com/rockballslab/SAASKIT/main/saaskit.sh -o saaskit.sh
chmod +x saaskit.sh
sudo ./saaskit.sh install
```

The script is **fully interactive**. It asks two questions:

```
  Domain root (ex: mydomain.com) : 
  Admin email                    : 
  Install Listmonk? (yes/no)     : 
```

Everything else is generated automatically — database passwords, encryption keys, MCP authentication token. All credentials are saved to `/etc/vps-secure/SAASKIT.conf` (readable only by root).

---

## What the script does — step by step

```
[1/9] Prerequisites    — detects Docker, reverse proxy mode (inject or standalone)
[2/9] Configuration    — prompts for domain + email, generates all secrets
[3/9] DNS check        — verifies all subdomains resolve to this VPS
[4/9] Environment      — creates /opt/SAASKIT/, .env (chmod 600), init SQL
[5/9] docker-compose   — generates compose file with pinned image versions
[6/9] Reverse proxy    — injects Caddy blocks (or creates standalone Caddyfile)
[7/9] Containers       — pulls images, starts services in dependency order
[8/9] n8n templates    — clones 100+ workflow templates + n8n-skills locally
[9/9] Claude Code CLI  — installs Node.js + @anthropic-ai/claude-code globally
```

> [!NOTE]
> **Reverse proxy detection is automatic.** If vps-secure is installed, SAASKIT injects its routes into the existing Caddy instance (no port 80/443 conflict). If no proxy is found, a standalone Caddy is created inside the stack. You don't need to configure anything.

> [!WARNING]
> The script creates and writes to `/opt/SAASKIT/`. If a previous installation is detected (`.env` exists), the script stops and asks you to run `update` or `uninstall` first. **It will not silently overwrite an existing installation.**

---

## Post-install (required steps)

### Step 1 — Configure n8n-MCP (required to use Claude with n8n)

```bash
# In the n8n UI: Settings → API → Create API Key
# Then:
sudo saaskit-mcp-apikey.sh <your-n8n-api-key>
```

### Step 2 — Create your Baserow admin account

Baserow does not auto-create accounts on first run. Open `https://baserow.<domain>` and register with your admin email.

### Step 3 — Verify all services

```bash
sudo ./saaskit.sh keys    # displays all URLs and credentials
```

> [!TIP]
> Bookmark `https://n8n.<domain>`, `https://baserow.<domain>`, and `https://minio-console.<domain>` immediately after install. Your credentials are in `/etc/vps-secure/SAASKIT.conf`.

---

## Connect Claude Desktop to your n8n via MCP

Once n8n-MCP is configured, add this to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "n8n-mcp": {
      "command": "npx",
      "args": ["n8n-mcp"],
      "env": {
        "MCP_MODE": "http",
        "MCP_SERVER_URL": "https://mcpn8n.<yourdomain.com>",
        "AUTH_TOKEN": "<your-mcp-token>",
        "LOG_LEVEL": "error"
      }
    }
  }
}
```

Your MCP token is in `/etc/vps-secure/SAASKIT.conf` → `MCP_TOKEN`.

> [!NOTE]
> With this setup, you can tell Claude: *"Create an n8n workflow that sends a Slack message when a new row is added to Baserow."* — Claude writes and deploys it directly via MCP. No copy-pasting, no JSON editing.

---

## Architecture

```
                       Internet
                          │
                   [Caddy / TLS]
              (vps-monitor-caddy or saaskit-caddy)
                          │
         ┌────────────────┼────────────────┐
         │                │                │
  127.0.0.1:5678   127.0.0.1:5680   127.0.0.1:9000
         │                │                │
    saaskit-n8n    saaskit-baserow    saaskit-minio
         │
  127.0.0.1:5679
         │
   saaskit-n8n-mcp
         │
         └────────────── saaskit-net (Docker bridge) ──────────────┐
                          │             │             │             │
                    saaskit-postgres  dragonfly    redis       (listmonk)
```

All SAASKIT containers communicate on `saaskit-net`. Only n8n, Baserow, MinIO API, MinIO Console, and n8n-MCP are reachable from outside — only on `127.0.0.1`, proxied through Caddy with automatic HTTPS.

---

## Commands

```bash
sudo ./saaskit.sh install             # install the full stack
sudo ./saaskit.sh keys                # display all URLs and credentials
sudo ./saaskit.sh backup              # full backup (PostgreSQL + volumes → MinIO)
sudo ./saaskit.sh backup --postgres   # PostgreSQL only
sudo ./saaskit.sh backup --volumes    # volumes only
sudo ./saaskit.sh backup --list       # list local backups
sudo ./saaskit.sh update              # update all Docker images
sudo ./saaskit.sh update n8n          # update a single service
sudo ./saaskit.sh update --check      # check available updates (dry run)
sudo ./saaskit.sh uninstall           # clean uninstall (asks confirmation)
```

### Docker commands

```bash
cd /opt/SAASKIT

docker compose ps                     # container status
docker compose logs -f n8n            # live logs for n8n
docker compose logs -f baserow        # live logs for Baserow
docker compose restart n8n            # restart a service
docker compose down && docker compose --env-file .env up -d  # full restart
```

---

## Backup

`saaskit.sh backup` does two things:

1. **PostgreSQL dump** — all databases (`n8n_db`, `baserow_db`, + `listmonk_db` if installed), compressed with gzip
2. **Volume backup** — n8n workflows + credentials, MinIO data

Backups are stored in `/opt/SAASKIT/backups/` and automatically uploaded to your MinIO internal bucket.

### External backup (optional)

For off-VPS backup (Backblaze B2, Hetzner S3, etc.), create `/opt/SAASKIT/backup-external.conf`:

```bash
BACKUP_EXTERNAL_ENDPOINT="https://s3.us-west-004.backblazeb2.com"
BACKUP_EXTERNAL_ACCESS_KEY="your-access-key"
BACKUP_EXTERNAL_SECRET_KEY="your-secret-key"
BACKUP_EXTERNAL_BUCKET="my-saaskit-backups"
```

> [!IMPORTANT]
> Backups older than 7 days are automatically deleted from the local `/opt/SAASKIT/backups/` directory. Configure an external destination if you need longer retention.

---

## n8n workflow templates

After install, two template collections are available locally:

```
/opt/SAASKIT/templates/awesome-n8n-templates/   # 100+ ready-to-import workflows
/opt/SAASKIT/templates/n8n-skills/              # Claude Code skillset for n8n
```

**Import a workflow:** n8n UI → New workflow → ⋮ menu → Import from file → pick any `.json`.

**Use n8n-skills with Claude Code:**
```bash
cat /opt/SAASKIT/templates/n8n-skills/SKILL.md
```

---

## Claude Code integration

This repo includes a `CLAUDE.md` (auto-loaded by Claude Code) and a skill at `.claude/skills/SAASKIT-stack/SKILL.md`.

The skill auto-triggers when Claude Code is working in this project and provides:
- Connection strings for all services
- PostgreSQL and MinIO quick commands
- Credential reading patterns
- Known gotchas (Dragonfly/Lua compatibility, n8n UID 1000, MinIO path-style S3...)

---

## Ports reference

| Service | Host binding | Port | Notes |
|---|---|---|---|
| n8n | 127.0.0.1 | 5678 | Proxied by Caddy |
| n8n-MCP | 127.0.0.1 | 5679 | Proxied by Caddy |
| Baserow | 127.0.0.1 | 5680 | Proxied by Caddy |
| MinIO API | 127.0.0.1 | 9000 | S3-compatible endpoint |
| MinIO Console | 127.0.0.1 | 9001 | Admin UI |
| Listmonk | 127.0.0.1 | 5682 | Optional, if installed |
| PostgreSQL | internal only | 5432 | Not exposed externally |
| Dragonfly | internal only | 6379 | Not exposed externally |
| Redis | internal only | 6379 | Not exposed externally |

> [!WARNING]
> No service is bound to `0.0.0.0`. Everything is either internal (`saaskit-net`) or bound to `127.0.0.1` and proxied by Caddy with TLS. **Never manually expose PostgreSQL, Dragonfly, or Redis on a public port.**

---

## Built with

- [vps-secure](https://github.com/rockballslab/vps-secure) — VPS hardening baseline (required)
- [n8n](https://n8n.io) — workflow automation platform
- [n8n-mcp](https://github.com/czlonkowski/n8n-mcp) — MCP server for n8n by @czlonkowski
- [Baserow](https://baserow.io) — open-source no-code database
- [MinIO](https://min.io) — S3-compatible object storage
- [PostgreSQL](https://postgresql.org) — relational database
- [DragonflyDB](https://dragonflydb.io) — Redis-compatible in-memory store
- [Caddy](https://caddyserver.com) — automatic HTTPS reverse proxy
- [awesome-n8n-templates](https://github.com/enescingoz/awesome-n8n-templates) — community workflow templates
- [n8n-skills](https://github.com/czlonkowski/n8n-skills) — Claude Code skillset for n8n

---

## License

MIT — use it, fork it, build on it.

---

*by [rockballslab](https://github.com/rockballslab)*
