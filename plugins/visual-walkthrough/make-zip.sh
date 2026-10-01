#!/usr/bin/env bash
# claude.ai の Skills（Settings → Capabilities → Skills）にアップロードする zip を作る。
# 使い方: bash plugins/visual-walkthrough/make-zip.sh [出力先.zip]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/visual-walkthrough.zip}"
rm -f "$OUT"
bash "$HERE/update-manifest.sh" >/dev/null
( cd "$HERE/skills" && zip -qr "$OUT" visual-walkthrough -x '*.DS_Store' '*/.source' )
echo "$OUT ($(du -h "$OUT" | cut -f1))"

# 起動用 skill（claude.ai の Skills にアップロードする。ほぼ更新不要）
LOUT="$(dirname "$OUT")/visual-walkthrough-launcher.zip"
rm -f "$LOUT"
( cd "$HERE/launcher" && zip -qr "$LOUT" visual-walkthrough-launcher -x '*.DS_Store' )
echo "$LOUT ($(du -h "$LOUT" | cut -f1))"
