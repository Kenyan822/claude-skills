#!/usr/bin/env bash
# Claude Code クラウド環境（claude.ai/code → Environments → Setup script）に貼るスクリプト。
# セッション起動前に走り、GitHub の claude-skills から visual-walkthrough の最新版を取ってきて、
# このセッションのリポジトリの .claude/skills/ に「未追跡」で置く（コミットはしない）。
# そのあと skill の bootstrap.sh で Node / pnpm / Playwright / Chromium / 使い捨て Postgres を用意する。
#
# 環境側に要る設定:
#   環境変数 SKILLS_GITHUB_TOKEN  skill のリポジトリ（既定 Kenyan822/claude-skills。SKILLS_REPO で変更可）を Contents: Read-only で読める fine-grained PAT
#   環境変数 SKILLS_REF           取ってくるブランチかタグ（省略時 main）
#   ネットワーク                    GitHub API・npm・Playwright の Chromium 配布元・Google Fonts に出られること（試行は Full が楽）
set -euo pipefail

OWNER_REPO="${SKILLS_REPO:-Kenyan822/claude-skills}"
REF="${SKILLS_REF:-main}"
TOKEN="${SKILLS_GITHUB_TOKEN:?SKILLS_GITHUB_TOKEN（claude-skills を読める PAT）を環境変数に設定してください}"
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
WORK="$(mktemp -d)"

log() { printf '[cloud-setup] %s\n' "$*" >&2; }
api() { curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

SHA="$(api "https://api.github.com/repos/$OWNER_REPO/commits/$REF" | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha"][:12])')"
api "https://api.github.com/repos/$OWNER_REPO/tarball/$REF" -o "$WORK/skills.tgz"
mkdir -p "$WORK/src" && tar xzf "$WORK/skills.tgz" -C "$WORK/src" --strip-components=1

DEST="$REPO_DIR/.claude/skills/visual-walkthrough"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$WORK/src/plugins/visual-walkthrough/skills/visual-walkthrough" "$DEST"
printf '%s %s %s\n' "$OWNER_REPO" "$REF" "$SHA" > "$DEST/.source"
# git status を汚さない。skill を誤ってコミットしないように、このリポジトリのローカル除外に足す
if [ -d "$REPO_DIR/.git" ]; then
  mkdir -p "$REPO_DIR/.git/info"
  grep -qxF ".claude/skills/visual-walkthrough/" "$REPO_DIR/.git/info/exclude" 2>/dev/null || echo ".claude/skills/visual-walkthrough/" >> "$REPO_DIR/.git/info/exclude"
fi
log "installed visual-walkthrough@$SHA ($REF) into $DEST"

# 道具を揃える（Postgres は撮影時に skill が立てるので、ここでは道具の導入まで）
bash "$DEST/scripts/bootstrap.sh" --repo "$REPO_DIR" --no-pg
rm -rf "$WORK"
log "done"
