#!/usr/bin/env bash
# skill のファイル一覧（MANIFEST）を作り直す。raw.githubusercontent.com にはディレクトリ一覧が無いので、
# クラウドで skill を取ってくる install-cloud.sh はこの一覧を読む。skill を直したらコミット前に実行する。
set -euo pipefail
D="$(cd "$(dirname "$0")/skills/visual-walkthrough" && pwd)"
( cd "$D" && find . -type f ! -name MANIFEST ! -name .DS_Store ! -name .source | sed 's|^\./||' | sort > MANIFEST )
echo "$(wc -l < "$D/MANIFEST") files"
