#!/usr/bin/env bash
# クラウドセッション（claude.ai/code）の中で、GitHub から visual-walkthrough の最新版を取ってくる。
# api.github.com は紐づいていないリポジトリを 403 にするが、raw.githubusercontent.com は通る。
# 使い方（セッションの最初に頼む）:
#   curl -fsSL -H "Authorization: token $SKILLS_GITHUB_TOKEN" https://raw.githubusercontent.com/Kenyan822/claude-skills/main/install-cloud.sh | bash
# 環境変数 SKILLS_GITHUB_TOKEN（このリポジトリを Contents: Read-only で読める PAT）が要る。SKILLS_REF で版を固定できる。
set -euo pipefail
REPO="${SKILLS_REPO:-Kenyan822/claude-skills}"; REF="${SKILLS_REF:-main}"
TOKEN="${SKILLS_GITHUB_TOKEN:?SKILLS_GITHUB_TOKEN を環境変数に設定してください}"
BASE="https://raw.githubusercontent.com/$REPO/$REF/plugins/visual-walkthrough/skills/visual-walkthrough"
DEST="${VW_SKILL_DIR:-$HOME/.claude/skills/visual-walkthrough}"
get() { curl -fsSL -H "Authorization: token $TOKEN" "$1"; }
TMP="$(mktemp -d)"
get "$BASE/MANIFEST" > "$TMP/MANIFEST"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  mkdir -p "$TMP/skill/$(dirname "$f")"
  get "$BASE/$f" > "$TMP/skill/$f"
done < "$TMP/MANIFEST"
[ -f "$TMP/skill/SKILL.md" ] || { echo "SKILL.md が取れませんでした" >&2; exit 1; }
chmod +x "$TMP/skill/scripts/"*.sh 2>/dev/null || true
printf '%s %s %s\n' "$REPO" "$REF" "$(date -u +%FT%TZ)" > "$TMP/skill/.source"
rm -rf "$DEST" && mkdir -p "$(dirname "$DEST")" && mv "$TMP/skill" "$DEST" && rm -rf "$TMP"
echo "installed visual-walkthrough ($REF) into $DEST ($(wc -l < "$DEST/MANIFEST") files)"
