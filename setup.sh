#!/usr/bin/env bash
# ARTIFEX setup: from a fresh checkout to a running, configured console in one command.
#
# When this script finishes:
#   - PostgreSQL is running and the schema is created
#   - ARTIFEX is built and running in the background (and restarts on failure)
#   - the admin password is set (saved to .artifex/credentials, mode 600)
#   - an LLM profile is created and activated, if you supplied a key
#   - the console answers on http://127.0.0.1:8787
#
# Usage:
#   ./setup.sh [options]           install / reinstall and start
#   ./setup.sh status|start|stop|restart|logs   manage an existing install
#
# Run ./setup.sh --help for all options. Re-running is safe: generated passwords
# are reused from .artifex/state.env and nothing that exists is overwritten
# without reason.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

STATE_DIR="$ROOT/.artifex"
STATE_FILE="$STATE_DIR/state.env"
CRED_FILE="$STATE_DIR/credentials"
LOG_FILE="$STATE_DIR/artifex.log"
PID_FILE="$STATE_DIR/artifex.pid"
TOOLCHAIN_DIR="$ROOT/.toolchain"

GO_VERSION="1.27.3"          # matches go.mod
NODE_MAJOR="24"              # LTS used by the Dockerfile; 20 and 22 also build
NODE_MIN_MAJOR="20"
PG_CONTAINER="artifex-pg"
PG_DOCKER_PORT="5433"        # avoids clashing with a system Postgres on 5432
PROFILE_NAME="Setup default"
SERVICE_NAME="artifex"

# ── defaults (flags override, env vars seed) ──────────────────────────────
MODE=""                                  # docker | native (auto when empty)
DB_MODE=""                               # docker | system | dsn (native only)
PG_DSN="${ARTIFEX_PG_DSN:-}"
ADMIN_PASSWORD="${ARTIFEX_ADMIN_PASSWORD:-}"
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
LLM_MODEL="${ARTIFEX_LLM_MODEL:-}"
LLM_BASE_URL="${ARTIFEX_LLM_BASE_URL:-}"
SKIP_LLM=0
SKIP_LLM_TEST=0
SKIP_BUILD=0
EXPOSE=0
PORT=8787
PROXY_PORT=8788
ASSUME_YES=0

# ── output helpers ─────────────────────────────────────────────────────────
if [ -t 1 ]; then C_I=$'\033[36m'; C_OK=$'\033[32m'; C_W=$'\033[33m'; C_E=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else C_I=""; C_OK=""; C_W=""; C_E=""; C_B=""; C_0=""; fi
info(){ printf '%s[*]%s %s\n' "$C_I" "$C_0" "$*"; }
ok(){   printf '%s[+]%s %s\n' "$C_OK" "$C_0" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$C_W" "$C_0" "$*" >&2; }
die(){  printf '%s[x]%s %s\n' "$C_E" "$C_0" "$*" >&2; exit 1; }
step(){ printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
have(){ command -v "$1" >/dev/null 2>&1; }
interactive(){ [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; }
rand(){ LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}" || true; }

usage(){
  cat <<'EOF'
ARTIFEX setup

Usage: ./setup.sh [options]
       ./setup.sh status | start | stop | restart | logs

Install modes:
  --mode docker          App and Postgres in Docker. Bundles the scanning tools
                         (nmap, ripgrep, playwright...). Default when Docker runs.
  --mode native          Build a native binary. Default when Docker is not running.

Database (native mode):
  --db docker            Postgres in a Docker container on 127.0.0.1:5433 (default
                         when Docker runs)
  --db system            Install/start the system PostgreSQL and create the database
  --db dsn --pg-dsn URL  Use an existing database, e.g.
                         postgres://user:pass@host:5432/artifex?sslmode=require

Admin account:
  --admin-password PW    Admin password (default: random, saved to
                         .artifex/credentials). Env: ARTIFEX_ADMIN_PASSWORD

LLM (stored as an LLM profile in the app, not in environment files):
  --anthropic-key KEY    Env: ANTHROPIC_API_KEY
  --openai-key KEY       Env: OPENAI_API_KEY
  --model ID             Default: claude-opus-5-5 (Anthropic) or gpt-4o (OpenAI)
  --base-url URL         OpenAI-compatible endpoint (Ollama, vLLM...); key optional
  --no-llm               Skip LLM setup
  --skip-llm-test        Do not send a test request after saving the profile

Network:
  --port N               Console port (default 8787)
  --proxy-port N         Traffic-capture proxy port (default 8788)
  --expose               Listen on all interfaces instead of 127.0.0.1.
                         Only do this on a trusted, firewalled network.

Other:
  --skip-build           Native mode: reuse the existing ./artifex binary
  -y, --yes              Never prompt; use defaults
  -h, --help             Show this help
EOF
}

# ── state (generated secrets survive re-runs) ─────────────────────────────
load_state(){ [ -f "$STATE_FILE" ] && . "$STATE_FILE" || true; }
save_state(){ # save_state KEY VALUE
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  local tmp; tmp="$(mktemp "$STATE_DIR/.state.XXXXXX")"
  grep -v "^$1=" "$STATE_FILE" >"$tmp" || true
  printf "%s='%s'\n" "$1" "$2" >>"$tmp"
  mv "$tmp" "$STATE_FILE"; chmod 600 "$STATE_FILE"
}

# ── tiny JSON helpers (no jq dependency) ──────────────────────────────────
json_str(){ # quote a value for JSON; rejects control characters
  local s="$1"
  case "$s" in *[$'\n\r\t']*) die "Value contains a newline or tab; refusing to send it" ;; esac
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  printf '"%s"' "$s"
}
json_get(){ # json_get FIELD  (reads one JSON object on stdin; first match)
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -n1
}

BASE_URL=""
TOKEN=""
api(){ # api METHOD PATH [JSON]  → prints body; returns non-zero on HTTP >= 400
  local method="$1" path="$2" body="${3:-}" out code
  local args=(-sS -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}' --max-time 120)
  [ -n "$TOKEN" ] && args+=(-H "Authorization: Bearer $TOKEN")
  [ -n "$body" ] && args+=(--data-binary @-)
  out="$(printf '%s' "$body" | curl "${args[@]}" "$BASE_URL$path")" || return 1
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  printf '%s' "$out"
  [ "$code" -lt 400 ]
}

# ── platform ───────────────────────────────────────────────────────────────
detect_platform(){
  case "$(uname -s)" in
    Linux) OS=linux ;; Darwin) OS=darwin ;;
    *) die "Unsupported OS $(uname -s). On Windows, use WSL2 or the prebuilt release archive." ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64; NODE_ARCH=x64 ;;
    aarch64|arm64) ARCH=arm64; NODE_ARCH=arm64 ;;
    *) die "Unsupported CPU architecture $(uname -m)" ;;
  esac
  have curl || die "curl is required. Install it with your package manager and re-run."
}

SUDO=""
need_root(){ # sets SUDO for commands that need root
  if [ "$(id -u)" -eq 0 ]; then SUDO=""
  elif have sudo; then SUDO="sudo"
  else die "This step needs root and sudo is not installed: $*"; fi
}

sha256_of(){ if have sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

docker_ready(){ have docker && docker info >/dev/null 2>&1; }
compose_ready(){ docker_ready && docker compose version >/dev/null 2>&1; }

port_busy(){ # port_busy PORT
  if have ss; then ss -ltnH "( sport = :$1 )" 2>/dev/null | grep -q .
  elif have lsof; then lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; fi
}

# ── toolchains (native mode) ───────────────────────────────────────────────
ensure_go(){
  if have go; then
    # Go >= 1.21 fetches the go.mod toolchain automatically (GOTOOLCHAIN=auto).
    local v; v="$(go env GOVERSION 2>/dev/null | sed 's/^go//')"
    local major minor; major="${v%%.*}"; minor="$(echo "$v" | cut -d. -f2)"
    if [ "${major:-0}" -gt 1 ] || { [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -ge 21 ]; }; then
      ok "Go $v found (go.mod's Go $GO_VERSION is fetched automatically if needed)"
      return
    fi
    warn "Go $v is too old; installing Go $GO_VERSION locally"
  fi
  if [ -x "$TOOLCHAIN_DIR/go/bin/go" ]; then
    export PATH="$TOOLCHAIN_DIR/go/bin:$PATH"; ok "Using Go from $TOOLCHAIN_DIR/go"; return
  fi
  info "Downloading Go $GO_VERSION to $TOOLCHAIN_DIR/go"
  local tgz="go${GO_VERSION}.${OS}-${ARCH}.tar.gz" tmp; tmp="$(mktemp -d)"
  curl -fsSL "https://dl.google.com/go/$tgz" -o "$tmp/$tgz"
  curl -fsSL "https://dl.google.com/go/$tgz.sha256" -o "$tmp/sum"
  [ "$(sha256_of "$tmp/$tgz")" = "$(tr -d ' \n' <"$tmp/sum")" ] || die "Go download failed its checksum"
  mkdir -p "$TOOLCHAIN_DIR"; rm -rf "$TOOLCHAIN_DIR/go"
  tar -C "$TOOLCHAIN_DIR" -xzf "$tmp/$tgz"; rm -rf "$tmp"
  export PATH="$TOOLCHAIN_DIR/go/bin:$PATH"
  ok "Go $GO_VERSION installed (checksum verified)"
}

ensure_node(){
  if have node && have npm; then
    local major; major="$(node -p 'process.versions.node.split(".")[0]')"
    if [ "$major" -ge "$NODE_MIN_MAJOR" ]; then ok "Node.js $(node -v) found"; return; fi
    warn "Node.js $(node -v) is too old; installing Node.js $NODE_MAJOR locally"
  fi
  if [ -x "$TOOLCHAIN_DIR/node/bin/node" ]; then
    export PATH="$TOOLCHAIN_DIR/node/bin:$PATH"; ok "Using Node.js from $TOOLCHAIN_DIR/node"; return
  fi
  info "Downloading Node.js $NODE_MAJOR LTS to $TOOLCHAIN_DIR/node"
  local base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x" tmp line file sum
  tmp="$(mktemp -d)"
  curl -fsSL "$base/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
  line="$(grep " node-v[0-9.]*-${OS}-${NODE_ARCH}\.tar\.gz\$" "$tmp/SHASUMS256.txt" | head -n1)"
  [ -n "$line" ] || die "No Node.js build found for ${OS}-${NODE_ARCH}"
  sum="${line%% *}"; file="${line##* }"
  curl -fsSL "$base/$file" -o "$tmp/$file"
  [ "$(sha256_of "$tmp/$file")" = "$sum" ] || die "Node.js download failed its checksum"
  mkdir -p "$TOOLCHAIN_DIR"; rm -rf "$TOOLCHAIN_DIR/node"; mkdir "$TOOLCHAIN_DIR/node"
  tar -C "$TOOLCHAIN_DIR/node" --strip-components=1 -xzf "$tmp/$file"; rm -rf "$tmp"
  export PATH="$TOOLCHAIN_DIR/node/bin:$PATH"
  ok "Node.js $(node -v) installed (checksum verified)"
}

# ── database (native mode) ─────────────────────────────────────────────────
db_docker(){
  docker_ready || die "--db docker needs a running Docker daemon"
  DB_PASS="${DB_PASS:-$(rand 24)}"; save_state DB_PASS "$DB_PASS"
  if docker ps -a --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    info "Reusing container $PG_CONTAINER"
    docker start "$PG_CONTAINER" >/dev/null
  else
    port_busy "$PG_DOCKER_PORT" && die "Port $PG_DOCKER_PORT is in use; free it or use --db system / --db dsn"
    info "Starting PostgreSQL 16 in container $PG_CONTAINER (127.0.0.1:$PG_DOCKER_PORT)"
    docker run -d --name "$PG_CONTAINER" --restart unless-stopped \
      -p "127.0.0.1:$PG_DOCKER_PORT:5432" \
      -e POSTGRES_USER=artifex -e POSTGRES_PASSWORD="$DB_PASS" -e POSTGRES_DB=artifex \
      -v artifex-pg:/var/lib/postgresql/data postgres:16-alpine >/dev/null
  fi
  info "Waiting for PostgreSQL"
  local i; for i in $(seq 1 60); do
    docker exec "$PG_CONTAINER" pg_isready -U artifex -d artifex >/dev/null 2>&1 && break
    [ "$i" -eq 60 ] && die "PostgreSQL did not become ready; check: docker logs $PG_CONTAINER"
    sleep 1
  done
  # Keep the stored password in sync with a reused volume.
  docker exec -i "$PG_CONTAINER" psql -q -U artifex -d artifex \
    -c "ALTER USER artifex WITH PASSWORD '$DB_PASS';" >/dev/null
  PG_DSN="postgres://artifex:${DB_PASS}@127.0.0.1:${PG_DOCKER_PORT}/artifex?sslmode=disable"
  ok "PostgreSQL ready"
}

pg_sql(){ # pg_sql "SQL"  → runs as the database superuser, prints tuples only
  local psql_cmd='cd / && psql -X -v ON_ERROR_STOP=1 -q -tA -d postgres'
  if [ "$OS" = darwin ]; then printf '%s\n' "$1" | sh -c "$psql_cmd"
  elif [ "$(id -u)" -eq 0 ]; then printf '%s\n' "$1" | su postgres -s /bin/sh -c "$psql_cmd"
  else printf '%s\n' "$1" | sudo -u postgres sh -c "$psql_cmd"; fi
}

db_system(){
  if ! have psql || { [ "$OS" = linux ] && ! ls /usr/lib/postgresql/*/bin/postgres >/dev/null 2>&1 && ! have postgres; }; then
    info "Installing PostgreSQL"
    if [ "$OS" = darwin ]; then
      have brew || die "Install Homebrew (https://brew.sh) or use --db docker / --db dsn"
      brew install postgresql@16 && brew link --force postgresql@16
    elif have apt-get; then need_root "install postgresql"; $SUDO apt-get update -q; $SUDO apt-get install -y -q postgresql
    elif have dnf; then need_root "install postgresql"; $SUDO dnf install -y postgresql-server; $SUDO postgresql-setup --initdb || true
    elif have pacman; then need_root "install postgresql"; $SUDO pacman -S --noconfirm postgresql
    else die "No supported package manager found; use --db docker or --db dsn"; fi
  fi
  info "Starting PostgreSQL"
  if [ "$OS" = darwin ]; then brew services start postgresql@16 >/dev/null
  else
    need_root "start postgresql"
    if have systemctl && [ -d /run/systemd/system ]; then $SUDO systemctl enable --now postgresql >/dev/null 2>&1 || true
    elif have service; then $SUDO service postgresql start >/dev/null 2>&1 || true
    fi
  fi
  local i; for i in $(seq 1 30); do
    pg_sql 'SELECT 1' >/dev/null 2>&1 && break
    [ "$i" -eq 30 ] && die "Could not reach the local PostgreSQL as its superuser"
    sleep 1
  done
  DB_PASS="${DB_PASS:-$(rand 24)}"; save_state DB_PASS "$DB_PASS"
  pg_sql "DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='artifex') THEN CREATE ROLE artifex LOGIN PASSWORD '$DB_PASS';
    ELSE ALTER ROLE artifex WITH LOGIN PASSWORD '$DB_PASS'; END IF; END \$\$;"
  if ! pg_sql "SELECT 1 FROM pg_database WHERE datname='artifex'" | grep -q 1; then
    pg_sql "CREATE DATABASE artifex OWNER artifex;"
  fi
  local port; port="$(pg_sql 'SHOW port' | tr -d ' ')"
  PG_DSN="postgres://artifex:${DB_PASS}@127.0.0.1:${port:-5432}/artifex?sslmode=disable"
  ok "PostgreSQL ready (database 'artifex' on port ${port:-5432})"
}

# ── build (native mode) ────────────────────────────────────────────────────
build_native(){
  if [ "$SKIP_BUILD" -eq 1 ] && [ -x ./artifex ]; then ok "Reusing existing ./artifex"; return; fi
  info "Building the web console (npm ci + static export)"
  ( cd web && npm ci --no-audit --no-fund --loglevel=error && npm run build:static )
  mkdir -p server/webui/dist
  rm -rf server/webui/dist/* server/webui/dist/.[!.]* 2>/dev/null || true
  cp -R web/out/. server/webui/dist/
  info "Compiling the single binary"
  local ver; ver="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
  CGO_ENABLED=0 go build -tags embedui -trimpath \
    -ldflags "-s -w -X main.version=$ver" -o artifex ./cmd/artifex
  ok "Built ./artifex ($ver)"
}

write_config(){
  local tmp; tmp="$(mktemp "$ROOT/.config.XXXXXX")"
  cat >"$tmp" <<JSON
{
  "database": {
    "dsn": "$PG_DSN"
  }
}
JSON
  chmod 600 "$tmp"; mv "$tmp" config.json
  ok "Wrote config.json (mode 600)"
}

# ── run (native mode) ──────────────────────────────────────────────────────
listen_addrs(){
  if [ "$EXPOSE" -eq 1 ]; then ADDR=":$PORT"; PROXY_ADDR=":$PROXY_PORT"
  else ADDR="127.0.0.1:$PORT"; PROXY_ADDR="127.0.0.1:$PROXY_PORT"; fi
}

systemd_user_ok(){ [ "$OS" = linux ] && have systemctl && systemctl --user show-environment >/dev/null 2>&1; }

native_stop(){
  if systemd_user_ok && systemctl --user list-unit-files "$SERVICE_NAME.service" >/dev/null 2>&1 \
     && [ -f "$HOME/.config/systemd/user/$SERVICE_NAME.service" ]; then
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  if [ "$OS" = darwin ] && [ -f "$HOME/Library/LaunchAgents/com.artifex.console.plist" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/com.artifex.console.plist" 2>/dev/null || true
  fi
  if [ -f "$PID_FILE" ]; then
    local pid; pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      local i; for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
}

native_start(){
  listen_addrs
  mkdir -p "$STATE_DIR"
  if systemd_user_ok; then
    local unit="$HOME/.config/systemd/user/$SERVICE_NAME.service"
    mkdir -p "$(dirname "$unit")"
    cat >"$unit" <<EOF
[Unit]
Description=ARTIFEX console
After=network-online.target

[Service]
WorkingDirectory=$ROOT
ExecStart=$ROOT/start.sh -addr $ADDR -proxy $PROXY_ADDR
Environment=ARTIFEX_LANGUAGE=en
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now "$SERVICE_NAME" >/dev/null 2>&1
    systemctl --user restart "$SERVICE_NAME"
    save_state RUNNER systemd
    ok "Running as systemd user service '$SERVICE_NAME'"
    if have loginctl && ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q yes; then
      warn "The service stops when you log out. To keep it running: loginctl enable-linger $(id -un)"
    fi
  elif [ "$OS" = darwin ]; then
    local plist="$HOME/Library/LaunchAgents/com.artifex.console.plist"
    mkdir -p "$(dirname "$plist")"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.artifex.console</string>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>ProgramArguments</key><array>
    <string>$ROOT/start.sh</string><string>-addr</string><string>$ADDR</string>
    <string>-proxy</string><string>$PROXY_ADDR</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>ARTIFEX_LANGUAGE</key><string>en</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_FILE</string>
  <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict></plist>
EOF
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load -w "$plist"
    save_state RUNNER launchd
    ok "Running as launchd agent com.artifex.console"
  else
    ARTIFEX_LANGUAGE=en nohup ./start.sh -addr "$ADDR" -proxy "$PROXY_ADDR" >>"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    save_state RUNNER nohup
    ok "Running in the background (pid $(cat "$PID_FILE"), log $LOG_FILE)"
  fi
}

# ── docker mode ────────────────────────────────────────────────────────────
set_env_var(){ # set_env_var KEY VALUE  (in .env; replaces active or commented line)
  local tmp; tmp="$(mktemp "$ROOT/.env.XXXXXX")"
  awk -v k="$1" -v v="$2" '
    BEGIN { done = 0 }
    $0 ~ "^[#[:space:]]*" k "=" { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }' .env >"$tmp"
  chmod 600 "$tmp"; mv "$tmp" .env
}

install_docker_mode(){
  compose_ready || die "Docker with the compose plugin is required for --mode docker (or use --mode native)"
  listen_addrs
  [ -f .env ] || cp .env.example .env
  chmod 600 .env
  local pw; pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' .env | head -n1)"
  if [ -z "$pw" ] || [ "$pw" = "change-me-please" ]; then
    set_env_var POSTGRES_PASSWORD "$(rand 24)"; ok "Generated a Postgres password in .env"
  fi
  set_env_var ARTIFEX_BIND_ADDR "$ADDR"
  set_env_var ARTIFEX_PROXY_ADDR "$PROXY_ADDR"
  if port_busy 5432 && ! docker compose ps --status running postgres 2>/dev/null | grep -q postgres; then
    die "Port 5432 is already in use (a local Postgres?). Stop it, or use --mode native."
  fi
  info "Building the image and starting containers (first build takes several minutes)"
  docker compose up -d --build
  save_state RUNNER docker
  ok "Containers started"
}

# ── post-start configuration (both modes) ──────────────────────────────────
wait_health(){
  info "Waiting for ARTIFEX to answer on $BASE_URL"
  local i; for i in $(seq 1 180); do
    if curl -fsS --max-time 3 "$BASE_URL/api/health" 2>/dev/null | grep -q '"ok":true'; then
      ok "ARTIFEX is up"; return
    fi
    sleep 1
  done
  warn "ARTIFEX did not answer within 3 minutes. Recent log output:"
  show_logs 40 || true
  die "Startup failed"
}

setup_admin(){
  local status initialized resp
  status="$(api GET /api/auth/status)" || die "Could not read admin status: $status"
  initialized="$(printf '%s' "$status" | json_get initialized)"
  if [ "$initialized" = "false" ]; then
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-${SAVED_ADMIN_PASSWORD:-$(rand 20)}}"
    [ "${#ADMIN_PASSWORD}" -ge 8 ] || die "The admin password must be at least 8 characters"
    resp="$(api POST /api/auth/init "{\"password\":$(json_str "$ADMIN_PASSWORD")}")" \
      || die "Could not set the admin password: $resp"
    TOKEN="$(printf '%s' "$resp" | json_get token)"
    save_state SAVED_ADMIN_PASSWORD "$ADMIN_PASSWORD"
    ok "Admin password set"
  else
    [ -n "$ADMIN_PASSWORD" ] || ADMIN_PASSWORD="${SAVED_ADMIN_PASSWORD:-}"
    if [ -z "$ADMIN_PASSWORD" ]; then
      warn "An admin password already exists and this script doesn't know it."
      warn "Pass --admin-password to configure the LLM here, or reset it with ./reset-password.sh"
      return
    fi
    resp="$(api POST /api/auth/login "{\"username\":\"ARTIFEX\",\"password\":$(json_str "$ADMIN_PASSWORD")}")" \
      || { warn "Login with the known admin password failed: $resp"; ADMIN_PASSWORD=""; return; }
    TOKEN="$(printf '%s' "$resp" | json_get token)"
    save_state SAVED_ADMIN_PASSWORD "$ADMIN_PASSWORD"
    ok "Logged in with the existing admin password"
  fi
  mkdir -p "$STATE_DIR"
  umask 077
  cat >"$CRED_FILE" <<EOF
ARTIFEX console: $BASE_URL
Username:        ARTIFEX
Password:        $ADMIN_PASSWORD
EOF
  chmod 600 "$CRED_FILE"
}

ask_llm_key(){
  [ "$SKIP_LLM" -eq 1 ] && return 0
  [ -n "$ANTHROPIC_KEY$OPENAI_KEY$LLM_BASE_URL" ] && return 0
  interactive || return 0
  printf '\nAgents need an LLM to explore. Paste an API key now, or press Enter to add one later in the UI.\n'
  local choice key
  read -rp "Provider: 1) Anthropic  2) OpenAI  [1]: " choice || true
  read -rsp "API key (input hidden): " key || true; echo
  [ -z "$key" ] && return 0
  if [ "${choice:-1}" = 2 ]; then OPENAI_KEY="$key"; else ANTHROPIC_KEY="$key"; fi
}

setup_llm(){
  [ "$SKIP_LLM" -eq 1 ] && { info "Skipping LLM setup (--no-llm)"; return; }
  local format key model
  if [ -n "$ANTHROPIC_KEY" ]; then format=anthropic; key="$ANTHROPIC_KEY"; model="${LLM_MODEL:-claude-opus-5-5}"
  elif [ -n "$OPENAI_KEY" ] || [ -n "$LLM_BASE_URL" ]; then format=openai; key="$OPENAI_KEY"; model="${LLM_MODEL:-gpt-4o}"
  else warn "No LLM key given. Add one later in the console: LLM configuration → New."; return; fi
  [ -n "$TOKEN" ] || { warn "Not logged in, so the LLM profile was not created"; return; }

  # Update our own profile on re-runs instead of piling up duplicates.
  local list id="" body resp
  list="$(api GET /api/llm/profiles)" || list=""
  id="$(printf '%s' "$list" | tr '{' '\n' | grep "\"name\":\"$PROFILE_NAME\"" | json_get id || true)"
  body="{"
  [ -n "$id" ] && body+="\"id\":$id,"
  body+="\"name\":$(json_str "$PROFILE_NAME"),\"format\":\"$format\",\"model\":$(json_str "$model"),"
  body+="\"api_key\":$(json_str "$key"),\"streaming\":true"
  [ -n "$LLM_BASE_URL" ] && body+=",\"base_url\":$(json_str "$LLM_BASE_URL")"
  body+="}"
  resp="$(api POST /api/llm/profiles "$body")" || die "Could not save the LLM profile: $resp"
  id="$(printf '%s' "$resp" | json_get id)"
  resp="$(api POST /api/llm/profiles/active "{\"id\":$id}")" || die "Could not activate the LLM profile: $resp"
  ok "LLM profile '$PROFILE_NAME' saved and active ($format, $model)"

  if [ "$SKIP_LLM_TEST" -eq 0 ]; then
    info "Sending one small test request to the model"
    if resp="$(api POST /api/llm/test "{\"profile_id\":$id}")" && ! printf '%s' "$resp" | grep -q '"ok":false'; then
      ok "The model answered"
    else
      warn "The test request failed. Check the key and model in LLM configuration. Response: ${resp:0:300}"
    fi
  fi
}

verify(){
  step "Checking the install"
  local s
  curl -fsS "$BASE_URL/api/health" | grep -q '"ok":true' && ok "Console answers at $BASE_URL" || warn "Health check failed"
  [ "$(api GET /api/auth/status | json_get initialized)" = true ] && ok "Admin account is set" || warn "Admin account is not set"
  if [ -n "$TOKEN" ]; then
    s="$(api GET /api/stats || true)"
    if [ "$(printf '%s' "$s" | json_get llm_configured)" = true ]; then ok "An LLM is configured"
    else warn "No LLM configured yet: agents will not explore until you add one"; fi
  fi
}

summary(){
  printf '\n%sARTIFEX is ready.%s\n\n' "$C_B" "$C_0"
  printf '  Console    %s\n' "$BASE_URL"
  printf '  Username   ARTIFEX\n'
  if [ -n "$ADMIN_PASSWORD" ]; then printf '  Password   saved in %s\n' "$CRED_FILE"; fi
  printf '  Proxy      %s (traffic capture)\n\n' "$PROXY_ADDR"
  printf '  Manage it: ./setup.sh status | stop | start | restart | logs\n'
  [ "$EXPOSE" -eq 0 ] && printf '  It listens on 127.0.0.1 only. From another machine: ssh -L %s:127.0.0.1:%s <this-host>\n' "$PORT" "$PORT"
  printf '\n  Next: sign in, set an asset scope, and create a task. See docs/local-guide.md.\n'
  printf '  Only test systems you own or are authorized to test.\n\n'
}

# ── management subcommands ─────────────────────────────────────────────────
show_logs(){
  local n="${1:-100}"; load_state
  case "${RUNNER:-}" in
    docker)  docker compose logs --tail "$n" artifex ;;
    systemd) journalctl --user -u "$SERVICE_NAME" -n "$n" --no-pager ;;
    *)       [ -f "$LOG_FILE" ] && tail -n "$n" "$LOG_FILE" ;;
  esac
}

manage(){
  detect_platform; load_state
  BASE_URL="http://127.0.0.1:${SAVED_PORT:-8787}"
  case "$1" in
    status)
      if curl -fsS --max-time 3 "$BASE_URL/api/health" 2>/dev/null | grep -q '"ok":true'; then
        ok "Running (${RUNNER:-unknown}) at $BASE_URL"
      else warn "Not answering at $BASE_URL (runner: ${RUNNER:-unknown})"; exit 1; fi ;;
    stop)
      case "${RUNNER:-}" in docker) docker compose stop ;; *) native_stop ;; esac
      ok "Stopped" ;;
    start|restart)
      PORT="${SAVED_PORT:-8787}"; PROXY_PORT="${SAVED_PROXY_PORT:-8788}"; EXPOSE="${SAVED_EXPOSE:-0}"
      case "${RUNNER:-}" in
        docker) docker compose up -d ;;
        "") die "Nothing installed yet; run ./setup.sh first" ;;
        *) native_stop; [ "${DB_MODE_SAVED:-}" = docker ] && docker start "$PG_CONTAINER" >/dev/null 2>&1 || true; native_start ;;
      esac
      wait_health ;;
    logs) show_logs 200 ;;
  esac
}

# ── main ───────────────────────────────────────────────────────────────────
case "${1:-}" in status|start|stop|restart|logs) manage "$1"; exit ;; esac

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift ;;
    --db) DB_MODE="$2"; shift ;;
    --pg-dsn) PG_DSN="$2"; DB_MODE="${DB_MODE:-dsn}"; shift ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift ;;
    --anthropic-key) ANTHROPIC_KEY="$2"; shift ;;
    --openai-key) OPENAI_KEY="$2"; shift ;;
    --model) LLM_MODEL="$2"; shift ;;
    --base-url) LLM_BASE_URL="$2"; shift ;;
    --no-llm) SKIP_LLM=1 ;;
    --skip-llm-test) SKIP_LLM_TEST=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --expose) EXPOSE=1 ;;
    --port) PORT="$2"; shift ;;
    --proxy-port) PROXY_PORT="$2"; shift ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

detect_platform
load_state   # restores generated secrets (SAVED_ADMIN_PASSWORD, DB_PASS) from earlier runs
BASE_URL="http://127.0.0.1:$PORT"

printf '%sARTIFEX setup%s\n' "$C_B" "$C_0"
cat <<'EOF'
ARTIFEX runs LLM agents that execute shell commands on this machine.
Use an isolated machine or VM, and only test systems you are authorized to test.
EOF

if [ -z "$MODE" ]; then
  if compose_ready; then MODE=docker; else MODE=native; fi
fi
case "$MODE" in docker|native) ;; *) die "--mode must be docker or native" ;; esac
info "Install mode: $MODE"

port_busy "$PORT" && ! curl -fsS --max-time 2 "$BASE_URL/api/health" 2>/dev/null | grep -q artifex \
  && die "Port $PORT is used by another program; pick another with --port"

ask_llm_key

if [ "$MODE" = docker ]; then
  step "Starting ARTIFEX in Docker"
  install_docker_mode
else
  step "Toolchains"
  ensure_go
  ensure_node
  step "Database"
  if [ -z "$DB_MODE" ]; then
    if [ -n "$PG_DSN" ]; then DB_MODE=dsn; elif docker_ready; then DB_MODE=docker; else DB_MODE=system; fi
  fi
  case "$DB_MODE" in
    docker) db_docker ;;
    system) db_system ;;
    dsn) [ -n "$PG_DSN" ] || die "--db dsn needs --pg-dsn"; ok "Using the database from --pg-dsn" ;;
    *) die "--db must be docker, system or dsn" ;;
  esac
  save_state DB_MODE_SAVED "$DB_MODE"
  write_config
  step "Building"
  build_native
  step "Starting"
  native_stop
  native_start
fi
save_state SAVED_PORT "$PORT"
save_state SAVED_PROXY_PORT "$PROXY_PORT"
save_state SAVED_EXPOSE "$EXPOSE"

wait_health
step "Configuring"
setup_admin
setup_llm
verify
summary
