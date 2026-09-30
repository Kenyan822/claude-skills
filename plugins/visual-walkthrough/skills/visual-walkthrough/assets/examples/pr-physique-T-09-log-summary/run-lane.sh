#!/bin/zsh
# お手本（physique-analytics）。Node の版・ポート・コンテナ名・ガードのパスは自分の環境に合わせる。
# 1 レーン分の撮影。今日のデータと代替サーバーのログを消し、対応する worktree の next dev を 3100 で起動して scenario.mjs を回し、止める。
set -e
export PATH=~/.nvm/versions/node/v24.21.0/bin:$PATH
S=$(cd "$(dirname "$0")" && pwd)   # シナリオと worktree（wt-base / wt-head）を置いた作業フォルダ
LANE=$1
[ "$LANE" = before ] && WT=wt-base || WT=wt-head
docker exec physique-capture-db psql -U physique -d physique -Atc "delete from workout_sets where session_id in (select id from workout_sessions where date = current_date); delete from workout_sessions where date = current_date;"
: > $S/auth-stub.log
cd $S/$WT/web
rm -rf .next
env -i PATH="$PATH" HOME="$HOME" TZ=Asia/Tokyo \
  API_BASE_URL=http://127.0.0.1:8090 \
  NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54329 NEXT_PUBLIC_SUPABASE_ANON_KEY=capture-anon-key \
  NODE_OPTIONS="--require <visual-walkthrough>/scripts/guard/node/egress-guard.cjs" \
  CAPTURE_ALLOW_HOSTS=fonts.googleapis.com,fonts.gstatic.com \
  pnpm exec next dev -p 3100 > $S/web-$LANE.log 2>&1 &
WEBPID=$!
for i in {1..90}; do curl -s -o /dev/null http://localhost:3100/login && break; sleep 1; done
curl -s -o /dev/null -w "warm /login %{http_code}\n" http://localhost:3100/login
cd $S && node scenario.mjs $LANE
kill $WEBPID 2>/dev/null || true
lsof -ti tcp:3100 | xargs kill 2>/dev/null || true
wait $WEBPID 2>/dev/null || true
echo "lane $LANE done"
