# claude-skills

Claude Code のスキル置き場（個人用・非公開）。

## visual-walkthrough

PR や issue を、本物のアプリを実際に動かして撮ったスクリーンショットで「見て分かる」ページにする。
main と PR（issue なら現状と提案）を並べて 1 操作ずつ再生し、各操作の通信と DB の差分を横に出す。
詳細は [plugins/visual-walkthrough/skills/visual-walkthrough/SKILL.md](plugins/visual-walkthrough/skills/visual-walkthrough/SKILL.md)。

### 手元で使う

```bash
claude plugin marketplace add Kenyan822/claude-skills
claude plugin install visual-walkthrough@kenya-skills
```

### Claude Code のクラウドセッションで使う

クラウドセッションはマーケットプレイスの plugin を読まないが、**claude.ai で有効にした skill は自動で同期される**
（Settings → Capabilities → Skills。セッション内では `~/.claude/skills/synced/` に入る）。

1. `plugins/visual-walkthrough/skills/visual-walkthrough/` を zip にする（`make-zip.sh` を実行）
2. claude.ai → Settings → Capabilities → Skills でアップロードして有効にする
3. クラウド環境のネットワークを Full にする（Chromium の取得と Google Fonts に必要。setup script は要らない。
   道具の用意は skill 自身の `scripts/bootstrap.sh` がやる）

skill を直したら zip を作り直して再アップロードする。

`plugins/visual-walkthrough/cloud-setup.sh` は「環境の setup script から GitHub の最新版を取る」案の名残で、
**現状は動かない**（setup script には環境変数が渡らず、GitHub プロキシも紐づいていないリポジトリを 403 にする）。参考として残している。

## 直すとき

`plugins/visual-walkthrough/skills/visual-walkthrough/` を直して main に入れる。クラウドは次のセッションから新版になる。
手元は `claude plugin update visual-walkthrough@kenya-skills`。`plugin.json` の `version` を上げること。
