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
  for H in "$VW_HOME/pg" /tmp/visual-walkthrough-pg; do
    [ -d "$H/data" ] || continue
    PGCTL="$(command -v pg_ctl || ls "$VW_HOME"/epg/node_modules/@embedded-postgres/*/native/bin/pg_ctl /tmp/visual-walkthrough-epg/node_modules/@embedded-postgres/*/native/bin/pg_ctl 2>/dev/null | head -1 || true)"
    if [ -n "$PGCTL" ]; then
      if [ "$(id -u)" = "0" ] && command -v runuser >/dev/null 2>&1; then runuser -u vwpg -- "$PGCTL" -D "$H/data" stop -m fast >/dev/null 2>&1 || true
      else "$PGCTL" -D "$H/data" stop -m fast >/dev/null 2>&1 || true; fi
    fi
    rm -rf "$H" && log "local postgres removed ($H)"
  done
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
# クラウドの VM は Chromium を先に入れている（PLAYWRIGHT_BROWSERS_PATH）。その版に合う Playwright を選べば
# ダウンロードが要らない。版の対応は playwright-core の browsers.json（chromium revision）から。
PW_DIR="$VW_HOME/pw"
mkdir -p "$PW_DIR"
if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ] && [ -d "$PLAYWRIGHT_BROWSERS_PATH" ] && [ -z "${VW_PW_VERSION:-}" ]; then
  REV="$(ls "$PLAYWRIGHT_BROWSERS_PATH" | sed -n 's/^chromium-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)"
  case "$REV" in
    1187) PW_VERSION=1.55.0;; 1194) PW_VERSION=1.56.1;; 1200) PW_VERSION=1.57.0;;
    "") ;;
    *) log "preinstalled chromium-$REV: unknown Playwright mapping, using $PW_VERSION (may download)";;
  esac
  [ -n "$REV" ] && log "preinstalled chromium-$REV → playwright $PW_VERSION"
fi
PW_VERSION="${VW_PW_VERSION:-$PW_VERSION}"
if [ "$(cat "$PW_DIR/.version" 2>/dev/null)" != "$PW_VERSION" ] || [ ! -f "$PW_DIR/node_modules/pg/package.json" ]; then
  rm -rf "$PW_DIR/node_modules" "$PW_DIR/package-lock.json"
  printf '{"name":"visual-walkthrough-pw","private":true}\n' > "$PW_DIR/package.json"
  ( cd "$PW_DIR" && npm i --no-audit --no-fund "playwright@$PW_VERSION" pg >/dev/null )
  echo "$PW_VERSION" > "$PW_DIR/.version"
  log "playwright $PW_VERSION + pg installed in $PW_DIR"
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

# ── 4. Postgres: docker → PATH 上のバイナリ → apt → npm の embedded-postgres ─
# Postgres は root では起動しない。root のときは専用ユーザー vwpg で動かし、置き場は誰でも読める /tmp 配下にする。
PG_MODE="none"; PG_URL=""
PGHOME="$VW_HOME/pg"; PGRUN=""
if [ "$(id -u)" = "0" ]; then
  PGHOME="/tmp/visual-walkthrough-pg"
  id vwpg >/dev/null 2>&1 || useradd -m -s /bin/bash vwpg >/dev/null 2>&1 || true
  have runuser && PGRUN="runuser -u vwpg --"
fi
start_local_cluster() {  # $1 = bin dir（空なら PATH）
  local B="${1:+$1/}"
  mkdir -p "$PGHOME"; [ -n "$PGRUN" ] && chown -R vwpg "$PGHOME" && chmod a+rx "$PGHOME"
  if [ ! -f "$PGHOME/data/PG_VERSION" ]; then
    printf '%s\n' "$PG_PASS" > "$PGHOME/pw"; [ -n "$PGRUN" ] && chown vwpg "$PGHOME/pw"
    $PGRUN "${B}initdb" -D "$PGHOME/data" -U "$PG_USER" --pwfile="$PGHOME/pw" -A md5 -E UTF8 >/dev/null
  fi
  $PGRUN "${B}pg_ctl" -D "$PGHOME/data" status >/dev/null 2>&1 || $PGRUN "${B}pg_ctl" -D "$PGHOME/data" -l "$PGHOME/log" -o "-p $PG_PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=" start >/dev/null
  PG_MODE="local"; PG_URL="postgres://$PG_USER:$PG_PASS@127.0.0.1:$PG_PORT/$PG_DB"
  # データベースの作成は pg（Node）でやる。psql が無い VM でも動くように
  ( cd "$PW_DIR" && PGURL="postgres://$PG_USER:$PG_PASS@127.0.0.1:$PG_PORT/postgres" PGDB="$PG_DB" node -e "
    const {Client}=require('pg');(async()=>{for(let i=0;i<40;i++){try{const c=new Client({connectionString:process.env.PGURL});await c.connect();
    const r=await c.query('select 1 from pg_database where datname=\$1',[process.env.PGDB]);
    if(!r.rowCount)await c.query('create database \"'+process.env.PGDB.replace(/\"/g,'')+'\"');await c.end();return;}catch(e){await new Promise(r=>setTimeout(r,500));}}
    console.error('postgres did not come up');process.exit(1)})()" )
  log "postgres (local cluster) $PG_URL"
}
if [ "$WANT_PG" = 1 ] && [ -z "${VW_NO_DOCKER:-}" ] && have docker && docker info >/dev/null 2>&1; then
  PG_MODE="docker"
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" -e POSTGRES_USER="$PG_USER" -e POSTGRES_PASSWORD="$PG_PASS" -e POSTGRES_DB="$PG_DB" -e TZ=Asia/Tokyo -p "$PG_PORT:5432" postgres:17-alpine >/dev/null
  fi
  for _ in $(seq 1 30); do docker exec "$CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 && break; sleep 1; done
  PG_URL="postgres://$PG_USER:$PG_PASS@localhost:$PG_PORT/$PG_DB"
  log "postgres (docker) $PG_URL"
elif [ "$WANT_PG" = 1 ]; then
  if have initdb && have pg_ctl && [ -z "${VW_NO_SYSTEM_PG:-}" ]; then
    start_local_cluster ""
  else
    if [ "$(uname -s)" = "Linux" ] && have apt-get && { [ -n "$SUDO" ] || [ "$(id -u)" = "0" ]; } && [ -z "${VW_NO_SYSTEM_PG:-}" ]; then
      $SUDO apt-get update -qq >/dev/null 2>&1 && $SUDO apt-get install -y -qq postgresql postgresql-contrib >/dev/null 2>&1 || true
      PGBIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
    fi
    if [ -n "${PGBIN:-}" ] && [ -x "$PGBIN/initdb" ]; then
      start_local_cluster "$PGBIN"
    else
      # npm だけで入る Postgres（embedded-postgres）。root も sudo も Docker も要らない
      EPG="$VW_HOME/epg"; [ "$(id -u)" = "0" ] && EPG="/tmp/visual-walkthrough-epg"
      mkdir -p "$EPG"
      [ -f "$EPG/package.json" ] || printf '{"name":"visual-walkthrough-epg","private":true}\n' > "$EPG/package.json"
      ( cd "$EPG" && ls node_modules/@embedded-postgres/*/native/bin/initdb >/dev/null 2>&1 || npm i --no-audit --no-fund embedded-postgres >/dev/null )
      EPGBIN="$(ls -d "$EPG"/node_modules/@embedded-postgres/*/native/bin 2>/dev/null | head -1 || true)"
      if [ -n "$EPGBIN" ] && [ -x "$EPGBIN/initdb" ]; then
        [ "$(id -u)" = "0" ] && chmod -R a+rX "$EPG"
        start_local_cluster "$EPGBIN"
      else
        log "WARNING: no docker, no postgres binaries, and embedded-postgres unavailable; DB must be arranged by hand"
      fi
    fi
  fi
fi

# ── 5. 結果を書く ───────────────────────────────────────────────
python3 - "$VW_HOME/env.json" "$NODE_BIN" "$PNPM" "$PW_DIR/package.json" "$PG_MODE" "$PG_URL" "$PG_PORT" "$CONTAINER" "$PG_USER" "$PG_DB" <<'EOF'
import json, sys
out, node_bin, pnpm, pw_from, pg_mode, pg_url, pg_port, container, pg_user, pg_db = sys.argv[1:]
json.dump({
  "node_bin": node_bin, "pnpm": pnpm or None, "playwright_from": pw_from, "pg_from": pw_from,
  "pg": {"mode": pg_mode, "url": pg_url or None, "port": int(pg_port), "container": container if pg_mode == "docker" else None, "user": pg_user, "db": pg_db},
}, open(out, "w"), ensure_ascii=False, indent=1)
print(open(out).read())
EOF
log "wrote $VW_HOME/env.json"
