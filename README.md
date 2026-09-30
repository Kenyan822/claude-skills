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

クラウドセッションはマーケットプレイスの plugin を読まないので、環境の Setup script で GitHub から取ってくる。
[plugins/visual-walkthrough/cloud-setup.sh](plugins/visual-walkthrough/cloud-setup.sh) を claude.ai の環境設定（Environments → Setup script）に貼り、
環境変数 `SKILLS_GITHUB_TOKEN`（このリポジトリを Contents: Read-only で読める fine-grained PAT）を設定する。
セッション起動時に最新の skill がリポジトリの `.claude/skills/` に未追跡で置かれ、Node / pnpm / Playwright / Chromium が用意される。

## 直すとき

`plugins/visual-walkthrough/skills/visual-walkthrough/` を直して main に入れる。クラウドは次のセッションから新版になる。
手元は `claude plugin update visual-walkthrough@kenya-skills`。`plugin.json` の `version` を上げること。
