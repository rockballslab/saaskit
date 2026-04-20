#!/usr/bin/env bash
# ============================================================
# saaskit.sh — saas-kit · Stack SaaS self-hosted
#
# Usage :
#   sudo ./saaskit.sh install    — installe la stack complète
#   sudo ./saaskit.sh backup     — sauvegarde PostgreSQL + volumes
#   sudo ./saaskit.sh update     — met à jour les images Docker
#   sudo ./saaskit.sh uninstall  — désinstalle proprement
#   sudo ./saaskit.sh keys       — affiche tous les credentials
#
# Prérequis :
#   - Ubuntu 24.04 LTS + vps-secure installé (Docker, UFW)
#   - DNS configurés pour tous les sous-domaines
#   - Reverse proxy : vps-monitor-caddy détecté auto (inject)
#                     ou Caddy standalone créé automatiquement
#
# ATTENTION : télécharger d'abord, ne pas lancer en curl|bash :
#   curl -fsSL https://raw.githubusercontent.com/rockballslab/saas-kit/main/saaskit.sh -o saaskit.sh
#   chmod +x saaskit.sh && sudo ./saaskit.sh install
# ============================================================
set -euo pipefail

_cleanup() {
    local exit_code=$?
    [[ $exit_code -ne 0 ]] && \
        echo -e "\n\033[1;33m[WARN]  Script interrompu — vérifie l'état du serveur.\033[0m" >&2
}
trap _cleanup EXIT
unset HISTFILE
# FIX S7 : PATH explicite — prévient le hijacking depuis cron/env non standard
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ============================================================
# Couleurs et log
# ============================================================
ROUGE='\033[0;31m'
VERT='\033[0;32m'
JAUNE='\033[1;33m'
BLANC='\033[0;37m'
GRAS='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLANC}[INFO]  $*${RESET}"; }
log_success() { echo -e "${VERT}[OK]    $*${RESET}"; }
log_warn()    { echo -e "${JAUNE}[WARN]  $*${RESET}"; }
log_error()   { echo -e "${ROUGE}[ERR]   $*${RESET}" >&2; }

etape() {
    local num="$1" total="$2" label="$3"
    echo -e "\n${GRAS}${VERT}[$num/$total] $label${RESET}"
    echo -e "${VERT}$(printf '=%.0s' {1..60})${RESET}"
}

# ============================================================
# Constantes globales
# ============================================================
KIT_DIR="/opt/saas-kit"
DATA_DIR="/opt/saas-kit/data"
BACKUP_DIR="/opt/saas-kit/backups"
CONF="/etc/vps-secure/saas-kit.conf"
CADDYFILE="/home/vpsadmin/vps-monitor/Caddyfile"   # défaut — surchargé par detect_reverse_proxy
CADDY_CONTAINER="vps-monitor-caddy"                 # défaut — surchargé par detect_reverse_proxy
CADDY_MODE=""                                        # "inject"|"standalone" — défini par detect_reverse_proxy
ADMIN_USER="${SUDO_USER:-vpsadmin}"

PORT_N8N=5678
PORT_MCP=5679
PORT_BASEROW=5680
PORT_MINIO_API=9000
PORT_MINIO_CONSOLE=9001

PORT_LOGTO=3001
PORT_LOGTO_ADMIN=3002
PORT_TTS=5683
PORT_UPTIME=5684

# ============================================================
# Vérification root
# ============================================================
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Ce script doit être lancé en ROOT (sudo)."
        exit 1
    fi
}

# ============================================================
# ARCH1 — Détection automatique du reverse proxy
# Priorité 1 : vps-monitor-caddy  → mode inject
# Priorité 2 : autre Caddy/443    → mode inject
# Fallback   : aucun proxy        → mode standalone (saaskit-caddy créé)
# ============================================================
detect_reverse_proxy() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^vps-monitor-caddy$"; then
        CADDY_MODE="inject"
        CADDY_CONTAINER="vps-monitor-caddy"
        CADDYFILE="/home/vpsadmin/vps-monitor/Caddyfile"
        log_success "Reverse proxy détecté : vps-monitor-caddy (mode injection)"
        return
    fi

    local other_caddy=""
    while IFS= read -r cname; do
        if docker inspect --format \
            '{{range $p, $c := .HostConfig.PortBindings}}{{$p}} {{end}}' \
            "$cname" 2>/dev/null | grep -qE "(^| )443/tcp( |$)"; then
            other_caddy="$cname"; break
        fi
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)

    if [[ -n "$other_caddy" ]]; then
        local other_cf
        other_cf=$(docker inspect "$other_caddy" \
            --format '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null || echo "")
        if [[ -n "$other_cf" && -f "$other_cf" ]]; then
            CADDY_MODE="inject"
            CADDY_CONTAINER="$other_caddy"
            CADDYFILE="$other_cf"
            log_success "Reverse proxy détecté : $other_caddy (mode injection)"
            return
        fi
    fi

    CADDY_MODE="standalone"
    CADDY_CONTAINER="saaskit-caddy"
    CADDYFILE="${KIT_DIR}/Caddyfile"
    log_warn "Aucun reverse proxy détecté — Caddy standalone sera créé dans saaskit."
}

# ============================================================
# Utilitaire : attendre qu'un container soit healthy
# M4 FIX : déplacé au top-level (était redéfini à chaque appel cmd_update)
# Usage : _wait_healthy <container_name> [timeout_secondes]
# ============================================================
_wait_healthy() {
    local ctn="$1" timeout="${2:-60}" i=0
    local has_health
    has_health=$(docker inspect --format='{{if .State.Health}}yes{{end}}' "$ctn" 2>/dev/null || echo "")
    [[ -z "$has_health" ]] && { sleep 3; return 0; }
    while [[ $i -lt $timeout ]]; do
        local s; s=$(docker inspect --format='{{.State.Health.Status}}' "$ctn" 2>/dev/null || echo "starting")
        [[ "$s" == "healthy" ]] && return 0
        sleep 1; i=$((i+1))
    done
    log_warn "$ctn pas encore healthy après ${timeout}s."
}

# ============================================================
# Banner
# ============================================================
banner() {
    echo -e "${VERT}"
cat << 'EOF'
  ███████╗ █████╗  █████╗ ███████╗    ██╗  ██╗██╗████████╗
  ██╔════╝██╔══██╗██╔══██╗██╔════╝    ██║ ██╔╝██║╚══██╔══╝
  ███████╗███████║███████║███████╗    █████╔╝ ██║   ██║
  ╚════██║██╔══██║██╔══██║╚════██║    ██╔═██╗ ██║   ██║
  ███████║██║  ██║██║  ██║███████║    ██║  ██╗██║   ██║
  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝   ╚═╝  ╚═╝╚═╝   ╚═╝
EOF
    echo -e "${RESET}"
    echo -e "${BLANC}  n8n · Baserow · MinIO · PostgreSQL · Dragonfly · Claude Code${RESET}"
    echo -e "${BLANC}  github.com/rockballslab/saas-kit${RESET}"
    echo -e "${VERT}$(printf '=%.0s' {1..60})${RESET}\n"
}

# ============================================================
# COMMANDE : install
# ============================================================
# ============================================================
# Sous-fonctions de cmd_install (C1 — découpage monolithe)
# ============================================================

_install_check_prereqs() {
    if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
        log_warn "Ubuntu 24.04 recommandé. Autre version détectée."
        read -rp "  Continuer quand même ? (oui/non) : " _ans
        [[ "$_ans" == "oui" ]] || exit 1
    fi
    if ! command -v docker &>/dev/null; then
        log_error "Docker non trouvé — lance d'abord vps-secure."; exit 1
    fi
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose v2 non trouvé — lance d'abord vps-secure."; exit 1
    fi

    # ARCH1 : détection automatique du reverse proxy
    detect_reverse_proxy

    command -v git &>/dev/null || apt-get install -y git -qq
    command -v dig &>/dev/null || apt-get install -y dnsutils -qq
    log_success "Prérequis OK."

    # ── Étape 1 : Configuration ──────────────────────────────
}

_install_gather_config() {
    etape "1" "$TOTAL_ETAPES" "Configuration"
    echo -e "${BLANC}  Deux informations suffisent — tout le reste est généré automatiquement.${RESET}\n"

    read -rp "  Domaine racine (ex: mondomaine.com) : " ROOT_DOMAIN
    [[ -z "$ROOT_DOMAIN" ]] && { log_error "Domaine obligatoire."; exit 1; }
    # E4 FIX : whitelist stricte — bloque $(), backticks, espaces, et autres injecteurs
    # avant leur usage dans les heredocs non-quotés ci-dessous
    [[ ! "$ROOT_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]] && \
        { log_error "Domaine invalide — seuls alphanum, tirets et points autorisés."; exit 1; }

    read -rp "  Email admin : " ADMIN_EMAIL
    [[ ! "$ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && { log_error "Email invalide."; exit 1; }

    echo ""
    read -rp "  Installer Pocket TTS (synthèse vocale locale, optionnel) ? (oui/non) : " INSTALL_TTS
    INSTALL_TTS="${INSTALL_TTS:-non}"

    if [[ "$INSTALL_TTS" == "oui" ]]; then
        read -rp "  HuggingFace token (requis pour Pocket TTS, voir hf.co/settings/tokens) : " HF_TOKEN
        [[ -z "$HF_TOKEN" ]] && { log_error "HF_TOKEN obligatoire pour Pocket TTS."; exit 1; }
    else
        HF_TOKEN=""
    fi

    log_info "Génération des secrets..."
    # E2 FIX : base64 48 → ~36 alphanum après tr-dc → head -c 20 toujours satisfait
    N8N_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 20)
    BASEROW_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 20)
    MINIO_PASSWORD=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 20)
    POSTGRES_PASSWORD=$(openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c 32)
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
    MCP_TOKEN=$(openssl rand -hex 32)
    BASEROW_SECRET_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 50)

    N8N_DOMAIN="n8n.${ROOT_DOMAIN}"
    MCP_DOMAIN="mcpn8n.${ROOT_DOMAIN}"
    BASEROW_DOMAIN="baserow.${ROOT_DOMAIN}"
    MINIO_DOMAIN="minio.${ROOT_DOMAIN}"
    MINIO_CONSOLE_DOMAIN="minio-console.${ROOT_DOMAIN}"
    LOGTO_DOMAIN="auth.${ROOT_DOMAIN}"
    LOGTO_ADMIN_DOMAIN="auth-admin.${ROOT_DOMAIN}"
    TTS_DOMAIN="tts.${ROOT_DOMAIN}"
    UPTIME_DOMAIN="status.${ROOT_DOMAIN}"

    echo ""
    log_info "Sous-domaines qui seront configurés :"
    for d in "$N8N_DOMAIN" "$MCP_DOMAIN" "$BASEROW_DOMAIN" "$MINIO_DOMAIN" \
              "$MINIO_CONSOLE_DOMAIN" "$LOGTO_DOMAIN" "$UPTIME_DOMAIN"; do
        echo -e "  ${BLANC}$d${RESET}"
    done
    [[ "$INSTALL_TTS" == "oui" ]] && echo -e "  ${BLANC}$TTS_DOMAIN${RESET}"
    echo ""
    log_warn "Logto (auth OIDC) et Uptime Kuma (monitoring) sont installés automatiquement."
    log_warn "Pocket TTS : $([ "$INSTALL_TTS" == "oui" ] && echo "OUI" || echo "non")"
    log_success "Secrets générés."

    # ── Étape 2 : DNS ────────────────────────────────────────
}

_install_check_dns() {
    etape "2" "$TOTAL_ETAPES" "Vérification DNS"

    # FIX W8 : fallback si ip route échoue
    VPS_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    [[ -z "$VPS_IP" ]] && VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$VPS_IP" ]] && VPS_IP="<IP inconnue>"
    log_info "IP VPS détectée : $VPS_IP"

    local DOMAINS_TO_CHECK=("$N8N_DOMAIN" "$MCP_DOMAIN" "$BASEROW_DOMAIN" "$MINIO_DOMAIN" \
                             "$MINIO_CONSOLE_DOMAIN" "$LOGTO_DOMAIN" "$UPTIME_DOMAIN")
    [[ "$INSTALL_TTS" == "oui" ]] && DOMAINS_TO_CHECK+=("$TTS_DOMAIN")

    local DNS_OK=true
    for domain in "${DOMAINS_TO_CHECK[@]}"; do
        local resolved
        resolved=$(dig +short "$domain" 2>/dev/null | tail -1 || echo "")
        if [[ "$resolved" == "$VPS_IP" ]]; then
            log_success "$domain => $VPS_IP"
        else
            log_warn "$domain => '${resolved:-non résolu}' (attendu : $VPS_IP)"
            DNS_OK=false
        fi
    done

    if [[ "$DNS_OK" == "false" ]]; then
        log_warn "Certains DNS ne pointent pas encore vers ce VPS."
        read -rp "  Continuer quand même ? (oui/non) : " dns_answer
        [[ "$dns_answer" == "oui" ]] || exit 1
    else
        log_success "Tous les DNS sont correctement configurés."
    fi

    # ── Étape 3 : Répertoires ────────────────────────────────
}

_install_create_env() {
    etape "3" "$TOTAL_ETAPES" "Création de l'environnement"

    mkdir -p "$KIT_DIR"
    mkdir -p "$DATA_DIR/postgres" "$DATA_DIR/dragonfly" "$DATA_DIR/redis" \
             "$DATA_DIR/n8n" "$DATA_DIR/baserow" "$DATA_DIR/minio" \
             "$DATA_DIR/logto" "$DATA_DIR/tts" \
             "$DATA_DIR/uptime-kuma" \
             "$KIT_DIR/templates" "$KIT_DIR/initdb"

    if [[ -d "$DATA_DIR/postgres/global" ]]; then
        log_warn "Données PostgreSQL existantes — le script SQL init NE sera PAS réexécuté."
        read -rp "  Continuer ? (oui/non) : " _pg_ans
        [[ "$_pg_ans" == "oui" ]] || exit 1
    fi

    chown -R 1000:1000 "$DATA_DIR/n8n" 2>/dev/null || true
    # FIX W2 : vérifier que ADMIN_USER existe avant chown
    if id "$ADMIN_USER" &>/dev/null; then
        chown -R "$ADMIN_USER:$ADMIN_USER" "$KIT_DIR" 2>/dev/null || true
    else
        log_warn "Utilisateur '$ADMIN_USER' non trouvé — chown KIT_DIR ignoré."
    fi
    log_success "Répertoires créés dans $KIT_DIR"

    # FIX S1 : écriture .env avec umask restrictif dans sous-shell
    (
        umask 077
        cat > "$KIT_DIR/.env" << ENV
# saas-kit — généré le $(date '+%Y-%m-%d %H:%M:%S') — NE PAS COMMITTER
ROOT_DOMAIN=${ROOT_DOMAIN}
N8N_DOMAIN=${N8N_DOMAIN}
MCP_DOMAIN=${MCP_DOMAIN}
BASEROW_DOMAIN=${BASEROW_DOMAIN}
MINIO_DOMAIN=${MINIO_DOMAIN}
MINIO_CONSOLE_DOMAIN=${MINIO_CONSOLE_DOMAIN}
LOGTO_DOMAIN=${LOGTO_DOMAIN}
LOGTO_ADMIN_DOMAIN=${LOGTO_ADMIN_DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}
POSTGRES_USER=saaskit
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres
N8N_PASSWORD=${N8N_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
MCP_TOKEN=${MCP_TOKEN}
N8N_API_KEY=
BASEROW_PASSWORD=${BASEROW_PASSWORD}
BASEROW_SECRET_KEY=${BASEROW_SECRET_KEY}
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=${MINIO_PASSWORD}
PORT_LOGTO=${PORT_LOGTO}
PORT_LOGTO_ADMIN=${PORT_LOGTO_ADMIN}
INSTALL_TTS=${INSTALL_TTS}
HF_TOKEN=${HF_TOKEN}
TTS_DOMAIN=${TTS_DOMAIN}
PORT_TTS=${PORT_TTS}
UPTIME_DOMAIN=${UPTIME_DOMAIN}
PORT_UPTIME=${PORT_UPTIME}
KIT_DIR=${KIT_DIR}
DATA_DIR=${DATA_DIR}
ENV
    )
    chmod 600 "$KIT_DIR/.env"
    log_success ".env généré : $KIT_DIR/.env"

    cat > "$KIT_DIR/initdb/01-create-databases.sql" << 'SQL'
CREATE DATABASE n8n_db;       GRANT ALL PRIVILEGES ON DATABASE n8n_db       TO saaskit;
CREATE DATABASE baserow_db;   GRANT ALL PRIVILEGES ON DATABASE baserow_db   TO saaskit;
CREATE DATABASE logto_db;     GRANT ALL PRIVILEGES ON DATABASE logto_db     TO saaskit;
SQL
    log_success "Script SQL init généré."

    # ── Étape 4 : docker-compose.yml ─────────────────────────
}

_install_generate_compose() {
    etape "4" "$TOTAL_ETAPES" "Génération docker-compose.yml"

    # Logto — toujours installé
    local LOGTO_SERVICE="
  logto:
    image: svhd/logto:1.38.0
    container_name: saaskit-logto
    restart: unless-stopped
    entrypoint: /bin/sh
    command:
      - -c
      - 'npm run cli db seed -- --swe 2>/dev/null; npm start'
    ports:
      - \"127.0.0.1:${PORT_LOGTO}:3001\"
      - \"127.0.0.1:${PORT_LOGTO_ADMIN}:3002\"
    environment:
      TRUST_PROXY_HEADER: 1
      DB_URL: postgresql://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@postgres:5432/logto_db
      ENDPOINT: https://\${LOGTO_DOMAIN}
      ADMIN_ENDPOINT: http://127.0.0.1:${PORT_LOGTO_ADMIN}
    volumes:
      - ${DATA_DIR}/logto:/etc/logto/packages/core/connectors
    networks:
      - saaskit-net
    depends_on:
      postgres:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    healthcheck:
      test: [\"CMD-SHELL\", \"wget --quiet --tries=1 --spider http://localhost:3001/api/status || exit 1\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    logging:
      options: {max-size: \"10m\", max-file: \"3\"}"

    # Pocket TTS — optionnel
    local TTS_SERVICE="  # Pocket TTS non installé"
    if [[ "$INSTALL_TTS" == "oui" ]]; then
        TTS_SERVICE="
  tts:
    image: ghcr.io/kyutai-labs/pocket-tts:v1.1.1
    container_name: saaskit-tts
    restart: unless-stopped
    ports:
      - \"127.0.0.1:${PORT_TTS}:8000\"
    command: [\"pocket-tts\", \"serve\", \"--host\", \"0.0.0.0\", \"--port\", \"8000\"]
    environment:
      HF_TOKEN: \${HF_TOKEN}
      HF_HOME: /data/hf-cache
    volumes:
      - ${DATA_DIR}/tts:/data
    networks:
      - saaskit-net
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    healthcheck:
      test: [\"CMD-SHELL\", \"wget --quiet --tries=1 --spider http://localhost:8000/health || exit 1\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    logging:
      options: {max-size: \"10m\", max-file: \"3\"}"
    fi

    # Uptime Kuma — toujours installé
    local UPTIME_SERVICE="
  uptime-kuma:
    image: louislam/uptime-kuma:2.2.1    # FIX S— : SSTI GHSA-v832-4r73-wx5j (Mar 2026)
    container_name: saaskit-uptime-kuma
    restart: unless-stopped
    ports:
      - \"127.0.0.1:${PORT_UPTIME}:3001\"
    volumes:
      - ${DATA_DIR}/uptime-kuma:/app/data
    networks:
      - saaskit-net
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    healthcheck:
      test: [\"CMD-SHELL\", \"wget --quiet --tries=1 --spider http://localhost:3001/ || exit 1\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      options: {max-size: \"10m\", max-file: \"3\"}"

    # ARCH1 : bloc Caddy conditionnel (standalone uniquement)
    local CADDY_SVC_BLOCK=""
    local COMPOSE_NOTE="# Caddy NON inclus — ${CADDY_CONTAINER} est utilisé comme proxy"
    if [[ "$CADDY_MODE" == "standalone" ]]; then
        mkdir -p "$DATA_DIR/caddy/data" "$DATA_DIR/caddy/config"
        COMPOSE_NOTE="# STANDALONE : Caddy inclus (aucun reverse proxy externe détecté)"
        CADDY_SVC_BLOCK="
  # ARCH1 — Caddy standalone (créé car aucun proxy externe détecté)
  caddy:
    image: caddy:2.11.2-alpine
    container_name: saaskit-caddy
    restart: unless-stopped
    ports:
      - \"80:80\"
      - \"443:443\"
      - \"443:443/udp\"
    volumes:
      - ${KIT_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${DATA_DIR}/caddy/data:/data
      - ${DATA_DIR}/caddy/config:/config
    networks:
      - saaskit-net
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    logging:
      options: {max-size: \"10m\", max-file: \"3\"}"
    fi

    cat > "$KIT_DIR/docker-compose.yml" << COMPOSE
# saas-kit — docker-compose.yml — généré par saaskit.sh
${COMPOSE_NOTE}

services:

  postgres:
    image: postgres:16-alpine
    container_name: saaskit-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - ${DATA_DIR}/postgres:/var/lib/postgresql/data
      - ${KIT_DIR}/initdb:/docker-entrypoint-initdb.d:ro
    networks:
      - saaskit-net
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      options: {max-size: "10m", max-file: "3"}

  dragonfly:
    image: docker.dragonflydb.io/dragonflydb/dragonfly:v1.38.0
    container_name: saaskit-dragonfly
    restart: unless-stopped
    ulimits:
      memlock: -1
    volumes:
      - ${DATA_DIR}/dragonfly:/data
    networks:
      - saaskit-net
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -p 6379 ping || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      options: {max-size: "10m", max-file: "3"}

  redis:
    image: redis:7-alpine
    container_name: saaskit-redis
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ${DATA_DIR}/redis:/data
    networks:
      - saaskit-net
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      options: {max-size: "10m", max-file: "3"}

  # n8n — automation workflows (FIX B5 : auth via N8N_DEFAULT_USER_*)
  n8n:
    image: docker.n8n.io/n8nio/n8n:2.16.1
    container_name: saaskit-n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_N8N}:5678"
    environment:
      N8N_HOST: \${N8N_DOMAIN}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://\${N8N_DOMAIN}/
      N8N_DEFAULT_USER_EMAIL: \${ADMIN_EMAIL}
      N8N_DEFAULT_USER_PASSWORD: \${N8N_PASSWORD}
      N8N_USER_MANAGEMENT_JWT_SECRET: \${N8N_ENCRYPTION_KEY}
      N8N_ENCRYPTION_KEY: \${N8N_ENCRYPTION_KEY}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: n8n_db
      DB_POSTGRESDB_USER: \${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: \${POSTGRES_PASSWORD}
      QUEUE_BULL_REDIS_HOST: dragonfly
      QUEUE_BULL_REDIS_PORT: 6379
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_VERSION_NOTIFICATIONS_ENABLED: "false"
      N8N_TEMPLATES_ENABLED: "true"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: 168
      TZ: Europe/Paris
    volumes:
      - ${DATA_DIR}/n8n:/home/node/.n8n
    networks:
      - saaskit-net
    depends_on:
      postgres:
        condition: service_healthy
      dragonfly:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      options: {max-size: "10m", max-file: "3"}

  # n8n-MCP — MCP server pour Claude (FIX B6 : N8N_API_KEY via saaskit-mcp-apikey.sh)
  # C2 TODO : pinner ce tag dès qu'une release stable est taguée sur ghcr.io/czlonkowski/n8n-mcp
  n8n-mcp:
    image: ghcr.io/czlonkowski/n8n-mcp:latest
    container_name: saaskit-n8n-mcp
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_MCP}:3000"
    environment:
      MCP_MODE: http
      PORT: 3000
      AUTH_TOKEN: \${MCP_TOKEN}
      N8N_API_URL: http://saaskit-n8n:5678
      N8N_API_KEY: \${N8N_API_KEY:-}
      LOG_LEVEL: error
      DISABLE_CONSOLE_OUTPUT: "true"
    networks:
      - saaskit-net
    depends_on:
      n8n:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:3000/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    logging:
      options: {max-size: "10m", max-file: "3"}

  baserow:
    image: baserow/baserow:2.2.0
    container_name: saaskit-baserow
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT_BASEROW}:80"
    environment:
      BASEROW_PUBLIC_URL: https://\${BASEROW_DOMAIN}
      DATABASE_URL: postgresql://\${POSTGRES_USER}:\${POSTGRES_PASSWORD}@postgres:5432/baserow_db
      REDIS_URL: redis://redis:6379
      SECRET_KEY: \${BASEROW_SECRET_KEY}
      BASEROW_AMOUNT_OF_WORKERS: 2
      MEDIA_URL: https://\${BASEROW_DOMAIN}/media/
      BASEROW_EXTRA_ALLOWED_HOSTS: \${BASEROW_DOMAIN}
    volumes:
      - ${DATA_DIR}/baserow:/baserow/data
    networks:
      - saaskit-net
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:80/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    logging:
      options: {max-size: "10m", max-file: "3"}

  # MinIO — FIX S6 : CVE-2025-62506 patchée, FIX B4 : healthcheck HTTP
  # E1 FIX : alpine/minio non officiel (maintenu par un particulier) — migré sur quay.io/minio/minio
  minio:
      image: quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z.hotfix.7aa24e772
    container_name: saaskit-minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    ports:
      - "127.0.0.1:${PORT_MINIO_API}:9000"
      - "127.0.0.1:${PORT_MINIO_CONSOLE}:9001"
    environment:
      MINIO_ROOT_USER: \${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: \${MINIO_ROOT_PASSWORD}
      MINIO_BROWSER_REDIRECT_URL: https://\${MINIO_CONSOLE_DOMAIN}
    volumes:
      - ${DATA_DIR}/minio:/data
    networks:
      - saaskit-net
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9000/minio/health/live || wget -qO /dev/null http://localhost:9000/minio/health/live 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    logging:
      options: {max-size: "10m", max-file: "3"}

${CADDY_SVC_BLOCK}

${LOGTO_SERVICE}

${TTS_SERVICE}

${UPTIME_SERVICE}

networks:
  saaskit-net:
    name: saaskit-net
    driver: bridge
COMPOSE
    log_success "docker-compose.yml généré."

    # ── Étape 5 : Configuration reverse proxy ─────────────────
}

_install_configure_proxy() {
    etape "5" "$TOTAL_ETAPES" "Configuration reverse proxy (mode: ${CADDY_MODE})"

    if [[ "$CADDY_MODE" == "inject" ]]; then
        # ── Mode INJECT : injection dans Caddy externe ─────────────────────────

        # FIX S4 : vérification CVE-2026-30851 Caddy < 2.11.2
        local caddy_ver
        caddy_ver=$(docker exec "$CADDY_CONTAINER" caddy version 2>/dev/null \
            | grep -oP 'v\K[\d.]+' | head -1 || echo "0.0.0")
        if ! printf '%s\n%s\n' "2.11.2" "$caddy_ver" | sort -V -C 2>/dev/null; then
            log_warn "Caddy ${caddy_ver} < 2.11.2 — CVE-2026-30851 (auth bypass CVSS 8.1)."
            read -rp "  Continuer quand même ? (oui/non) : " _caddy_ans
            [[ "$_caddy_ans" == "oui" ]] || exit 1
        fi

        local CADDYFILE_BACKUP="${CADDYFILE}.backup.$(date '+%Y%m%d-%H%M%S')"
        cp "$CADDYFILE" "$CADDYFILE_BACKUP"
        log_success "Backup Caddyfile : $CADDYFILE_BACKUP"

        if grep -q "saas-kit — n8n" "$CADDYFILE" 2>/dev/null; then
            log_warn "Blocs saas-kit déjà présents — injection ignorée."
        else
            local TTS_CADDY_BLOCK=""
            if [[ "$INSTALL_TTS" == "oui" ]]; then
                TTS_CADDY_BLOCK="
# ── saas-kit — Pocket TTS ────────────────────────────────────────────────────
${TTS_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_TTS} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header { Strict-Transport-Security \"max-age=31536000\"; -Server }
}"
            fi

            # FIX B7/B8 : heredoc non-quoté + placeholders Caddy escapés avec \{
            cat >> "$CADDYFILE" << CADDYBLOCKS

# ── saas-kit — n8n ───────────────────────────────────────────────────────────
${N8N_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_N8N} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Frame-Options "SAMEORIGIN"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "no-referrer"
    -Server
  }
}

# ── saas-kit — n8n-MCP ───────────────────────────────────────────────────────
${MCP_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_MCP} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header { Strict-Transport-Security "max-age=31536000"; X-Content-Type-Options "nosniff"; -Server }
}

# ── saas-kit — Baserow ───────────────────────────────────────────────────────
${BASEROW_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_BASEROW} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header { Strict-Transport-Security "max-age=31536000"; X-Frame-Options "SAMEORIGIN"; -Server }
}

# ── saas-kit — MinIO API ─────────────────────────────────────────────────────
${MINIO_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_MINIO_API} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header { -Server }
}

# ── saas-kit — MinIO Console ─────────────────────────────────────────────────
${MINIO_CONSOLE_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_MINIO_CONSOLE} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header { Strict-Transport-Security "max-age=31536000"; X-Frame-Options "SAMEORIGIN"; -Server }
}

# ── saas-kit — Logto (auth OIDC) ─────────────────────────────────────────────
${LOGTO_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_LOGTO} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header { Strict-Transport-Security "max-age=31536000"; X-Frame-Options "SAMEORIGIN"; -Server }
}

# ── saas-kit — Uptime Kuma (status) ──────────────────────────────────────────
${UPTIME_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_UPTIME} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header { Strict-Transport-Security "max-age=31536000"; X-Frame-Options "SAMEORIGIN"; -Server }
}

${TTS_CADDY_BLOCK}
CADDYBLOCKS
            log_success "Blocs saas-kit injectés dans $CADDYFILE"

            if ! docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
                log_error "Caddyfile invalide ! Restauration backup..."
                cp "$CADDYFILE_BACKUP" "$CADDYFILE"
                exit 1
            fi
        fi

        log_info "Rechargement de Caddy..."
        if docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
            log_success "Caddy rechargé."
        elif docker restart "$CADDY_CONTAINER" 2>/dev/null; then
            log_warn "Reload échoué — Caddy redémarre (attente 5s)..."; sleep 5
            log_success "Caddy redémarré."
        else
            log_warn "Restart Caddy manuel requis : docker restart $CADDY_CONTAINER"
        fi

    else
        # ── Mode STANDALONE : Caddyfile complet pour saaskit-caddy ────────────
        # Caddy dans saaskit-net → reverse_proxy via noms Docker (pas 127.0.0.1)
        log_info "Génération du Caddyfile standalone..."

        cat > "$CADDYFILE" << CADDYSTANDALONE
# saas-kit — Caddyfile standalone — généré le $(date '+%Y-%m-%d %H:%M:%S')
# saaskit-caddy dans saaskit-net — proxy via noms Docker

# ── saas-kit — n8n ───────────────────────────────────────────────────────────
${N8N_DOMAIN} {
  reverse_proxy saaskit-n8n:5678
  header { Strict-Transport-Security "max-age=31536000; includeSubDomains"; X-Frame-Options "SAMEORIGIN"; -Server }
}

# ── saas-kit — n8n-MCP ───────────────────────────────────────────────────────
${MCP_DOMAIN} {
  reverse_proxy saaskit-n8n-mcp:3000
  header { Strict-Transport-Security "max-age=31536000"; -Server }
}

# ── saas-kit — Baserow ───────────────────────────────────────────────────────
${BASEROW_DOMAIN} {
  reverse_proxy saaskit-baserow:80
  header { Strict-Transport-Security "max-age=31536000"; X-Frame-Options "SAMEORIGIN"; -Server }
}

# ── saas-kit — MinIO API ─────────────────────────────────────────────────────
${MINIO_DOMAIN} {
  reverse_proxy saaskit-minio:9000
  header { -Server }
}

# ── saas-kit — MinIO Console ─────────────────────────────────────────────────
${MINIO_CONSOLE_DOMAIN} {
  reverse_proxy saaskit-minio:9001
  header { Strict-Transport-Security "max-age=31536000"; X-Frame-Options "SAMEORIGIN"; -Server }
}

# ── saas-kit — Logto (auth OIDC) ─────────────────────────────────────────────
${LOGTO_DOMAIN} {
  reverse_proxy saaskit-logto:3001
  header { Strict-Transport-Security "max-age=31536000"; X-Frame-Options "SAMEORIGIN"; -Server }
}

# ── saas-kit — Uptime Kuma (status) ──────────────────────────────────────────
${UPTIME_DOMAIN} {
  reverse_proxy saaskit-uptime-kuma:3001
  header { Strict-Transport-Security "max-age=31536000"; X-Frame-Options "SAMEORIGIN"; -Server }
}
CADDYSTANDALONE

        if [[ "$INSTALL_TTS" == "oui" ]]; then
            cat >> "$CADDYFILE" << CADDYTTS

# ── saas-kit — Pocket TTS ───────────────────────────────────────────────────
${TTS_DOMAIN} {
  reverse_proxy saaskit-tts:8000
  header { Strict-Transport-Security "max-age=31536000"; -Server }
}
CADDYTTS
        fi

        log_success "Caddyfile standalone généré : $CADDYFILE"
        log_info "saaskit-caddy démarrera avec les autres services à l'étape 6."
    fi

    # ── Étape 6 : Démarrage containers ───────────────────────
}

_install_start_containers() {
    etape "6" "$TOTAL_ETAPES" "Démarrage des containers"

    cd "$KIT_DIR"

    if docker compose ps -q 2>/dev/null | grep -q .; then
        log_warn "Containers saas-kit déjà présents — arrêt."
        docker compose down 2>/dev/null || true
    fi

    log_info "Pull des images Docker..."
    docker compose --env-file .env pull --quiet 2>/dev/null || \
        log_warn "Pull partiel — démarrage avec images locales."

    log_info "Démarrage PostgreSQL, Dragonfly, Redis..."
    docker compose --env-file .env up -d postgres dragonfly redis

    log_info "Attente healthchecks bases de données (30s max)..."
    for i in {1..30}; do
        local pg_ok df_ok rd_ok
        pg_ok=$(docker inspect --format='{{.State.Health.Status}}' saaskit-postgres 2>/dev/null || echo "starting")
        df_ok=$(docker inspect --format='{{.State.Health.Status}}' saaskit-dragonfly 2>/dev/null || echo "starting")
        rd_ok=$(docker inspect --format='{{.State.Health.Status}}' saaskit-redis 2>/dev/null || echo "starting")
        if [[ "$pg_ok" == "healthy" && "$df_ok" == "healthy" && "$rd_ok" == "healthy" ]]; then
            log_success "Bases de données prêtes."; break
        fi
        sleep 1
        [[ $i -eq 30 ]] && log_warn "Timeout — on continue quand même."
    done

    log_info "Démarrage de tous les services..."
    docker compose --env-file .env up -d

    # M2 FIX : polling healthcheck au lieu de sleep fixe
    # Attend que n8n, baserow et minio soient healthy (60s max)
    log_info "Attente démarrage des services applicatifs (60s max)..."
    for _i in {1..60}; do
        local _n8n _brw _mio
        _n8n=$(docker inspect --format='{{.State.Health.Status}}' saaskit-n8n     2>/dev/null || echo "starting")
        _brw=$(docker inspect --format='{{.State.Health.Status}}' saaskit-baserow 2>/dev/null || echo "starting")
        _mio=$(docker inspect --format='{{.State.Health.Status}}' saaskit-minio   2>/dev/null || echo "starting")
        if [[ "$_n8n" == "healthy" && "$_brw" == "healthy" && "$_mio" == "healthy" ]]; then
            log_success "Services applicatifs prêts (${_i}s)."; break
        fi
        sleep 1
        [[ $_i -eq 60 ]] && log_warn "Timeout 60s — certains services tardent, on continue."
    done

    local FAILED=false
    local SERVICES=(saaskit-postgres saaskit-dragonfly saaskit-redis saaskit-n8n \
                    saaskit-baserow saaskit-minio saaskit-logto \
                    saaskit-uptime-kuma)
    [[ "$INSTALL_TTS" == "oui" ]] && SERVICES+=(saaskit-tts)
    [[ "$CADDY_MODE" == "standalone" ]] && SERVICES+=(saaskit-caddy)

    for svc in "${SERVICES[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            log_success "$svc — actif"
        else
            log_warn "$svc — non démarré (docker logs $svc)"; FAILED=true
        fi
    done

    docker ps --format '{{.Names}}' | grep -q "^saaskit-n8n-mcp$" && \
        log_success "saaskit-n8n-mcp — actif" || \
        log_warn "saaskit-n8n-mcp — sans clé API (normal — voir étape post-install)"
    [[ "$FAILED" == "true" ]] && log_warn "Certains services n'ont pas démarré."

    # ── Étape 7 : Templates n8n ──────────────────────────────
}

_install_post_setup() {
    etape "7" "$TOTAL_ETAPES" "Téléchargement des templates n8n"

    local TEMPLATES_DIR="$KIT_DIR/templates"
    for repo in "enescingoz/awesome-n8n-templates" "czlonkowski/n8n-skills"; do
        local name; name=$(basename "$repo")
        if [[ -d "$TEMPLATES_DIR/$name" ]]; then
            git -C "$TEMPLATES_DIR/$name" pull --quiet 2>/dev/null || true
            log_success "$name mis à jour."
        else
            git clone --quiet --depth=1 "https://github.com/${repo}.git" \
                "$TEMPLATES_DIR/$name" 2>/dev/null && \
                log_success "$name cloné." || log_warn "$name : clone échoué."
        fi
    done
    local TEMPLATES_COUNT
    TEMPLATES_COUNT=$(find "$TEMPLATES_DIR" -name "*.json" 2>/dev/null | wc -l)
    log_success "Templates : ${TEMPLATES_COUNT} fichiers JSON disponibles."

    # ── Étape 8 : Claude Code CLI + conf + helper ─────────────
    etape "8" "$TOTAL_ETAPES" "Installation Claude Code CLI"

    # FIX S5 : packages Ubuntu natifs — supprime curl|bash NodeSource
    if ! command -v node &>/dev/null; then
        log_info "Installation Node.js (Ubuntu 24.04 LTS natif)..."
        apt-get update -qq && apt-get install -y nodejs npm -qq
    fi
    local NODE_VER; NODE_VER=$(node --version 2>/dev/null || echo "inconnu")
    log_info "Node.js : $NODE_VER"
    local NODE_MAJOR; NODE_MAJOR=$(echo "$NODE_VER" | grep -oP '(?<=v)\d+' | head -1 || echo "0")
    [[ "${NODE_MAJOR:-0}" -lt 18 ]] && log_warn "Node.js < v18 — Claude Code peut ne pas fonctionner."

    # E3 FIX : nom de package corrigé (@anthropic-ai/ pas @anthropic/) + version pinnée
    # Vérifier la dernière version stable sur https://www.npmjs.com/package/@anthropic-ai/claude-code
    local CLAUDE_CODE_VERSION="2.1.114"
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" --quiet 2>/dev/null && \
        log_success "Claude Code ${CLAUDE_CODE_VERSION} installé." || \
        log_warn "Échec — installe manuellement : npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

    mkdir -p /etc/vps-secure
    (
        umask 077
        cat > "$CONF" << CONFEOF
# saas-kit — généré le $(date '+%Y-%m-%d %H:%M:%S')
ROOT_DOMAIN="${ROOT_DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
KIT_DIR="${KIT_DIR}"
N8N_DOMAIN="${N8N_DOMAIN}"
N8N_USER="${ADMIN_EMAIL}"
N8N_PASSWORD="${N8N_PASSWORD}"
MCP_DOMAIN="${MCP_DOMAIN}"
MCP_TOKEN="${MCP_TOKEN}"
BASEROW_DOMAIN="${BASEROW_DOMAIN}"
BASEROW_USER="${ADMIN_EMAIL}"
BASEROW_PASSWORD="${BASEROW_PASSWORD}"
MINIO_DOMAIN="${MINIO_DOMAIN}"
MINIO_CONSOLE_DOMAIN="${MINIO_CONSOLE_DOMAIN}"
MINIO_USER="admin"
MINIO_PASSWORD="${MINIO_PASSWORD}"
POSTGRES_USER="saaskit"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
LOGTO_DOMAIN="${LOGTO_DOMAIN}"
LOGTO_ADMIN_DOMAIN="${LOGTO_ADMIN_DOMAIN}"
PORT_LOGTO="${PORT_LOGTO}"
PORT_LOGTO_ADMIN="${PORT_LOGTO_ADMIN}"
INSTALL_TTS="${INSTALL_TTS}"
TTS_DOMAIN="${TTS_DOMAIN}"
UPTIME_DOMAIN="${UPTIME_DOMAIN}"
PORT_UPTIME="${PORT_UPTIME}"
# ARCH1 : mode reverse proxy détecté à l'installation
CADDY_MODE="${CADDY_MODE}"
CADDY_CONTAINER="${CADDY_CONTAINER}"
CADDYFILE="${CADDYFILE}"
CONFEOF
    )
    chmod 600 "$CONF"
    log_success "Config sauvegardée dans $CONF"

    # FIX B6/S3 : helper MCP — Python3 remplace sed pour sécurité
    (
        umask 077
        cat > /usr/local/bin/saaskit-mcp-apikey.sh << 'HELPEREOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${1:-}" ]] && echo "Usage : sudo $0 <N8N_API_KEY>" && exit 1
API_KEY="${1}"
ENV_FILE="/opt/saas-kit/.env"
[[ ! -f "$ENV_FILE" ]] && { echo "[ERR] $ENV_FILE non trouvé."; exit 1; }
python3 - "$ENV_FILE" "$API_KEY" << 'PYEOF'
import sys, os
env_file, api_key = sys.argv[1], sys.argv[2]
lines = []
found = False
with open(env_file) as f:
    for line in f:
        if line.startswith('N8N_API_KEY='):
            lines.append(f'N8N_API_KEY={api_key}\n'); found = True
        else:
            lines.append(line)
if not found: lines.append(f'N8N_API_KEY={api_key}\n')
tmp = env_file + '.tmp'
with open(tmp, 'w') as f: f.writelines(lines)
os.chmod(tmp, 0o600)
os.replace(tmp, env_file)
print("[OK] N8N_API_KEY mis à jour dans .env")
PYEOF
cd /opt/saas-kit
docker compose --env-file .env up -d --no-deps n8n-mcp
echo "[OK] n8n-MCP redémarré avec la nouvelle clé API."
HELPEREOF
    )
    chmod +x /usr/local/bin/saaskit-mcp-apikey.sh

    if [[ -f /etc/aide/aide.conf ]] && ! grep -q "saas-kit" /etc/aide/aide.conf 2>/dev/null; then
        {
            echo "!/opt/saas-kit/data(/.*)?$"
            echo "!/opt/saas-kit/backups(/.*)?$"
            echo "!/opt/saas-kit/templates(/.*)?$"
            echo "!/opt/saas-kit/.env$"
        } >> /etc/aide/aide.conf
        log_info "Répertoires saas-kit exclus de AIDE (data, backups, templates, .env)."
    fi

    # ── Étape 9 : Vérification endpoints ─────────────────────
    etape "9" "$TOTAL_ETAPES" "Vérification des endpoints"

    # M2 FIX : attend le healthcheck n8n plutôt qu'un sleep fixe
    log_info "Test des URLs publiques (attente healthcheck n8n, 30s max)..."
    _wait_healthy "saaskit-n8n" 30

    for url in "https://${N8N_DOMAIN}/healthz" "https://${BASEROW_DOMAIN}/" "https://${MINIO_DOMAIN}/minio/health/live"; do
        local HTTP_CODE
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" =~ ^(200|301|302|401|403)$ ]]; then
            log_success "$url => HTTP $HTTP_CODE"
        else
            log_warn "$url => HTTP $HTTP_CODE"
        fi
    done

    echo ""
    echo -e "${GRAS}${VERT}+$(printf '=%.0s' {1..66})+${RESET}"
    echo -e "${GRAS}${VERT}|    saas-kit — Installation terminée ✓  [mode: ${CADDY_MODE}]     |${RESET}"
    echo -e "${GRAS}${VERT}+$(printf '=%.0s' {1..66})+${RESET}"
    echo ""
    echo -e "  ${VERT}n8n           :${RESET} https://${N8N_DOMAIN}"
    echo -e "  ${VERT}n8n-MCP       :${RESET} https://${MCP_DOMAIN}"
    echo -e "  ${VERT}Baserow       :${RESET} https://${BASEROW_DOMAIN}"
    echo -e "  ${VERT}MinIO API     :${RESET} https://${MINIO_DOMAIN}"
    echo -e "  ${VERT}MinIO Console :${RESET} https://${MINIO_CONSOLE_DOMAIN}"
    echo -e "  ${VERT}Logto (auth)  :${RESET} https://${LOGTO_DOMAIN}"
    echo -e "  ${VERT}Uptime Kuma   :${RESET} https://${UPTIME_DOMAIN}"
    [[ "$INSTALL_TTS" == "oui" ]] && echo -e "  ${VERT}Pocket TTS    :${RESET} https://${TTS_DOMAIN}"
    echo ""
    echo -e "  ${JAUNE}Post-install :${RESET}"
    echo -e "  1. sudo ./saaskit.sh keys"
    echo -e "  2. n8n : https://${N8N_DOMAIN} → ${ADMIN_EMAIL}"
    echo -e "  3. sudo saaskit-mcp-apikey.sh <clé_api_n8n>"
    echo -e "  4. Baserow : https://${BASEROW_DOMAIN} → créer compte"
    echo -e "  5. Logto admin : http://127.0.0.1:${PORT_LOGTO_ADMIN} (accès local uniquement)"
    echo -e "  6. Uptime Kuma : https://${UPTIME_DOMAIN} → créer compte admin"
    [[ "$INSTALL_TTS" == "oui" ]] && echo -e "  7. Pocket TTS : https://${TTS_DOMAIN} (premier démarrage ~2min, download modèle)"
    echo ""
    echo -e "${GRAS}${VERT}  Done. Stack prête sur https://${ROOT_DOMAIN}${RESET}"
    echo ""
}

cmd_install() {
    banner
    # C1 FIX : TOTAL_ETAPES global (accessible depuis les sous-fonctions)
    TOTAL_ETAPES=9

    # FIX W1 : bloquer si déjà installé
    if [[ -f "$KIT_DIR/.env" ]]; then
        log_error "saas-kit déjà installé dans $KIT_DIR"
        log_error "Lance 'sudo ./saaskit.sh update' ou 'uninstall' d'abord."
        exit 1
    fi

    _install_check_prereqs
    _install_gather_config
    _install_check_dns
    _install_create_env
    _install_generate_compose
    _install_configure_proxy
    _install_start_containers
    _install_post_setup
}


# ============================================================
# COMMANDE : keys
# ============================================================
cmd_keys() {
    local ENV_FILE="$KIT_DIR/.env"
    [[ ! -f "$ENV_FILE" ]] && { log_error ".env non trouvé — lance d'abord install."; exit 1; }

    set -a
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
        export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    done < "$ENV_FILE"
    set +a

    echo ""
    echo -e "${GRAS}${VERT}+$(printf '=%.0s' {1..60})+${RESET}"
    echo -e "${GRAS}${VERT}|           saas-kit — Credentials                     |${RESET}"
    echo -e "${GRAS}${VERT}+$(printf '=%.0s' {1..60})+${RESET}"
    echo ""
    echo -e "  ${GRAS}URLs :${RESET}"
    echo -e "  n8n           : ${VERT}https://${N8N_DOMAIN:-?}${RESET}"
    echo -e "  n8n-MCP       : ${VERT}https://${MCP_DOMAIN:-?}${RESET}"
    echo -e "  Baserow       : ${VERT}https://${BASEROW_DOMAIN:-?}${RESET}"
    echo -e "  MinIO API     : ${VERT}https://${MINIO_DOMAIN:-?}${RESET}"
    echo -e "  MinIO Console : ${VERT}https://${MINIO_CONSOLE_DOMAIN:-?}${RESET}"
    echo -e "  Logto (auth)  : ${VERT}https://${LOGTO_DOMAIN:-?}${RESET}"
    echo -e "  Uptime Kuma   : ${VERT}https://${UPTIME_DOMAIN:-?}${RESET}"
    [[ "${INSTALL_TTS:-non}" == "oui" ]] && \
        echo -e "  Pocket TTS    : ${VERT}https://${TTS_DOMAIN:-?}${RESET}"
    echo ""
    echo -e "  ${GRAS}Credentials :${RESET}"
    echo -e "  Admin email : ${VERT}${ADMIN_EMAIL:-?}${RESET}"
    echo -e "  n8n         : ${VERT}${ADMIN_EMAIL:-?} / ${N8N_PASSWORD:-?}${RESET}"
    echo -e "  Baserow     : ${VERT}${ADMIN_EMAIL:-?} / ${BASEROW_PASSWORD:-?}${RESET}"
    echo -e "  MinIO       : ${VERT}admin / ${MINIO_ROOT_PASSWORD:-?}${RESET}"
    echo -e "  MCP Token   : ${VERT}${MCP_TOKEN:-?}${RESET}"
    if [[ -n "${N8N_API_KEY:-}" ]]; then
        echo -e "  n8n API Key : ${VERT}${N8N_API_KEY}${RESET}"
    else
        echo -e "  n8n API Key : ${JAUNE}non configurée — sudo saaskit-mcp-apikey.sh <clé>${RESET}"
    fi
    echo ""
    echo -e "  ${GRAS}Secrets techniques :${RESET}"
    echo -e "  PostgreSQL  : ${VERT}saaskit / ${POSTGRES_PASSWORD:-?}${RESET}"
    echo -e "  n8n enc key : ${VERT}${N8N_ENCRYPTION_KEY:-?}${RESET}"
    echo ""
    echo -e "  ${GRAS}Config Claude Desktop (n8n-MCP) :${RESET}"
    echo    '  { "mcpServers": { "n8n-mcp": { "command": "npx", "args": ["n8n-mcp"],'
    echo    '    "env": { "MCP_MODE": "http",'
    # FIX S2 : MCP_SERVER_URL
    echo -e "      \"MCP_SERVER_URL\": \"https://${MCP_DOMAIN:-?}\","
    echo -e "      \"AUTH_TOKEN\": \"${MCP_TOKEN:-?}\", \"LOG_LEVEL\": \"error\" } } } }"
    echo ""
    echo -e "  ${JAUNE}Source : $ENV_FILE (chmod 600)${RESET}"
    echo ""
}

# ============================================================
# COMMANDE : backup
# ============================================================
cmd_backup() {
    local DO_POSTGRES=true DO_VOLUMES=true
    case "${2:-}" in
        --postgres) DO_VOLUMES=false ;;
        --volumes)  DO_POSTGRES=false ;;
        --list)
            find "$BACKUP_DIR" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) 2>/dev/null \
                | sort | while read -r f; do echo -e "  $(du -sh "$f" | cut -f1)  $f"; done
            return 0 ;;
    esac

    [[ ! -f "$CONF" ]] && { log_error "Config non trouvée. Lance d'abord install."; exit 1; }
    ! docker ps --format '{{.Names}}' | grep -q "^saaskit-postgres$" && \
        { log_error "Container saaskit-postgres non démarré."; exit 1; }

    local POSTGRES_USER MINIO_BUCKET="saaskit-backups"
    POSTGRES_USER=$(grep '^POSTGRES_USER=' "$CONF" | cut -d'=' -f2 | tr -d '"')
    [[ -z "$POSTGRES_USER" ]] && { log_error "POSTGRES_USER introuvable dans $CONF"; exit 1; }

    local MINIO_ROOT_USER MINIO_ROOT_PASSWORD
    MINIO_ROOT_USER=$(grep '^MINIO_ROOT_USER=' "$KIT_DIR/.env" | cut -d'=' -f2)
    MINIO_ROOT_PASSWORD=$(grep '^MINIO_ROOT_PASSWORD=' "$KIT_DIR/.env" | cut -d'=' -f2)

    local TIMESTAMP; TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
    mkdir -p "$BACKUP_DIR"
    echo -e "\n${GRAS}${VERT}  saas-kit — Backup $TIMESTAMP${RESET}\n"
    local BACKUP_OK=true

    if [[ "$DO_POSTGRES" == "true" ]]; then
        log_info "Backup PostgreSQL..."
        local DBS_TO_BACKUP=("n8n_db" "baserow_db" "logto_db")

        for db in "${DBS_TO_BACKUP[@]}"; do
            local DEST="$BACKUP_DIR/postgres_${db}_${TIMESTAMP}.sql.gz"
            local _s
            docker exec saaskit-postgres pg_dump -U "$POSTGRES_USER" "$db" 2>/dev/null \
                > "${DEST%.gz}" && gzip -f "${DEST%.gz}" && _s=0 || _s=1
            [[ $_s -eq 0 ]] && log_success "  $db → $(basename "$DEST") ($(du -sh "$DEST" | cut -f1))" \
                || { log_warn "  Dump $db échoué"; BACKUP_OK=false; }
        done
        local DEST_G="$BACKUP_DIR/postgres_globals_${TIMESTAMP}.sql.gz"
        docker exec saaskit-postgres pg_dumpall -U "$POSTGRES_USER" --globals-only 2>/dev/null \
            | gzip > "$DEST_G" && log_success "  globals → $(basename "$DEST_G")" || true
    fi

    if [[ "$DO_VOLUMES" == "true" ]]; then
        log_info "Backup volumes..."
        local DEST_N8N="$BACKUP_DIR/volume_n8n_${TIMESTAMP}.tar.gz"
        tar -czf "$DEST_N8N" -C "$DATA_DIR" n8n/ uptime-kuma/ 2>/dev/null && \
            log_success "  n8n → $(basename "$DEST_N8N") ($(du -sh "$DEST_N8N" | cut -f1))" || \
            { log_warn "  Backup n8n échoué"; BACKUP_OK=false; }
        local DEST_MINIO="$BACKUP_DIR/volume_minio_${TIMESTAMP}.tar.gz"
        tar -czf "$DEST_MINIO" -C "$DATA_DIR" minio/ 2>/dev/null && \
            log_success "  minio → $(basename "$DEST_MINIO") ($(du -sh "$DEST_MINIO" | cut -f1))" || \
            log_warn "  Backup MinIO échoué (non bloquant)"
    fi

    log_info "Upload vers MinIO interne (bucket: $MINIO_BUCKET)..."
    # FIX S9 : MC_HOST_ remplace mc alias set — credentials invisibles dans docker events
    local _mc_local="MC_HOST_local=http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@localhost:9000"
    docker exec -e "$_mc_local" saaskit-minio mc mb --ignore-existing "local/${MINIO_BUCKET}" 2>/dev/null || true
    local UPLOADED=0
    for f in "$BACKUP_DIR"/*_${TIMESTAMP}*; do
        [[ -f "$f" ]] || continue
        docker cp "$f" "saaskit-minio:/tmp/$(basename "$f")" && \
            docker exec -e "$_mc_local" saaskit-minio mc cp "/tmp/$(basename "$f")" "local/${MINIO_BUCKET}/$(basename "$f")" && \
            docker exec saaskit-minio rm -f "/tmp/$(basename "$f")" && UPLOADED=$((UPLOADED + 1))
    done
    log_success "MinIO : $UPLOADED fichier(s) uploadé(s)."

    local EXTERNAL_CONF="$KIT_DIR/backup-external.conf"
    if [[ -f "$EXTERNAL_CONF" ]]; then
        # FIX S4 : vérifier et corriger les permissions — fichier contient des clés S3
        local _ext_perms
        _ext_perms=$(stat -c '%a' "$EXTERNAL_CONF" 2>/dev/null || echo "644")
        if [[ "$_ext_perms" != "600" && "$_ext_perms" != "400" ]]; then
            log_warn "backup-external.conf : permissions trop larges (${_ext_perms}) — correction automatique en 600."
            chmod 600 "$EXTERNAL_CONF"
        fi
        local BACKUP_EXTERNAL_ENDPOINT BACKUP_EXTERNAL_ACCESS_KEY \
              BACKUP_EXTERNAL_SECRET_KEY BACKUP_EXTERNAL_BUCKET
        BACKUP_EXTERNAL_ENDPOINT=$(grep '^BACKUP_EXTERNAL_ENDPOINT=' "$EXTERNAL_CONF" | cut -d'=' -f2- | tr -d '"' || echo "")
        BACKUP_EXTERNAL_ACCESS_KEY=$(grep '^BACKUP_EXTERNAL_ACCESS_KEY=' "$EXTERNAL_CONF" | cut -d'=' -f2- | tr -d '"' || echo "")
        BACKUP_EXTERNAL_SECRET_KEY=$(grep '^BACKUP_EXTERNAL_SECRET_KEY=' "$EXTERNAL_CONF" | cut -d'=' -f2- | tr -d '"' || echo "")
        BACKUP_EXTERNAL_BUCKET=$(grep '^BACKUP_EXTERNAL_BUCKET=' "$EXTERNAL_CONF" | cut -d'=' -f2- | tr -d '"' || echo "saaskit-backups")

        if [[ -n "${BACKUP_EXTERNAL_ENDPOINT:-}" ]]; then
            log_info "Upload externe vers ${BACKUP_EXTERNAL_ENDPOINT}..."
            # FIX S9 : MC_HOST_ pour backup externe — credentials dans env var
            local _ext_host="${BACKUP_EXTERNAL_ENDPOINT#https://}"
            _ext_host="${_ext_host#http://}"
            local _mc_ext="MC_HOST_ext-backup=https://${BACKUP_EXTERNAL_ACCESS_KEY:-}:${BACKUP_EXTERNAL_SECRET_KEY:-}@${_ext_host}"
            for f in "$BACKUP_DIR"/*_${TIMESTAMP}*; do
                [[ -f "$f" ]] || continue
                local fname; fname=$(basename "$f")
                local fsize_local; fsize_local=$(stat -c%s "$f" 2>/dev/null || echo "0")
                if docker cp "$f" "saaskit-minio:/tmp/${fname}" 2>/dev/null; then
                    if timeout 300 docker exec -e "$_mc_ext" saaskit-minio mc cp \
                            "/tmp/${fname}" "ext-backup/${BACKUP_EXTERNAL_BUCKET}/${fname}" 2>/dev/null; then
                        local fsize_remote
                        fsize_remote=$(docker exec -e "$_mc_ext" saaskit-minio mc stat \
                            "ext-backup/${BACKUP_EXTERNAL_BUCKET}/${fname}" 2>/dev/null \
                            | grep -i 'size' | grep -oP '\d+' | head -1 || echo "0")
                        if [[ "${fsize_remote:-0}" -ge "$fsize_local" ]]; then
                            log_success "  Externe : ${fname} ($(du -sh "$f" | cut -f1))"
                        else
                            log_warn "  Upload incomplet : ${fname}"; BACKUP_OK=false
                        fi
                    else
                        log_warn "  Upload échoué ou timeout : ${fname}"; BACKUP_OK=false
                    fi
                    docker exec saaskit-minio rm -f "/tmp/${fname}" 2>/dev/null || true
                else
                    log_warn "  Transfert container échoué : ${fname}"; BACKUP_OK=false
                fi
            done
        fi
    fi

    local DELETED
    DELETED=$(find "$BACKUP_DIR" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
        -mtime +7 -print -delete 2>/dev/null | wc -l)
    [[ $DELETED -gt 0 ]] && log_info "$DELETED ancien(s) backup(s) supprimé(s)."

    echo ""
    [[ "$BACKUP_OK" == "true" ]] && log_success "Backup complet OK — $BACKUP_DIR" || \
        { log_warn "Backup terminé avec des avertissements."; exit 1; }
}

# ============================================================
# COMMANDE : update
# ============================================================
cmd_update() {
    [[ ! -f "$KIT_DIR/docker-compose.yml" ]] && \
        { log_error "docker-compose.yml non trouvé. Lance d'abord install."; exit 1; }

    if [[ "${2:-}" == "--check" ]]; then
        docker compose --env-file "$KIT_DIR/.env" -f "$KIT_DIR/docker-compose.yml" images
        return 0
    fi

    local SPECIFIC="${2:-}"
    local ALL_SERVICES=(postgres dragonfly redis n8n n8n-mcp baserow minio logto uptime-kuma tts)

    # ARCH1 : inclure caddy si mode standalone
    if [[ -z "$SPECIFIC" && -f "$CONF" ]]; then
        local _cm; _cm=$(grep '^CADDY_MODE=' "$CONF" | cut -d'"' -f2 2>/dev/null || echo "inject")
        [[ "$_cm" == "standalone" ]] && ALL_SERVICES+=(caddy)
    fi
    [[ -n "$SPECIFIC" ]] && ALL_SERVICES=("$SPECIFIC")

    echo -e "\n${GRAS}${VERT}  saas-kit — Update $(date '+%Y-%m-%d %H:%M:%S')${RESET}\n"

    cd "$KIT_DIR"
    log_info "Pull des images..."
    if [[ -n "$SPECIFIC" ]]; then
        docker compose --env-file .env pull "$SPECIFIC" 2>/dev/null || true
    else
        docker compose --env-file .env pull 2>/dev/null || true
    fi
    log_success "Images à jour."

    local UPDATED=0 SKIPPED=0

    for svc in "${ALL_SERVICES[@]}"; do
        local ctn="saaskit-${svc}"
        docker compose --env-file .env config --services 2>/dev/null | grep -q "^${svc}$" || \
            { SKIPPED=$((SKIPPED+1)); continue; }
        docker ps --format '{{.Names}}' | grep -q "^${ctn}$" || \
            { log_info "$svc non démarré — ignoré."; SKIPPED=$((SKIPPED+1)); continue; }

        local cur_digest new_digest
        cur_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$ctn" 2>/dev/null || echo "unknown")
        local img
        img=$(docker compose --env-file .env config --format json 2>/dev/null \
            | python3 -c "import sys,json; cfg=json.load(sys.stdin); print(cfg['services'].get('${svc}',{}).get('image',''))" 2>/dev/null || echo "")
        new_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "")

        if [[ -n "$cur_digest" && -n "$new_digest" && "$cur_digest" == "$new_digest" && "$cur_digest" != "unknown" ]]; then
            log_info "$svc — déjà à jour."; SKIPPED=$((SKIPPED+1)); continue
        fi

        log_info "Mise à jour $svc..."
        docker compose --env-file .env up -d --no-deps "$svc" 2>/dev/null
        _wait_healthy "$ctn" 45
        log_success "$svc — mis à jour."
        UPDATED=$((UPDATED+1)); sleep 2
    done

    docker image prune -f 2>/dev/null | grep -v "^$" || true
    echo ""
    echo -e "  ${VERT}Mis à jour : $UPDATED${RESET}  ${BLANC}Inchangés : $SKIPPED${RESET}"
    log_success "Update terminé."
}

# ============================================================
# COMMANDE : uninstall
# ============================================================
cmd_uninstall() {
    echo -e "${ROUGE}"
cat << 'EOF'
  ██╗   ██╗███╗  ██╗██╗███╗  ██╗███████╗████████╗ █████╗ ██╗     ██╗
  ██║   ██║████╗ ██║██║████╗ ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║
  ██║   ██║██╔██╗██║██║██╔██╗██║███████╗   ██║   ███████║██║     ██║
  ██║   ██║██║╚████║██║██║╚████║╚════██║   ██║   ██╔══██║██║     ██║
  ╚██████╔╝██║ ╚███║██║██║ ╚███║███████║   ██║   ██║  ██║███████╗███████╗
   ╚═════╝ ╚═╝  ╚══╝╚═╝╚═╝  ╚══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝
EOF
    echo -e "${RESET}"
    echo -e "${ROUGE}  ATTENTION : Opération IRRÉVERSIBLE.${RESET}"
    echo -e "${BLANC}  Fais un backup d'abord : sudo ./saaskit.sh backup${RESET}"
    echo ""
    read -rp "  Tape SUPPRIMER pour confirmer : " confirm
    [[ "$confirm" != "SUPPRIMER" ]] && { log_info "Annulé."; exit 0; }

    echo ""
    log_warn "Désinstallation en cours..."

    # ARCH1 : lire le mode Caddy depuis conf (fallback inject pour rétrocompat)
    local _caddy_mode _caddy_container _caddyfile
    if [[ -f "$CONF" ]]; then
        _caddy_mode=$(grep '^CADDY_MODE=' "$CONF" | cut -d'"' -f2 2>/dev/null || echo "inject")
        _caddy_container=$(grep '^CADDY_CONTAINER=' "$CONF" | cut -d'"' -f2 2>/dev/null || echo "vps-monitor-caddy")
        _caddyfile=$(grep '^CADDYFILE=' "$CONF" | cut -d'"' -f2 2>/dev/null || echo "/home/vpsadmin/vps-monitor/Caddyfile")
    else
        _caddy_mode="inject"; _caddy_container="vps-monitor-caddy"
        _caddyfile="/home/vpsadmin/vps-monitor/Caddyfile"
    fi
    CADDY_CONTAINER="$_caddy_container"
    CADDYFILE="$_caddyfile"

    if [[ -f "$KIT_DIR/docker-compose.yml" ]]; then
        cd "$KIT_DIR"
        docker compose down --volumes 2>/dev/null && log_success "Containers et volumes supprimés." || true
    fi

    for ctn in saaskit-postgres saaskit-dragonfly saaskit-redis saaskit-n8n \
               saaskit-n8n-mcp saaskit-baserow saaskit-minio \
               saaskit-logto saaskit-uptime-kuma saaskit-tts saaskit-caddy; do
        docker ps -a --format '{{.Names}}' | grep -q "^${ctn}$" && \
            docker rm -f "$ctn" 2>/dev/null && log_info "  $ctn supprimé." || true
    done

    docker network ls --format '{{.Name}}' | grep -q "^saaskit-net$" && \
        docker network rm saaskit-net 2>/dev/null && log_success "Réseau saaskit-net supprimé." || true

    # ARCH1 : nettoyage Caddy selon le mode
    if [[ "$_caddy_mode" == "inject" ]]; then
        # FIX W7/M3 : parser Python robuste — supprime blocs du Caddyfile externe
        if [[ -f "$CADDYFILE" ]] && grep -q "saas-kit" "$CADDYFILE" 2>/dev/null; then
            cp "$CADDYFILE" "${CADDYFILE}.pre-uninstall.$(date '+%Y%m%d-%H%M%S')"
            python3 - "$CADDYFILE" << 'PYEOF'
import sys, re

def remove_saaskit_blocks(content):
    lines = content.split('\n')
    result = []
    skip = False
    depth = 0
    block_started = False
    for line in lines:
        if not skip and re.match(r'^\s*#\s*──\s*saas-kit', line):
            skip = True; depth = 0; block_started = False; continue
        if skip:
            clean = re.sub(r'\{[^{}]*\}', '', line)
            opens = clean.count('{'); closes = clean.count('}')
            depth += opens - closes
            if opens > 0: block_started = True
            if block_started and depth <= 0: skip = False; block_started = False
            continue
        result.append(line)
    cleaned = '\n'.join(result)
    cleaned = re.sub(r'\n{3,}', '\n\n', cleaned).rstrip() + '\n'
    return cleaned

with open(sys.argv[1]) as f: content = f.read()
with open(sys.argv[1], 'w') as f: f.write(remove_saaskit_blocks(content))
PYEOF
            log_success "Blocs saas-kit supprimés du Caddyfile."
            docker ps --format '{{.Names}}' | grep -q "^${CADDY_CONTAINER}$" && \
                docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile 2>/dev/null && \
                log_success "Caddy rechargé." || log_warn "Reload Caddy manuel requis."
        fi
    else
        # Mode standalone : saaskit-caddy supprimé par compose down, Caddyfile par rm -rf KIT_DIR
        log_success "Caddy standalone (saaskit-caddy) supprimé avec les autres containers."
    fi

    [[ -d "$KIT_DIR" ]] && rm -rf "$KIT_DIR" && log_success "$KIT_DIR supprimé."
    [[ -f "$CONF" ]] && rm -f "$CONF" && log_success "Config supprimée."
    [[ -f /usr/local/bin/saaskit-mcp-apikey.sh ]] && \
        rm -f /usr/local/bin/saaskit-mcp-apikey.sh && log_success "Helper supprimé."
    [[ -f /etc/aide/aide.conf ]] && sed -i '/^!\/opt\/saas-kit/d' /etc/aide/aide.conf 2>/dev/null || true

    echo ""
    log_success "saas-kit désinstallé proprement."
    echo -e "  ${BLANC}Pour libérer l'espace images : docker image prune -a${RESET}"
    echo ""
}

# ============================================================
# Dispatcher principal
# ============================================================
CMD="${1:-help}"

case "$CMD" in
    install)   check_root; cmd_install "$@" ;;
    keys)      check_root; cmd_keys "$@" ;;
    backup)    check_root; cmd_backup "$@" ;;
    update)    check_root; cmd_update "$@" ;;
    uninstall) check_root; cmd_uninstall "$@" ;;
    help|--help|-h|*)
        echo ""
        echo -e "${GRAS}saas-kit — Self-hosted SaaS stack${RESET}"
        echo ""
        echo -e "  ${VERT}sudo ./saaskit.sh install${RESET}           — installe la stack"
        echo -e "  ${VERT}sudo ./saaskit.sh keys${RESET}              — affiche tous les credentials"
        echo -e "  ${VERT}sudo ./saaskit.sh backup${RESET}            — sauvegarde complète"
        echo -e "  ${VERT}sudo ./saaskit.sh backup --postgres${RESET} — PostgreSQL uniquement"
        echo -e "  ${VERT}sudo ./saaskit.sh backup --volumes${RESET}  — volumes uniquement"
        echo -e "  ${VERT}sudo ./saaskit.sh backup --list${RESET}     — liste les backups locaux"
        echo -e "  ${VERT}sudo ./saaskit.sh update${RESET}            — met à jour toutes les images"
        echo -e "  ${VERT}sudo ./saaskit.sh update <service>${RESET}  — met à jour un service"
        echo -e "  ${VERT}sudo ./saaskit.sh update --check${RESET}    — vérifie les updates dispo"
        echo -e "  ${VERT}sudo ./saaskit.sh uninstall${RESET}         — désinstalle proprement"
        echo ""
        echo -e "  ${BLANC}github.com/rockballslab/saas-kit${RESET}"
        echo ""
        ;;
esac
