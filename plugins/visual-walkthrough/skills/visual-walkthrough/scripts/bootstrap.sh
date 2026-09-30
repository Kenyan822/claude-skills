#!/usr/bin/env bash
# visual-walkthrough bootstrap: 撮影に要る道具を揃える。どこで実行しても同じ結果になる（冪等）。
# ローカルの Mac でも、Claude Code のクラウドセッション（Linux VM）でも、これを 1 回叩けば
#   ・対象リポジトリが要求する Node（.nvmrc / package.json engines）
#   ・pnpm（リポジトリが pnpm-lock.yaml を持つとき）
#   ・Playwright と Chromium（作業用フォルダに入れる。リポジトリの node_modules は触らない）
#   ・使い捨ての Postgres（Docker が使えればコンテナ、使えなければローカルのクラスタ）
# が用意され、結果が $VW_HOME/env.json に書かれる。scenario / run スクリプトはそれを読む。
#
# 使い方:
#   bash bootstrap.sh --repo <path> [--pg-user u --pg-pass p --pg-db d --pg-port 5442] [--no-pg]
#   bash bootstrap.sh stop            # ローカルクラスタ / コンテナを止めて消す
#
# 外向き通信が要るのは Node・pnpm・Playwright・Chromium の取得だけ。アプリの秘密情報は一切扱わない。
set -euo pipefail

VW_HOME="${VW_HOME:-$HOME/.cache/visual-walkthrough}"
REPO=""; PG_USER="capture"; PG_PASS="capture"; PG_DB="capture"; PG_PORT="5442"; WANT_PG=1; PW_VERSION="${PW_VERSION:-1.63.0}"
CONTAINER="visual-walkthrough-pg"

log() { printf '[bootstrap] %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""
if [ "$(id -u)" != "0" ] && have sudo && sudo -n true 2>/dev/null; then SUDO="sudo"; fi

# ── stop: 片付け ──────────────────────────────────────────────
if [ "${1:-}" = "stop" ]; then
  if have docker && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    docker rm -f "$CONTAINER" >/dev/null && log "container $CONTAINER removed"
  fi
  if [ -d "$VW_HOME/pg/data" ] && have pg_ctl; then
    pg_ctl -D "$VW_HOME/pg/data" stop -m fast >/dev/null 2>&1 && log "local postgres stopped" || true
    rm -rf "$VW_HOME/pg" && log "local postgres data removed"
  fi
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --pg-user) PG_USER="$2"; shift 2;;
    --pg-pass) PG_PASS="$2"; shift 2;;
    --pg-db) PG_DB="$2"; shift 2;;
    --pg-port) PG_PORT="$2"; shift 2;;
    --no-pg) WANT_PG=0; shift;;
    *) log "unknown arg: $1"; exit 2;;
  esac
done
mkdir -p "$VW_HOME"

# ── 1. Node: リポジトリの指定に合わせる ─────────────────────────
NODE_WANT=""
if [ -n "$REPO" ]; then
  for f in "$REPO/.nvmrc" "$REPO/web/.nvmrc" "$REPO/frontend/.nvmrc" "$REPO/.node-version"; do
    [ -f "$f" ] && NODE_WANT="$(tr -d 'v[:space:]' < "$f")" && break
  done
  if [ -z "$NODE_WANT" ]; then
    for f in "$REPO/package.json" "$REPO/web/package.json" "$REPO/frontend/package.json"; do
      [ -f "$f" ] || continue
      NODE_WANT="$(python3 -c "import json,re,sys;e=json.load(open(sys.argv[1])).get('engines',{}).get('node','');m=re.search(r'(\d+)',e);print(m.group(1) if m else '')" "$f" 2>/dev/null || true)"
      [ -n "$NODE_WANT" ] && break
    done
  fi
fi
NODE_BIN="$(dirname "$(command -v node)")"
if [ -n "$NODE_WANT" ]; then
  CUR="$(node -v | sed 's/^v//')"
  if [ "${CUR%%.*}" != "${NODE_WANT%%.*}" ]; then
    log "node ${CUR} → want ${NODE_WANT} (repo pin)"
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      # shellcheck disable=SC1090
      . "$HOME/.nvm/nvm.sh"; nvm install "$NODE_WANT" >/dev/null 2>&1 || nvm install "$NODE_WANT"
      NODE_BIN="$(dirname "$(nvm which "$NODE_WANT")")"
    else
      if ! have fnm; then
        curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$VW_HOME/fnm" --skip-shell >/dev/null
        export PATH="$VW_HOME/fnm:$PATH"
      fi
      eval "$(fnm env --shell bash)"
      fnm install "$NODE_WANT" >/dev/null
      NODE_BIN="$(dirname "$(fnm exec --using="$NODE_WANT" -- which node)")"
    fi
  fi
fi
export PATH="$NODE_BIN:$PATH"
log "node $(node -v) at $NODE_BIN"

# ── 2. pnpm（リポジトリが使うときだけ）──────────────────────────
PNPM=""
if [ -n "$REPO" ] && { [ -f "$REPO/pnpm-lock.yaml" ] || [ -f "$REPO/web/pnpm-lock.yaml" ] || [ -f "$REPO/frontend/pnpm-lock.yaml" ]; }; then
  if have pnpm; then PNPM="$(command -v pnpm)";
  elif have corepack && corepack enable pnpm >/dev/null 2>&1 && have pnpm; then PNPM="$(command -v pnpm)";
  elif npm i -g pnpm >/dev/null 2>&1 && have pnpm; then PNPM="$(command -v pnpm)";
  else PNPM="npx --yes pnpm"; fi
  log "pnpm: $PNPM"
fi

# ── 3. Playwright + Chromium（作業用フォルダ。リポジトリは汚さない）─────
PW_DIR="$VW_HOME/pw"
mkdir -p "$PW_DIR"
if [ ! -f "$PW_DIR/node_modules/playwright/package.json" ]; then
  ( cd "$PW_DIR" && [ -f package.json ] || printf '{"name":"visual-walkthrough-pw","private":true}\n' > "$PW_DIR/package.json"
    cd "$PW_DIR" && npm i --no-audit --no-fund "playwright@$PW_VERSION" >/dev/null )
  log "playwright $PW_VERSION installed in $PW_DIR"
fi
if ! ( cd "$PW_DIR" && node -e "require('playwright').chromium.launch().then(b=>b.close())" >/dev/null 2>&1 ); then
  if [ "$(uname -s)" = "Linux" ] && [ -n "$SUDO$( [ "$(id -u)" = 0 ] && echo root )" ]; then
    ( cd "$PW_DIR" && $SUDO env PATH="$PATH" npx playwright install --with-deps chromium >/dev/null ) || ( cd "$PW_DIR" && npx playwright install chromium >/dev/null )
  else
    ( cd "$PW_DIR" && npx playwright install chromium >/dev/null )
  fi
  ( cd "$PW_DIR" && node -e "require('playwright').chromium.launch().then(b=>{console.error('[bootstrap] chromium ok',b.version());return b.close()})" )
else
  log "chromium already launches"
fi

# ── 4. Postgres: Docker があればコンテナ、無ければローカルのクラスタ ─────
PG_MODE="none"; PG_URL=""
if [ "$WANT_PG" = 1 ]; then
  if have docker && docker info >/dev/null 2>&1; then
    PG_MODE="docker"
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
      docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
      docker run -d --name "$CONTAINER" -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PASS" -e POSTGRES_DB="$PG_DB" -e TZ=Asia/Tokyo -p "$PG_PORT:5432" postgres:17-alpine >/dev/null
    fi
    for _ in $(seq 1 30); do docker exec "$CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 && break; sleep 1; done
    PG_URL="postgres://$PG_USER:$PG_PASS@localhost:$PG_PORT/$PG_DB"
    log "postgres (docker) $PG_URL"
  else
    if ! have initdb; then
      if [ "$(uname -s)" = "Linux" ] && have apt-get; then
        $SUDO apt-get update -qq >/dev/null && $SUDO apt-get install -y -qq postgresql postgresql-contrib >/dev/null
        PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"; [ -n "$PGBIN" ] && export PATH="$PGBIN:$PATH"
      elif have brew; then
        brew install postgresql@17 >/dev/null && export PATH="$(brew --prefix postgresql@17)/bin:$PATH"
      fi
    fi
    if have initdb && have pg_ctl; then
      PG_MODE="local"
      mkdir -p "$VW_HOME/pg"
      if [ ! -f "$VW_HOME/pg/data/PG_VERSION" ]; then
        printf '%s\n' "$PG_PASS" > "$VW_HOME/pg/pw"
        initdb -D "$VW_HOME/pg/data" -U "$PG_USER" --pwfile="$VW_HOME/pg/pw" -A md5 >/dev/null
      fi
      pg_ctl -D "$VW_HOME/pg/data" status >/dev/null 2>&1 || pg_ctl -D "$VW_HOME/pg/data" -l "$VW_HOME/pg/log" -o "-p $PG_PORT -k $VW_HOME/pg" start >/dev/null
      for _ in $(seq 1 30); do pg_isready -h localhost -p "$PG_PORT" >/dev/null 2>&1 && break; sleep 1; done
      PGPASSWORD="$PG_PASS" psql -h localhost -p "$PG_PORT" -U "$PG_USER" -d postgres -Atc "select 1 from pg_database where datname='$PG_DB'" | grep -q 1 \
        || PGPASSWORD="$PG_PASS" createdb -h localhost -p "$PG_PORT" -U "$PG_USER" "$PG_DB"
      PG_URL="postgres://$PG_USER:$PG_PASS@localhost:$PG_PORT/$PG_DB"
      log "postgres (local cluster) $PG_URL"
    else
      log "WARNING: no docker and no postgres binaries; DB must be arranged by hand"
    fi
  fi
fi

# ── 5. 結果を書く ───────────────────────────────────────────────
python3 - "$VW_HOME/env.json" "$NODE_BIN" "$PNPM" "$PW_DIR/package.json" "$PG_MODE" "$PG_URL" "$PG_PORT" "$CONTAINER" "$PG_USER" "$PG_DB" <<'EOF'
import json, sys
out, node_bin, pnpm, pw_from, pg_mode, pg_url, pg_port, container, pg_user, pg_db = sys.argv[1:]
json.dump({
  "node_bin": node_bin, "pnpm": pnpm or None, "playwright_from": pw_from,
  "pg": {"mode": pg_mode, "url": pg_url or None, "port": int(pg_port), "container": container if pg_mode == "docker" else None, "user": pg_user, "db": pg_db},
}, open(out, "w"), ensure_ascii=False, indent=1)
print(open(out).read())
EOF
log "wrote $VW_HOME/env.json"
