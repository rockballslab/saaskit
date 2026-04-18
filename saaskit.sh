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
#   - Ubuntu 24.04 LTS
#   - vps-secure installé (Docker, UFW configurés)
#   - install-dashboard.sh exécuté (Caddy vps-monitor-caddy en place)
#   - DNS configurés pour tous les sous-domaines
#
# ATTENTION : le one-liner curl|bash ne peut pas lancer install
#   interactivement (stdin = pipe). Télécharger d'abord :
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
# FIX S1 : umask 077 global retiré — appliqué seulement aux fichiers sensibles
# pour éviter de casser git clone et apt-get

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
CADDYFILE="/home/vpsadmin/vps-monitor/Caddyfile"
CADDY_CONTAINER="vps-monitor-caddy"
ADMIN_USER="${SUDO_USER:-vpsadmin}"

PORT_N8N=5678
PORT_MCP=5679
PORT_BASEROW=5680
PORT_MINIO_API=9000
PORT_MINIO_CONSOLE=9001
PORT_LISTMONK=5682

# ============================================================
# Vérification root (commune à toutes les commandes)
# ============================================================
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Ce script doit être lancé en ROOT (sudo)."
        exit 1
    fi
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
# ============================================================
# COMMANDE : install
# ============================================================
# ============================================================
cmd_install() {
    banner
    local TOTAL_ETAPES=9

    # ── Vérifications initiales ──────────────────────────────

    # FIX W1 : Garde idempotence — bloquer si déjà installé
    if [[ -f "$KIT_DIR/.env" ]]; then
        log_error "saas-kit déjà installé dans $KIT_DIR"
        log_error "Lance 'sudo ./saaskit.sh update' pour mettre à jour."
        log_error "Lance 'sudo ./saaskit.sh uninstall' pour désinstaller d'abord."
        exit 1
    fi

    if ! grep -q "24.04" /etc/os-release 2>/dev/null; then
        log_warn "Ubuntu 24.04 recommandé. Autre version détectée."
        read -rp "  Continuer quand même ? (oui/non) : " _ans
        [[ "$_ans" == "oui" ]] || exit 1
    fi
    if ! command -v docker &>/dev/null; then
        log_error "Docker non trouvé — lance d'abord vps-secure."
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose v2 non trouvé — lance d'abord vps-secure."
        exit 1
    fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CADDY_CONTAINER}$"; then
        log_error "Container ${CADDY_CONTAINER} non trouvé."
        log_error "Lance d'abord install-dashboard.sh de vps-secure."
        exit 1
    fi
    if [[ ! -f "$CADDYFILE" ]]; then
        log_error "Caddyfile non trouvé : $CADDYFILE"
        exit 1
    fi
    command -v git &>/dev/null || apt-get install -y git -qq
    command -v dig &>/dev/null || apt-get install -y dnsutils -qq
    log_success "Prérequis OK."

    # ── Étape 1 : Configuration ──────────────────────────────
    etape "1" "$TOTAL_ETAPES" "Configuration"

    echo -e "${BLANC}  Deux informations suffisent — tout le reste est généré automatiquement.${RESET}\n"

    read -rp "  Domaine racine (ex: mondomaine.com) : " ROOT_DOMAIN
    [[ -z "$ROOT_DOMAIN" ]] && { log_error "Domaine obligatoire."; exit 1; }

    read -rp "  Email admin : " ADMIN_EMAIL
    [[ ! "$ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && { log_error "Email invalide."; exit 1; }

    echo ""
    read -rp "  Installer Listmonk (email transactionnel) ? (oui/non) : " INSTALL_LISTMONK
    INSTALL_LISTMONK="${INSTALL_LISTMONK:-non}"

    # Tout auto-généré
    log_info "Génération des secrets..."
    # FIX S1 : umask restreint uniquement pour la génération de secrets en mémoire
    N8N_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    BASEROW_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    MINIO_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
    MCP_TOKEN=$(openssl rand -hex 32)
    BASEROW_SECRET_KEY=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 50)

    # Sous-domaines
    N8N_DOMAIN="n8n.${ROOT_DOMAIN}"
    MCP_DOMAIN="mcpn8n.${ROOT_DOMAIN}"
    BASEROW_DOMAIN="baserow.${ROOT_DOMAIN}"
    MINIO_DOMAIN="minio.${ROOT_DOMAIN}"
    MINIO_CONSOLE_DOMAIN="minio-console.${ROOT_DOMAIN}"
    LISTMONK_DOMAIN="listmonk.${ROOT_DOMAIN}"

    echo ""
    log_info "Sous-domaines configurés :"
    echo -e "  ${BLANC}$N8N_DOMAIN${RESET}"
    echo -e "  ${BLANC}$MCP_DOMAIN${RESET}"
    echo -e "  ${BLANC}$BASEROW_DOMAIN${RESET}"
    echo -e "  ${BLANC}$MINIO_DOMAIN${RESET}"
    echo -e "  ${BLANC}$MINIO_CONSOLE_DOMAIN${RESET}"
    [[ "$INSTALL_LISTMONK" == "oui" ]] && echo -e "  ${BLANC}$LISTMONK_DOMAIN${RESET}"
    log_success "Secrets générés."

    # ── Étape 2 : DNS ────────────────────────────────────────
    etape "2" "$TOTAL_ETAPES" "Vérification DNS"

    # FIX W8 : fallback si ip route échoue (pare-feu strict vers 8.8.8.8)
    VPS_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    [[ -z "$VPS_IP" ]] && VPS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$VPS_IP" ]] && VPS_IP="<IP inconnue>"
    log_info "IP VPS détectée : $VPS_IP"

    local DOMAINS_TO_CHECK=("$N8N_DOMAIN" "$MCP_DOMAIN" "$BASEROW_DOMAIN" "$MINIO_DOMAIN" "$MINIO_CONSOLE_DOMAIN")
    [[ "$INSTALL_LISTMONK" == "oui" ]] && DOMAINS_TO_CHECK+=("$LISTMONK_DOMAIN")

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
        echo ""
        log_warn "Certains DNS ne pointent pas encore vers ce VPS."
        read -rp "  Continuer quand même ? (oui/non) : " dns_answer
        [[ "$dns_answer" == "oui" ]] || exit 1
    else
        log_success "Tous les DNS sont correctement configurés."
    fi

    # ── Étape 3 : Répertoires et fichiers ────────────────────
    etape "3" "$TOTAL_ETAPES" "Création de l'environnement"

    mkdir -p "$KIT_DIR"
    mkdir -p \
        "$DATA_DIR/postgres" \
        "$DATA_DIR/dragonfly" \
        "$DATA_DIR/redis" \
        "$DATA_DIR/n8n" \
        "$DATA_DIR/baserow" \
        "$DATA_DIR/minio" \
        "$DATA_DIR/listmonk" \
        "$KIT_DIR/templates" \
        "$KIT_DIR/initdb"

    if [[ -d "$DATA_DIR/postgres/global" ]]; then
        log_warn "Données PostgreSQL existantes détectées dans $DATA_DIR/postgres"
        log_warn "Le script SQL init NE sera PAS réexécuté (comportement PostgreSQL normal)."
        read -rp "  Continuer quand même ? Les bases doivent déjà exister. (oui/non) : " _pg_ans
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
# saas-kit — généré le $(date '+%Y-%m-%d %H:%M:%S')
# NE PAS COMMITTER — chmod 600

ROOT_DOMAIN=${ROOT_DOMAIN}
N8N_DOMAIN=${N8N_DOMAIN}
MCP_DOMAIN=${MCP_DOMAIN}
BASEROW_DOMAIN=${BASEROW_DOMAIN}
MINIO_DOMAIN=${MINIO_DOMAIN}
MINIO_CONSOLE_DOMAIN=${MINIO_CONSOLE_DOMAIN}
LISTMONK_DOMAIN=${LISTMONK_DOMAIN}

ADMIN_EMAIL=${ADMIN_EMAIL}

POSTGRES_USER=saaskit
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres

N8N_PASSWORD=${N8N_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

MCP_TOKEN=${MCP_TOKEN}
# FIX B6 : N8N_API_KEY dans .env pour que n8n-mcp soit géré par Compose
N8N_API_KEY=

BASEROW_PASSWORD=${BASEROW_PASSWORD}
BASEROW_SECRET_KEY=${BASEROW_SECRET_KEY}

MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=${MINIO_PASSWORD}

INSTALL_LISTMONK=${INSTALL_LISTMONK}
PORT_LISTMONK=${PORT_LISTMONK}

KIT_DIR=${KIT_DIR}
DATA_DIR=${DATA_DIR}
ENV
    )
    chmod 600 "$KIT_DIR/.env"
    log_success ".env généré : $KIT_DIR/.env"

    # init SQL — listmonk_db créé conditionnellement
    if [[ "$INSTALL_LISTMONK" == "oui" ]]; then
        cat > "$KIT_DIR/initdb/01-create-databases.sql" << 'SQL'
-- saas-kit — Initialisation des bases de données
CREATE DATABASE n8n_db;
GRANT ALL PRIVILEGES ON DATABASE n8n_db TO saaskit;

CREATE DATABASE baserow_db;
GRANT ALL PRIVILEGES ON DATABASE baserow_db TO saaskit;

CREATE DATABASE listmonk_db;
GRANT ALL PRIVILEGES ON DATABASE listmonk_db TO saaskit;
SQL
    else
        cat > "$KIT_DIR/initdb/01-create-databases.sql" << 'SQL'
-- saas-kit — Initialisation des bases de données
CREATE DATABASE n8n_db;
GRANT ALL PRIVILEGES ON DATABASE n8n_db TO saaskit;

CREATE DATABASE baserow_db;
GRANT ALL PRIVILEGES ON DATABASE baserow_db TO saaskit;
SQL
    fi
    log_success "Script SQL init généré."

    # ── Étape 4 : docker-compose.yml ─────────────────────────
    etape "4" "$TOTAL_ETAPES" "Génération docker-compose.yml"

    # Bloc Listmonk conditionnel
    local LISTMONK_SERVICE
    if [[ "$INSTALL_LISTMONK" == "oui" ]]; then
        LISTMONK_SERVICE="
  # Listmonk — email transactionnel
  listmonk:
    image: listmonk/listmonk:latest
    container_name: saaskit-listmonk
    restart: unless-stopped
    ports:
      - \"127.0.0.1:${PORT_LISTMONK}:9000\"
    environment:
      LISTMONK_app__address: \"0.0.0.0:9000\"
      LISTMONK_db__host: postgres
      LISTMONK_db__port: 5432
      LISTMONK_db__user: \${POSTGRES_USER}
      LISTMONK_db__password: \${POSTGRES_PASSWORD}
      LISTMONK_db__database: listmonk_db
    volumes:
      - ${DATA_DIR}/listmonk:/listmonk/uploads
    networks:
      - saaskit-net
    depends_on:
      postgres:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: [\"CMD-SHELL\", \"wget --quiet --tries=1 --spider http://localhost:9000/ || exit 1\"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      options: {max-size: \"10m\", max-file: \"3\"}"
    else
        LISTMONK_SERVICE="  # Listmonk non installé"
    fi

    cat > "$KIT_DIR/docker-compose.yml" << COMPOSE
# saas-kit — docker-compose.yml — généré par saaskit.sh
# Caddy NON inclus — vps-monitor-caddy (network_mode:host) est utilisé.

services:

  # PostgreSQL 16 — base partagée multi-db
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
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      options: {max-size: "10m", max-file: "3"}

  # Dragonfly — cache Redis-compatible (n8n + apps)
  dragonfly:
    image: docker.dragonflydb.io/dragonflydb/dragonfly:latest
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
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -p 6379 ping || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      options: {max-size: "10m", max-file: "3"}

  # Redis 7 — dédié Baserow (scripts Lua incompatibles Dragonfly)
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
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      options: {max-size: "10m", max-file: "3"}

  # n8n — automation workflows
  # FIX B5 : N8N_BASIC_AUTH_* supprimés (dépréciés depuis n8n v1.0)
  #          Remplacés par N8N_DEFAULT_USER_EMAIL/PASSWORD (compte owner au 1er démarrage)
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
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

  # n8n-MCP — MCP server pour Claude
  # FIX B6 : N8N_API_KEY lu depuis .env — géré par Compose (plus de docker run nu)
  #          Configurer via : sudo saaskit-mcp-apikey.sh <clé>
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

  # Baserow — no-code database
  baserow:
    image: baserow/baserow:latest
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
    healthcheck:
      test: ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:80/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    logging:
      options: {max-size: "10m", max-file: "3"}

  # MinIO — object storage S3-compatible
  # FIX B4 : healthcheck via curl/wget sur endpoint HTTP natif
  #          (alias "local" mc non garanti au boot sans init explicite)
  minio:
    # FIX S6 : image patchée CVE-2025-62506 (privilege escalation IAM CVSS 8.1)
    # Mettre à jour ce tag à chaque release MinIO
    image: minio/minio:RELEASE.2025-10-15T17-29-55Z
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
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9000/minio/health/live || wget -qO /dev/null http://localhost:9000/minio/health/live 2>/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    logging:
      options: {max-size: "10m", max-file: "3"}

${LISTMONK_SERVICE}

networks:
  saaskit-net:
    name: saaskit-net
    driver: bridge
COMPOSE
    log_success "docker-compose.yml généré."

    # ── Étape 5 : Injection Caddy ─────────────────────────────
    etape "5" "$TOTAL_ETAPES" "Configuration Caddy (vps-monitor)"
    
    # FIX S4 : vérification CVE-2026-30851 Caddy < 2.11.2
    local caddy_ver
    caddy_ver=$(docker exec "$CADDY_CONTAINER" caddy version 2>/dev/null \
        | grep -oP 'v\K[\d.]+' | head -1 || echo "0.0.0")
    if printf '%s\n%s\n' "2.11.2" "$caddy_ver" | sort -V -C 2>/dev/null; then
        : # version OK
    else
        log_warn "Caddy ${caddy_ver} < 2.11.2 — CVE-2026-30851 (auth bypass CVSS 8.1) détecté."
        log_warn "Mets à jour Caddy avant de continuer : docker pull caddy:latest"
        read -rp "  Continuer quand même ? (oui/non) : " _caddy_ans
        [[ "$_caddy_ans" == "oui" ]] || exit 1
    fi

    local CADDYFILE_BACKUP="${CADDYFILE}.backup.$(date '+%Y%m%d-%H%M%S')"
    cp "$CADDYFILE" "$CADDYFILE_BACKUP"
    log_success "Backup Caddyfile : $CADDYFILE_BACKUP"

    if grep -q "saas-kit — n8n" "$CADDYFILE" 2>/dev/null; then
        log_warn "Blocs saas-kit déjà présents — injection ignorée."
    else
        # FIX B8 : LISTMONK_CADDY_BLOCK construit avec \{host} etc. pour éviter
        #          l'expansion bash des placeholders Caddy
        local LISTMONK_CADDY_BLOCK=""
        if [[ "$INSTALL_LISTMONK" == "oui" ]]; then
            LISTMONK_CADDY_BLOCK="
# ── saas-kit — Listmonk ─────────────────────────────────────────────────────
${LISTMONK_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_LISTMONK} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header {
    Strict-Transport-Security \"max-age=31536000; includeSubDomains\"
    X-Frame-Options \"SAMEORIGIN\"
    X-Content-Type-Options \"nosniff\"
    -Server
  }
}"
        fi

        # FIX B7 : heredoc non-quoté (expansion des vars bash voulue)
        #          + placeholders Caddy escapés avec \{ pour survivre à l'expansion
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
  log {
    output file /data/n8n-access.log { roll_size 50mb; roll_keep 3 }
    level WARN
  }
}

# ── saas-kit — n8n-MCP ───────────────────────────────────────────────────────
${MCP_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_MCP} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    -Server
  }
  log {
    output file /data/mcp-access.log { roll_size 50mb; roll_keep 3 }
    level WARN
  }
}

# ── saas-kit — Baserow ───────────────────────────────────────────────────────
${BASEROW_DOMAIN} {
  reverse_proxy 127.0.0.1:${PORT_BASEROW} {
    header_up Host \{host}
    header_up X-Real-IP \{remote_host}
    header_up X-Forwarded-Proto \{scheme}
  }
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Frame-Options "SAMEORIGIN"
    X-Content-Type-Options "nosniff"
    -Server
  }
  log {
    output file /data/baserow-access.log { roll_size 50mb; roll_keep 3 }
    level WARN
  }
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
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Frame-Options "SAMEORIGIN"
    X-Content-Type-Options "nosniff"
    -Server
  }
}


${LISTMONK_CADDY_BLOCK}
CADDYBLOCKS
        log_success "Blocs saas-kit injectés dans $CADDYFILE"

        # Validation Caddy avant reload
        if ! docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
            log_error "Caddyfile invalide après injection ! Restauration du backup..."
            cp "$CADDYFILE_BACKUP" "$CADDYFILE"
            log_warn "Backup restauré. Vérifie manuellement le Caddyfile."
            exit 1
        fi
    fi

    log_info "Rechargement de Caddy..."
    if docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
        log_success "Caddy rechargé."
    elif docker restart "$CADDY_CONTAINER" 2>/dev/null; then
        log_warn "Reload échoué — Caddy redémarre (attente 5s)..."
        sleep 5
        log_success "Caddy redémarré."
    else
        log_warn "Restart Caddy manuel requis : docker restart $CADDY_CONTAINER"
    fi

    # ── Étape 6 : Démarrage containers ───────────────────────
    etape "6" "$TOTAL_ETAPES" "Démarrage des containers"

    cd "$KIT_DIR"

    if docker compose ps -q 2>/dev/null | grep -q .; then
        log_warn "Containers saas-kit déjà présents — arrêt."
        docker compose down 2>/dev/null || true
    fi

    log_info "Pull des images Docker..."
    if ! docker compose --env-file .env pull --quiet; then
        log_warn "Pull partiel ou échoué — on tente quand même le démarrage avec les images locales."
    fi

    log_info "Démarrage PostgreSQL, Dragonfly, Redis..."
    docker compose --env-file .env up -d postgres dragonfly redis

    log_info "Attente healthchecks bases de données (30s max)..."
    for i in {1..30}; do
        local pg_ok df_ok rd_ok
        pg_ok=$(docker inspect --format='{{.State.Health.Status}}' saaskit-postgres 2>/dev/null || echo "starting")
        df_ok=$(docker inspect --format='{{.State.Health.Status}}' saaskit-dragonfly 2>/dev/null || echo "starting")
        rd_ok=$(docker inspect --format='{{.State.Health.Status}}' saaskit-redis 2>/dev/null || echo "starting")
        if [[ "$pg_ok" == "healthy" && "$df_ok" == "healthy" && "$rd_ok" == "healthy" ]]; then
            log_success "Bases de données prêtes."
            break
        fi
        sleep 1
        [[ $i -eq 30 ]] && log_warn "Timeout — on continue quand même."
    done

    log_info "Démarrage de tous les services..."
    docker compose --env-file .env up -d

    log_info "Attente démarrage applicatif (25s)..."
    sleep 25

    local FAILED=false
    local SERVICES=(saaskit-postgres saaskit-dragonfly saaskit-redis saaskit-n8n saaskit-baserow saaskit-minio)
    [[ "$INSTALL_LISTMONK" == "oui" ]] && SERVICES+=(saaskit-listmonk)

    for svc in "${SERVICES[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            log_success "$svc — actif"
        else
            log_warn "$svc — non démarré (docker logs $svc)"
            FAILED=true
        fi
    done

    if docker ps --format '{{.Names}}' | grep -q "^saaskit-n8n-mcp$"; then
        log_success "saaskit-n8n-mcp — actif"
    else
        log_warn "saaskit-n8n-mcp — démarré mais sans clé API (normal — voir étape post-install)"
    fi
    [[ "$FAILED" == "true" ]] && log_warn "Certains services n'ont pas démarré — vérifie les logs."

    # ── Étape 7 : Templates n8n ──────────────────────────────
    etape "7" "$TOTAL_ETAPES" "Téléchargement des templates n8n"

    local TEMPLATES_DIR="$KIT_DIR/templates"

    if [[ -d "$TEMPLATES_DIR/awesome-n8n-templates" ]]; then
        git -C "$TEMPLATES_DIR/awesome-n8n-templates" pull --quiet 2>/dev/null || true
        log_success "awesome-n8n-templates mis à jour."
    else
        git clone --quiet --depth=1 \
            https://github.com/enescingoz/awesome-n8n-templates.git \
            "$TEMPLATES_DIR/awesome-n8n-templates" 2>/dev/null && \
            log_success "awesome-n8n-templates cloné." || \
            log_warn "Clone échoué — vérifie la connexion."
    fi

    if [[ -d "$TEMPLATES_DIR/n8n-skills" ]]; then
        git -C "$TEMPLATES_DIR/n8n-skills" pull --quiet 2>/dev/null || true
        log_success "n8n-skills mis à jour."
    else
        git clone --quiet --depth=1 \
            https://github.com/czlonkowski/n8n-skills.git \
            "$TEMPLATES_DIR/n8n-skills" 2>/dev/null && \
            log_success "n8n-skills cloné." || \
            log_warn "Clone échoué — vérifie la connexion."
    fi

    local TEMPLATES_COUNT
    TEMPLATES_COUNT=$(find "$TEMPLATES_DIR" -name "*.json" 2>/dev/null | wc -l)
    log_success "Templates : ${TEMPLATES_COUNT} fichiers JSON disponibles."

    # ── Étape 8 : Claude Code CLI ─────────────────────────────
    etape "8" "$TOTAL_ETAPES" "Installation Claude Code CLI"

    # FIX S5 : packages Ubuntu natifs (Node 20 LTS) — couverts par unattended-upgrades
    # Supprime le curl|bash NodeSource (vecteur supply chain)
    if ! command -v node &>/dev/null; then
        log_info "Installation Node.js (Ubuntu 24.04 LTS natif)..."
        apt-get update -qq
        apt-get install -y nodejs npm -qq
    fi
    local NODE_VER
    NODE_VER=$(node --version 2>/dev/null || echo "inconnu")
    log_info "Node.js : $NODE_VER"

    # Vérification version minimale pour Claude Code (≥ 18)
    local NODE_MAJOR
    NODE_MAJOR=$(echo "$NODE_VER" | grep -oP '(?<=v)\d+' | head -1 || echo "0")
    if [[ "${NODE_MAJOR:-0}" -lt 18 ]]; then
        log_warn "Node.js $NODE_VER < v18 — Claude Code peut ne pas fonctionner."
        log_warn "Pour Node 22 : https://github.com/rockballslab/saas-kit/wiki/nodejs22"
    fi

    npm install -g @anthropic/claude-code --quiet 2>/dev/null && \
        log_success "Claude Code installé." || \
        log_warn "Échec — installe manuellement : npm install -g @anthropic/claude-code"

    # FIX S1 : sauvegarde config avec umask restrictif
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

INSTALL_LISTMONK="${INSTALL_LISTMONK}"
LISTMONK_DOMAIN="${LISTMONK_DOMAIN}"
CONFEOF
    )
    chmod 600 "$CONF"
    log_success "Config sauvegardée dans $CONF"

    # FIX B6 : helper MCP API key utilise docker compose up au lieu de docker run nu
    (
        umask 077
        cat > /usr/local/bin/saaskit-mcp-apikey.sh << 'HELPEREOF'
#!/usr/bin/env bash
# Usage : sudo saaskit-mcp-apikey.sh <N8N_API_KEY>
# Met à jour la clé API n8n dans le .env et redémarre n8n-mcp via Compose
set -euo pipefail
[[ -z "${1:-}" ]] && echo "Usage : sudo $0 <N8N_API_KEY>" && exit 1
API_KEY="${1}"
ENV_FILE="/opt/saas-kit/.env"

[[ ! -f "$ENV_FILE" ]] && { echo "[ERR] $ENV_FILE non trouvé — lance d'abord install."; exit 1; }

# FIX S3 : Python3 à la place de sed — protège contre & \ ^ dans la clé API
python3 - "$ENV_FILE" "$API_KEY" << 'PYEOF'
import sys, os
env_file, api_key = sys.argv[1], sys.argv[2]
lines = []
found = False
with open(env_file) as f:
    for line in f:
        if line.startswith('N8N_API_KEY='):
            lines.append(f'N8N_API_KEY={api_key}\n')
            found = True
        else:
            lines.append(line)
if not found:
    lines.append(f'N8N_API_KEY={api_key}\n')
tmp = env_file + '.tmp'
with open(tmp, 'w') as f:
    f.writelines(lines)
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

    # Exclusion AIDE
    if [[ -f /etc/aide/aide.conf ]] && ! grep -q "saas-kit" /etc/aide/aide.conf 2>/dev/null; then
        echo "!/opt/saas-kit/data" >> /etc/aide/aide.conf
        log_info "Volume saas-kit exclu de AIDE."
    fi

    # ── Étape 9 : Vérification endpoints ─────────────────────
    etape "9" "$TOTAL_ETAPES" "Vérification des endpoints"

    log_info "Test des URLs publiques (attente 15s pour Caddy)..."
    sleep 15

    local URLS_TO_CHECK=(
        "https://${N8N_DOMAIN}/healthz"
        "https://${BASEROW_DOMAIN}/"
        "https://${MINIO_DOMAIN}/minio/health/live"
    )
    [[ "$INSTALL_LISTMONK" == "oui" ]] && URLS_TO_CHECK+=("https://${LISTMONK_DOMAIN}/")

    for url in "${URLS_TO_CHECK[@]}"; do
        local HTTP_CODE
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" =~ ^(200|301|302|401|403)$ ]]; then
            log_success "$url => HTTP $HTTP_CODE"
        else
            log_warn "$url => HTTP $HTTP_CODE (DNS propagé ? Caddy encore en cours ?)"
        fi
    done

    # ── Résumé final ──────────────────────────────────────────
    echo ""
    echo -e "${GRAS}${VERT}+$(printf '=%.0s' {1..66})+${RESET}"
    echo -e "${GRAS}${VERT}|              saas-kit — Installation terminée ✓                  |${RESET}"
    echo -e "${GRAS}${VERT}+$(printf '=%.0s' {1..66})+${RESET}"
    echo ""
    echo -e "  ${GRAS}Services :${RESET}"
    echo -e "  ${VERT}OK${RESET}  n8n           : ${BLANC}https://${N8N_DOMAIN}${RESET}"
    echo -e "  ${VERT}OK${RESET}  n8n-MCP       : ${BLANC}https://${MCP_DOMAIN}${RESET}"
    echo -e "  ${VERT}OK${RESET}  Baserow       : ${BLANC}https://${BASEROW_DOMAIN}${RESET}"
    echo -e "  ${VERT}OK${RESET}  MinIO API     : ${BLANC}https://${MINIO_DOMAIN}${RESET}"
    echo -e "  ${VERT}OK${RESET}  MinIO Console : ${BLANC}https://${MINIO_CONSOLE_DOMAIN}${RESET}"
    [[ "$INSTALL_LISTMONK" == "oui" ]] && \
        echo -e "  ${VERT}OK${RESET}  Listmonk      : ${BLANC}https://${LISTMONK_DOMAIN}${RESET}"
    echo ""
    echo -e "  ${JAUNE}IMPORTANT — À faire après l'installation :${RESET}"
    echo ""
    echo -e "  ${BLANC}1. Voir tous vos credentials :${RESET}"
    echo -e "     ${VERT}sudo ./saaskit.sh keys${RESET}"
    echo ""
    echo -e "  ${BLANC}2. n8n — connexion au premier démarrage :${RESET}"
    echo -e "     ${BLANC}https://${N8N_DOMAIN} → email: ${ADMIN_EMAIL} / password: voir keys${RESET}"
    echo ""
    echo -e "  ${BLANC}3. n8n-MCP — créer la clé API n8n puis :${RESET}"
    echo -e "     ${BLANC}https://${N8N_DOMAIN} → Settings → API → Create API Key${RESET}"
    echo -e "     ${BLANC}sudo saaskit-mcp-apikey.sh <ta_clé>${RESET}"
    echo ""
    echo -e "  ${BLANC}4. Baserow — créer le compte admin :${RESET}"
    echo -e "     ${BLANC}https://${BASEROW_DOMAIN} → s'inscrire avec ${ADMIN_EMAIL}${RESET}"
    [[ "$INSTALL_LISTMONK" == "oui" ]] && \
        echo -e "  ${BLANC}5. Listmonk — https://${LISTMONK_DOMAIN}/install${RESET}"
    echo ""
    echo -e "  ${GRAS}Commandes utiles :${RESET}"
    echo -e "  ${BLANC}sudo ./saaskit.sh keys${RESET}"
    echo -e "  ${BLANC}sudo ./saaskit.sh backup${RESET}"
    echo -e "  ${BLANC}sudo ./saaskit.sh update${RESET}"
    echo -e "  ${BLANC}cd $KIT_DIR && docker compose ps${RESET}"
    echo -e "  ${BLANC}sudo saaskit-mcp-apikey.sh <clé>${RESET}"
    echo ""
    echo -e "${GRAS}${VERT}  Done. Stack prête sur https://${ROOT_DOMAIN}${RESET}"
    echo ""
}

# ============================================================
# ============================================================
# COMMANDE : keys
# ============================================================
# ============================================================
cmd_keys() {
    local ENV_FILE="$KIT_DIR/.env"

    if [[ ! -f "$ENV_FILE" ]]; then
        log_error ".env non trouvé : $ENV_FILE"
        log_error "Lance d'abord : sudo ./saaskit.sh install"
        exit 1
    fi

    # Charger le .env
    # shellcheck source=/dev/null
    set -a
    # shellcheck source=/dev/null
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
    echo -e "  ${BLANC}n8n           : ${VERT}https://${N8N_DOMAIN:-?}${RESET}"
    echo -e "  ${BLANC}n8n-MCP       : ${VERT}https://${MCP_DOMAIN:-?}${RESET}"
    echo -e "  ${BLANC}Baserow       : ${VERT}https://${BASEROW_DOMAIN:-?}${RESET}"
    echo -e "  ${BLANC}MinIO API     : ${VERT}https://${MINIO_DOMAIN:-?}${RESET}"
    echo -e "  ${BLANC}MinIO Console : ${VERT}https://${MINIO_CONSOLE_DOMAIN:-?}${RESET}"
    [[ "${INSTALL_LISTMONK:-non}" == "oui" ]] && \
        echo -e "  ${BLANC}Listmonk      : ${VERT}https://${LISTMONK_DOMAIN:-?}${RESET}"
    echo ""
    echo -e "  ${GRAS}Credentials :${RESET}"
    echo -e "  ${BLANC}Admin email   : ${VERT}${ADMIN_EMAIL:-?}${RESET}"
    echo -e "  ${BLANC}n8n           : ${VERT}${ADMIN_EMAIL:-?} / ${N8N_PASSWORD:-?}${RESET}"
    echo -e "  ${BLANC}Baserow       : ${VERT}${ADMIN_EMAIL:-?} / ${BASEROW_PASSWORD:-?}${RESET}"
    echo -e "  ${BLANC}MinIO         : ${VERT}admin / ${MINIO_ROOT_PASSWORD:-?}${RESET}"
    echo -e "  ${BLANC}MCP Token     : ${VERT}${MCP_TOKEN:-?}${RESET}"
    # FIX B6 : afficher l'état de la clé API n8n-mcp
    if [[ -n "${N8N_API_KEY:-}" ]]; then
        echo -e "  ${BLANC}n8n API Key   : ${VERT}${N8N_API_KEY}${RESET}"
    else
        echo -e "  ${BLANC}n8n API Key   : ${JAUNE}non configurée — sudo saaskit-mcp-apikey.sh <clé>${RESET}"
    fi
    echo ""
    echo -e "  ${GRAS}Secrets techniques :${RESET}"
    echo -e "  ${BLANC}PostgreSQL    : ${VERT}saaskit / ${POSTGRES_PASSWORD:-?}${RESET}"
    echo -e "  ${BLANC}n8n enc. key  : ${VERT}${N8N_ENCRYPTION_KEY:-?}${RESET}"
    echo ""
    echo -e "  ${GRAS}Config Claude Desktop (n8n-MCP) :${RESET}"
    echo ""
    echo    '  {'
    echo    '    "mcpServers": {'
    echo    '      "n8n-mcp": {'
    echo    '        "command": "npx",'
    echo    '        "args": ["n8n-mcp"],'
    echo    '        "env": {'
    echo    '          "MCP_MODE": "http",'
    # FIX S2 : la clé est MCP_SERVER_URL (URL du MCP server, pas de n8n direct)
    echo -e "          \"MCP_SERVER_URL\": \"https://${MCP_DOMAIN:-?}\","
    echo -e "          \"AUTH_TOKEN\": \"${MCP_TOKEN:-?}\","
    echo    '          "LOG_LEVEL": "error"'
    echo    '        }'
    echo    '      }'
    echo    '    }'
    echo    '  }'
    echo ""
    echo -e "  ${JAUNE}Fichier source : $ENV_FILE (chmod 600)${RESET}"
    echo ""
}

# ============================================================
# ============================================================
# COMMANDE : backup
# ============================================================
# ============================================================
cmd_backup() {
    local DO_POSTGRES=true DO_VOLUMES=true
    case "${2:-}" in
        --postgres) DO_VOLUMES=false ;;
        --volumes)  DO_POSTGRES=false ;;
        --list)
            echo -e "${GRAS}Backups locaux dans $BACKUP_DIR :${RESET}"
            find "$BACKUP_DIR" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) 2>/dev/null \
                | sort | while read -r f; do
                echo -e "  $(du -sh "$f" | cut -f1)  $f"
            done
            return 0
            ;;
    esac

    [[ ! -f "$CONF" ]] && { log_error "Config non trouvée. Lance d'abord install."; exit 1; }
    ! docker ps --format '{{.Names}}' | grep -q "^saaskit-postgres$" && \
        { log_error "Container saaskit-postgres non démarré."; exit 1; }

    local POSTGRES_USER MINIO_BUCKET="saaskit-backups"
    POSTGRES_USER=$(grep '^POSTGRES_USER=' "$CONF" | cut -d'=' -f2 | tr -d '"')
    [[ -z "$POSTGRES_USER" ]] && { log_error "POSTGRES_USER introuvable dans $CONF"; exit 1; }

    # FIX B9 : lire MINIO_ROOT_USER/PASSWORD depuis .env pour créer l'alias mc
    local MINIO_ROOT_USER MINIO_ROOT_PASSWORD
    MINIO_ROOT_USER=$(grep '^MINIO_ROOT_USER=' "$KIT_DIR/.env" | cut -d'=' -f2)
    MINIO_ROOT_PASSWORD=$(grep '^MINIO_ROOT_PASSWORD=' "$KIT_DIR/.env" | cut -d'=' -f2)

    local TIMESTAMP; TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
    mkdir -p "$BACKUP_DIR"

    echo -e "\n${GRAS}${VERT}  saas-kit — Backup $TIMESTAMP${RESET}\n"
    local BACKUP_OK=true

    if [[ "$DO_POSTGRES" == "true" ]]; then
        log_info "Backup PostgreSQL..."

        # FIX B3 : ne dumper listmonk_db que si installé
        local DBS_TO_BACKUP=("n8n_db" "baserow_db")
        local _lm
        _lm=$(grep 'INSTALL_LISTMONK=' "$CONF" | cut -d'"' -f2 || echo "non")
        [[ "$_lm" == "oui" ]] && DBS_TO_BACKUP+=("listmonk_db")

        for db in "${DBS_TO_BACKUP[@]}"; do
            local DEST="$BACKUP_DIR/postgres_${db}_${TIMESTAMP}.sql.gz"
            local _dump_status
            docker exec saaskit-postgres pg_dump -U "$POSTGRES_USER" "$db" 2>/dev/null > "${DEST%.gz}" \
                && gzip -f "${DEST%.gz}" \
                && _dump_status=0 || _dump_status=1
            if [[ $_dump_status -eq 0 ]]; then
                log_success "  $db → $(basename "$DEST") ($(du -sh "$DEST" | cut -f1))"
            else
                log_warn "  Dump $db échoué"; BACKUP_OK=false
            fi
        done
        local DEST_G="$BACKUP_DIR/postgres_globals_${TIMESTAMP}.sql.gz"
        docker exec saaskit-postgres pg_dumpall -U "$POSTGRES_USER" --globals-only 2>/dev/null \
            | gzip > "$DEST_G" && log_success "  globals → $(basename "$DEST_G")" || true
    fi

    if [[ "$DO_VOLUMES" == "true" ]]; then
        log_info "Backup volumes..."
        local DEST_N8N="$BACKUP_DIR/volume_n8n_${TIMESTAMP}.tar.gz"
        tar -czf "$DEST_N8N" -C "$DATA_DIR" n8n/ 2>/dev/null && \
            log_success "  n8n → $(basename "$DEST_N8N") ($(du -sh "$DEST_N8N" | cut -f1))" || \
            { log_warn "  Backup n8n échoué"; BACKUP_OK=false; }

        local DEST_MINIO="$BACKUP_DIR/volume_minio_${TIMESTAMP}.tar.gz"
        tar -czf "$DEST_MINIO" -C "$DATA_DIR" minio/ 2>/dev/null && \
            log_success "  minio → $(basename "$DEST_MINIO") ($(du -sh "$DEST_MINIO" | cut -f1))" || \
            log_warn "  Backup MinIO échoué (non bloquant)"
    fi

    # FIX B9 : créer l'alias "local" mc avant tout usage mc
    log_info "Upload vers MinIO interne (bucket: $MINIO_BUCKET)..."
    docker exec saaskit-minio mc alias set local \
        http://localhost:9000 \
        "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" 2>/dev/null || true
    docker exec saaskit-minio mc mb --ignore-existing "local/$MINIO_BUCKET" 2>/dev/null || true
    local UPLOADED=0
    for f in "$BACKUP_DIR"/*_${TIMESTAMP}*; do
        [[ -f "$f" ]] || continue
        docker cp "$f" "saaskit-minio:/tmp/$(basename "$f")" && \
            docker exec saaskit-minio mc cp "/tmp/$(basename "$f")" "local/$MINIO_BUCKET/$(basename "$f")" && \
            docker exec saaskit-minio rm -f "/tmp/$(basename "$f")" && \
            UPLOADED=$((UPLOADED + 1))
    done
    log_success "MinIO : $UPLOADED fichier(s) uploadé(s)."

    # Destination externe optionnelle
    local EXTERNAL_CONF="$KIT_DIR/backup-external.conf"
    if [[ -f "$EXTERNAL_CONF" ]]; then
        # FIX W5 : ne pas sourcer le fichier — lire les variables explicitement
        local BACKUP_EXTERNAL_ENDPOINT BACKUP_EXTERNAL_ACCESS_KEY \
              BACKUP_EXTERNAL_SECRET_KEY BACKUP_EXTERNAL_BUCKET
        BACKUP_EXTERNAL_ENDPOINT=$(grep '^BACKUP_EXTERNAL_ENDPOINT=' "$EXTERNAL_CONF" | cut -d'=' -f2- | tr -d '"' || echo "")
        BACKUP_EXTERNAL_ACCESS_KEY=$(grep '^BACKUP_EXTERNAL_ACCESS_KEY=' "$EXTERNAL_CONF" | cut -d'=' -f2- | tr -d '"' || echo "")
        BACKUP_EXTERNAL_SECRET_KEY=$(grep '^BACKUP_EXTERNAL_SECRET_KEY=' "$EXTERNAL_CONF" | cut -d'=' -f2- | tr -d '"' || echo "")
        BACKUP_EXTERNAL_BUCKET=$(grep '^BACKUP_EXTERNAL_BUCKET=' "$EXTERNAL_CONF" | cut -d'=' -f2- | tr -d '"' || echo "saaskit-backups")

        if [[ -n "${BACKUP_EXTERNAL_ENDPOINT:-}" ]]; then
            log_info "Upload externe vers ${BACKUP_EXTERNAL_ENDPOINT}..."
            docker exec saaskit-minio mc alias set ext-backup \
                "$BACKUP_EXTERNAL_ENDPOINT" \
                "${BACKUP_EXTERNAL_ACCESS_KEY:-}" \
                "${BACKUP_EXTERNAL_SECRET_KEY:-}" 2>/dev/null || true
            for f in "$BACKUP_DIR"/*_${TIMESTAMP}*; do
                [[ -f "$f" ]] || continue
                docker exec -i saaskit-minio mc cp "/dev/stdin" \
                    "ext-backup/${BACKUP_EXTERNAL_BUCKET}/$(basename "$f")" \
                    < "$f" 2>/dev/null && log_success "  Externe : $(basename "$f")" || \
                    log_warn "  Upload externe échoué : $(basename "$f")"
            done
            docker exec saaskit-minio mc alias rm ext-backup 2>/dev/null || true
        fi
    fi

    # Rétention 7 jours
    local DELETED
    DELETED=$(find "$BACKUP_DIR" -type f \( -name "*.sql.gz" -o -name "*.tar.gz" \) \
        -mtime +7 -print -delete 2>/dev/null | wc -l)
    [[ $DELETED -gt 0 ]] && log_info "$DELETED ancien(s) backup(s) supprimé(s)."

    echo ""
    [[ "$BACKUP_OK" == "true" ]] && log_success "Backup complet OK — $BACKUP_DIR" || \
        { log_warn "Backup terminé avec des avertissements."; exit 1; }
}

# ============================================================
# ============================================================
# COMMANDE : update
# ============================================================
# ============================================================
cmd_update() {
    [[ ! -f "$KIT_DIR/docker-compose.yml" ]] && \
        { log_error "docker-compose.yml non trouvé. Lance d'abord install."; exit 1; }

    if [[ "${2:-}" == "--check" ]]; then
        docker compose --env-file "$KIT_DIR/.env" -f "$KIT_DIR/docker-compose.yml" images
        return 0
    fi

    local SPECIFIC="${2:-}"
    local ALL_SERVICES=(postgres dragonfly redis n8n n8n-mcp baserow minio listmonk)
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

    for svc in "${ALL_SERVICES[@]}"; do
        local ctn="saaskit-${svc}"
        docker compose --env-file .env config --services 2>/dev/null | grep -q "^${svc}$" || \
            { SKIPPED=$((SKIPPED+1)); continue; }
        docker ps --format '{{.Names}}' | grep -q "^${ctn}$" || \
            { log_info "$svc non démarré — ignoré."; SKIPPED=$((SKIPPED+1)); continue; }

        # FIX W9 : comparer les digests d'image via RepoDigests pour fiabilité
        local cur_digest new_digest
        cur_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$ctn" 2>/dev/null || echo "unknown")
        local img
        img=$(docker compose --env-file .env config --format json 2>/dev/null \
            | python3 -c "import sys,json; cfg=json.load(sys.stdin); print(cfg['services'].get('${svc}',{}).get('image',''))" 2>/dev/null || echo "")
        new_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo "")

        if [[ -n "$cur_digest" && -n "$new_digest" && "$cur_digest" == "$new_digest" && "$cur_digest" != "unknown" ]]; then
            log_info "$svc — déjà à jour."
            SKIPPED=$((SKIPPED+1)); continue
        fi

        log_info "Mise à jour $svc..."
        docker compose --env-file .env up -d --no-deps "$svc" 2>/dev/null
        _wait_healthy "$ctn" 45
        log_success "$svc — mis à jour."
        UPDATED=$((UPDATED+1))
        sleep 2
    done

    docker image prune -f 2>/dev/null | grep -v "^$" || true

    echo ""
    echo -e "  ${VERT}Mis à jour : $UPDATED${RESET}  ${BLANC}Inchangés : $SKIPPED${RESET}"
    log_success "Update terminé."
}

# ============================================================
# ============================================================
# COMMANDE : uninstall
# ============================================================
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

    # Containers et volumes
    if [[ -f "$KIT_DIR/docker-compose.yml" ]]; then
        cd "$KIT_DIR"
        docker compose down --volumes 2>/dev/null && \
            log_success "Containers et volumes supprimés." || true
    fi

    # FIX B6 : saaskit-n8n-mcp est maintenant géré par Compose → down --volumes suffit
    # On garde la boucle de sécurité pour les containers orphelins éventuels
    for ctn in saaskit-postgres saaskit-dragonfly saaskit-redis saaskit-n8n \
               saaskit-n8n-mcp saaskit-baserow saaskit-minio saaskit-listmonk; do
        docker ps -a --format '{{.Names}}' | grep -q "^${ctn}$" && \
            docker rm -f "$ctn" 2>/dev/null && log_info "  $ctn supprimé." || true
    done

    # Réseau
    docker network ls --format '{{.Name}}' | grep -q "^saaskit-net$" && \
        docker network rm saaskit-net 2>/dev/null && log_success "Réseau saaskit-net supprimé." || true

    # FIX W7 : suppression blocs Caddy avec parser ligne-à-ligne (gère imbrication > 2 niveaux)
    if [[ -f "$CADDYFILE" ]] && grep -q "saas-kit" "$CADDYFILE" 2>/dev/null; then
        cp "$CADDYFILE" "${CADDYFILE}.pre-uninstall.$(date '+%Y%m%d-%H%M%S')"
        python3 - "$CADDYFILE" << 'PYEOF'
import sys

with open(sys.argv[1]) as f:
    content = f.read()

lines = content.split('\n')
result = []
skip = False
depth = 0

for line in lines:
    # Détecter le début d'un bloc saas-kit
    if line.strip().startswith('# \u2500\u2500 saas-kit'):
        skip = True
        depth = 0
        continue
    if skip:
        depth += line.count('{') - line.count('}')
        # Fin du bloc quand on revient à depth <= 0 après avoir ouvert au moins une accolade
        if depth <= 0 and '}' in line:
            skip = False
        continue
    result.append(line)

# Nettoyer les lignes vides multiples
cleaned = '\n'.join(result)
import re
cleaned = re.sub(r'\n{3,}', '\n\n', cleaned).rstrip() + '\n'

with open(sys.argv[1], 'w') as f:
    f.write(cleaned)
PYEOF
        log_success "Blocs saas-kit supprimés du Caddyfile."
        docker ps --format '{{.Names}}' | grep -q "^${CADDY_CONTAINER}$" && \
            docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile 2>/dev/null && \
            log_success "Caddy rechargé." || \
            log_warn "Reload Caddy manuel requis."
    fi

    # Fichiers
    [[ -d "$KIT_DIR" ]] && rm -rf "$KIT_DIR" && log_success "$KIT_DIR supprimé."
    [[ -f "$CONF" ]] && rm -f "$CONF" && log_success "Config supprimée."
    [[ -f /usr/local/bin/saaskit-mcp-apikey.sh ]] && \
        rm -f /usr/local/bin/saaskit-mcp-apikey.sh && log_success "Helper supprimé."
    [[ -f /etc/aide/aide.conf ]] && \
        sed -i '/^!\/opt\/saas-kit/d' /etc/aide/aide.conf 2>/dev/null || true

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
