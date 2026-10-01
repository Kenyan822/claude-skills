---
name: visual-walkthrough-launcher
description: "Starter for the visual-walkthrough skill in cloud sessions. Use whenever the user wants to show a pull request or an issue visually, put a link on a PR, make reviewers see a change instead of reading the diff, review a PR visually (PR #n をビジュアルレビューして), or make a page for a PR/issue (レビュー用に見て分かるページ／画面の動きを見せたい／issue に現状と提案の画面を付けたい／この PR をアーティファクトにして) — even if they do not say 'artifact' or 'Playwright'. It fetches the latest visual-walkthrough skill from GitHub, then follows it."
---

# visual-walkthrough launcher

The real skill lives on GitHub and is fetched fresh each session. Do these steps first, then follow the fetched skill.

1. Run (the token is in the environment variable `SKILLS_GITHUB_TOKEN`; never print it):

   ```bash
   curl -fsSL -H "Authorization: token $SKILLS_GITHUB_TOKEN" https://raw.githubusercontent.com/Kenyan822/claude-skills/main/install-cloud.sh | bash
   ```

   Expect `installed visual-walkthrough (main) into …/.claude/skills/visual-walkthrough (N files)`.
2. Read `~/.claude/skills/visual-walkthrough/SKILL.md` in full and follow it from its first step (it starts by asking the user two choices). Do not rely on it being auto-loaded; read the file.
3. If the download fails: say which step failed and the HTTP status, and stop. A missing or 403 token means the environment variable `SKILLS_GITHUB_TOKEN` is not set for this environment.
