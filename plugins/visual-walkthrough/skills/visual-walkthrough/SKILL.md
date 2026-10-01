---
name: visual-walkthrough
description: "Turn a pull request or an issue into a page people understand by watching: the real app, driven step by step, shown as real screenshots side by side (main vs PR, or current vs proposal) with the request log and the DB diff beside each step. Use this whenever the user wants to show a PR or an issue visually, put a link on a PR, make reviewers see the change instead of reading the diff, PR を見て分かるページにしたい／レビュー用に画面の動きを見せたい／issue に現状と提案の画面を付けたい／この PR をアーティファクトにして, or says 「PR にリンク載せたい」「動画みたいにレビューさせたい」 — even if they don't say 'artifact' or 'Playwright'."
---

# Visual Walkthrough

Make a page that shows what a change does, using the real application. Claude never draws the screen. Playwright drives the real app locally, records a screenshot after every operation, and the page replays those screenshots with the pressed element highlighted, the requests that went out, and the rows that changed in the database. Claude's job is the reviewer's job: read the change, pick the operations worth showing, drive them, and narrate.

Two page types share one viewer:

- **PR page**: the same scenario on the base commit (`main`) and on the PR head (`PR`), side by side.
- **Issue page**: the same scenario on the current app (`現状`) and on a **proposal** (`提案`): the real app with a small DOM edit made inside the live browser right before the screenshot, tagged 未実装. Claude does not re-implement screens in React or HTML; the proposal inherits the real fonts, styles and layout, and only the edited part differs.

Write every user-visible string in Japanese unless the user writes in another language.

## Bundled files

- `scripts/capture-lib.mjs`: the recorder. `cap.step / press / type / select / popup / absent / edit` record one frame each: a 2x JPEG of the viewport, the target's bounding box (this becomes a clickable hotspot to the next frame), requests (browser → server, plus server → external API from the guard log), and the diff of whatever tables the scenario reads. Identical screenshots are stored once.
- `scripts/guard/node/egress-guard.cjs` and `scripts/guard/py/sitecustomize.py`: block every outbound connection except localhost and an allowlist, without touching the app's code. The Python guard also replaces `google-genai` calls with responses Claude wrote (`CAPTURE_MOCK_FILE`) and logs each call (`CAPTURE_MOCK_LOG`), which the recorder turns into 「外部 API → Claude の代替応答」 lines.
- `scripts/verify.mjs`: serves the finished page locally and measures it at desktop and phone width before publishing.
- `assets/viewer.html`: the fixed viewer. Copy it to `index.html`, change only the `<title>` line. Everything else comes from `page.json` and `capture/<lane>.json`.
- `assets/examples/pr-physique-T-09-log-summary/`: a finished PR page to copy from (Next.js web + Go API + Postgres, Supabase Auth). `scenario.mjs` records 12 frames per lane with `press`/`step`, resolves DB rows to what the screen shows, and names server actions from their arguments; `run-lane.sh` resets today's rows, starts `next dev` from the lane's worktree under the Node guard, runs the lane, stops the server; `auth-stub.mjs` is a 60-line local server standing in for Supabase Auth, answering the three endpoints the app calls with fixed responses and logging each call in the guard's JSON Lines format so the page shows them as 「外部 API → Claude の代替応答」. `page.json` is the copy.
- `assets/examples/fictional-label/`: how to author a fictional document fixture in HTML and render it to a vector PDF and a PNG with Playwright.
- `assets/examples/mock-responses.example.json`: the shape of the Python guard's LLM response rules.

## Two choices to make with the user before starting

Ask these first, in one message. They change what gets built, and both involve cost or confidentiality:

1. **Data**: fictional seed written for the capture (default; label everything 架空), or a copy of real data (needs the user's OK; never for client projects unless they say so).
2. **External APIs** (LLMs, payment, mail, cloud storage): block them and let Claude stand in (default; responses are written in advance from the code's prompts and parsers, so nothing is billed and the page can say so), or call the real services (needs the user's OK; check whose cloud project pays and whether it is a client's).

Also confirm, when the app belongs to a client, that its UI may be published as an artifact, and ask what must be masked (logos, product names, real names). Publication is external; do not publish before the answer.

## Workflow

1. **Read the change.** The usual moment is *before* the PR exists: the user is on a feature branch and wants to open the PR with the page attached. Then `base` is the merge-base with the default branch (`git merge-base origin/main HEAD`) and `head` is the branch tip; ask for a commit (a WIP commit is fine) if the work is uncommitted, because both sides are captured from detached worktrees. Read `git diff <base>...HEAD --stat` and the changed files. For an existing PR, `gh pr view <n> --json body,baseRefName,headRefName` and `gh pr diff <n> --name-only`. For an issue, read the current code of the screen plus the requirement's source (a doc, a meeting note, a code comment). Write down, in one line, what the reader must see to understand the change.
2. **Choose the scenario.** 5–12 operations on the simplest path that reaches the change. One concrete example throughout (one company, one file). Every frame is one operation: pressing, typing, choosing, a modal opening, a result appearing. Decide per lane what to highlight and what the one-line note says. Leave branches and variants to the checks section. Mark what you will not capture (`未撮影`).
3. **Prepare the app locally.**
   - Tools first: `bash scripts/bootstrap.sh --repo <repo> --pg-port <free port>` prepares the Node version the repo pins, pnpm when the repo uses it, Playwright + Chromium in `~/.cache/visual-walkthrough/pw` (never inside the repo), and a throwaway Postgres (a Docker container when Docker works, otherwise a local cluster). It writes `~/.cache/visual-walkthrough/env.json`; pass `playwright_from` to `createCapture` and use `tablesFromEnv(envJson, queries)` for the DB tables. `bash scripts/bootstrap.sh stop` removes the database afterwards.
   - Throwaway DB: start your own container on a free port under a separate compose project name (`docker compose -p <name>-capture up -d db`) or `docker run` with a distinct name. Never point at a shared or production database.
   - Fictional data: write a small seed script against the app's own client (Prisma, SQLAlchemy, the repo's seed scripts). Company names like 株式会社サンプル製作所, people like ダミー営業, codes and dates chosen so the scenario's search terms hit exactly what you intend.
   - Logged-in state: do not go through a login screen. Read the auth code and manufacture the state the server trusts. DB session (Auth.js `strategy: "database"`, Rails, Django): insert the session row and set the cookie. Signed token (Auth.js jwt, Supabase, custom JWT): sign one with the secret from `.env`. Cookie session behind a password login with a local admin (FastAPI + Starlette): call the login API once from the recorder's `login` hook. Firebase: the Auth Emulator. Only an external IdP that must be consulted per request needs a config change.
   - Egress guard: Node servers `NODE_OPTIONS="--require <abs>/guard/node/egress-guard.cjs"`, Python servers `PYTHONPATH=<abs>/guard/py`. Allow only what is harmless and needed (`CAPTURE_ALLOW_HOSTS=fonts.googleapis.com,fonts.gstatic.com` for `next/font/google`). Unset every real API key in the env you launch with, and set the cloud project id to a dummy value.
   - Mock responses: for each external call on the scenario path, read the prompt builder and the parser, then write the response in the parser's format (`prompt_contains` keys that identify each call). An unmatched call throws, so a missing rule fails the capture instead of silently succeeding. Make the content fit the fictional data, and, where the app locates text (red boxes, search hits), put the words in the fixture so the app finds them itself.
   - Masks: `mask: [{ selector: 'img[alt="<brand>"]', label: "SAMPLE" }]` replaces the element with a same-sized box right before each screenshot. Use it for client logos, product names and real people.
   - External services with no SDK hook (an auth provider, a payment API): write a small local HTTP server that answers only the endpoints the app calls, point the app's base URL env at it, and append each call to `CAPTURE_MOCK_LOG` as `{"ts", "service", "method", "model": <path>, "mocked": true, "rule"}` so the recorder shows it. `auth-stub.mjs` in the example is the pattern.
   - Warm the server with one request before recording. Turbopack's first compile takes seconds and would otherwise land inside a frame.
   - Playwright: the recorder loads `playwright` from the `package.json` you pass as `playwrightFrom`. If the target repo has none, make a scratch folder (`npm init -y && npm i playwright`) outside the repo and point there. Run `npx playwright install chromium` in that folder once; a browser cached for another Playwright version does not count.
4. **Write the scenario** (`scenario.mjs`, one file, lane from `argv`). Both lanes run the same steps in the same order and produce the same number of frames; where one lane has no counterpart, call `cap.absent()` so the frame indexes stay aligned. Patterns:
   - `await cap.press(id, cap, target)` records the frame with the target highlighted and a hotspot to the next frame, then clicks. The next `cap.step()` records the result (`wait` for the element that proves it).
   - `cap.type / cap.select` act, then record. `cap.step({ run })` for anything else.
   - `cap.popup(id, cap, trigger, { ready })` records a new tab as a full-page frame.
   - Proposal lane: `cap.edit(id, cap, editFn, { arg, target })` edits the live DOM and records; mark edited nodes with `data-proposal="add|change"`. Use the app's own assets for the edit (an image the app already generated, its own class names) rather than inventing them.
   - `tables`: return the rows the reader should watch (`dockerPsqlTables`, `gcsEmulatorTable`, `combineTables`). Resolve foreign keys to what the screen shows (`[#110]`, a person's name), and keep the first column short.
   - Targets come from Playwright locators; never type coordinates by hand.
5. **Run each lane.** Reset data and the guard log between lanes. For a PR, check out base and head in a detached `git worktree` (never touch the user's checkout), start the server per commit, run the lane, swap. Expect about 15 seconds per lane; the server start and Claude's reading dominate.
6. **Assemble.** `cp assets/viewer.html <page>/index.html`, set `<title>` (a name, two to four words). Write `page.json` next to it (schema below) and keep `capture/` beside them. Start the artifact per the Artifact tool's rules (quickstart, plain page) and publish `index.html` with `files` for `page.json`, `capture/*.json` and `capture/frames/*.jpg`.
7. **Verify locally, then publish, then iterate.** `node scripts/verify.mjs <page> 0,5,9 split <repo>/package.json` and read the JSON and the screenshots it writes. Republish the same path so the URL stays. Then draft the PR body: what changed per screen, the artifact link under a 「見て分かるページ」 heading with one line on how to read it (▶ で 1 操作ずつ・光る所は押せる), what the page does not cover, and the capture conditions (fictional data, mocked services). Run `gh pr create` (or `gh pr edit`, `gh issue create`) only when the user says to. The artifact is private until the owner shares it from the page's Share menu; say so, because a link reviewers cannot open is worse than no link.
8. **Clean up and report.** Stop dev servers, remove the throwaway containers and worktrees. The page (the artifact) is the only deliverable: the scenario, `page.json`, captures and images stay in the scratchpad and are not committed to the repo (decided 2026-10-01; a re-shoot after review rewrites the scenario from the code). Report what was verified (local measurements) and what was not (the artifact in the claude.ai viewer, anything 未撮影), which data was fictional, and which external calls were mocked.

## Reviewing someone else's PR

The same workflow, started from a PR number instead of a branch: 「PR #41 をビジュアルレビューして」. Differences:

- Fetch the PR without touching anyone's checkout: `git fetch origin pull/<n>/head:pr-<n>` and `git fetch origin <base>`, then two detached worktrees (`git worktree add <dir> <commit>`). `base` is the merge-base of the PR head and its base branch, not the tip of `main`, so the page shows only what the PR changes.
- Read the PR body first; it usually states the scenario the author cares about. Cover that path, then one thing the body does not mention that the diff touches.
- The two choices (data, external APIs) still come first. A reviewer's run defaults to fictional seed and mocked externals; say so.
- Deliver as a **PR comment** (`gh pr comment <n> --body-file …`), not by editing the author's PR body: the link under 「見て分かるページ」, how to read it in one line, what the page does not cover, the capture conditions, and anything the walkthrough made you doubt (a state the author may not have tried). Post only when the user says to, and remind them to share the artifact first, or the author cannot open it.
- In a cloud session (claude.ai/code) nothing changes in the steps. The skill arrives through claude.ai's skill sync (Settings → Capabilities → Skills; cloud sessions download enabled skills into `~/.claude/skills/synced/`), so there is no setup script to depend on: run `bash <this skill>/scripts/bootstrap.sh --repo . --pg-port <free>` yourself first. It prepares Node, pnpm, Playwright (the VM may already provide browsers via `PLAYWRIGHT_BROWSERS_PATH`; the script respects it) and the throwaway Postgres (Docker if the VM has it, otherwise a local cluster), and writes `~/.cache/visual-walkthrough/env.json` with `playwright_from` and `node_bin`. Setup scripts run before Claude Code starts and never see the environment's variables, and the GitHub proxy returns 403 for repositories not attached to the session, so do not try to fetch the skill or secrets from GitHub there. Keep long commands in the background because each shell call has a time limit, and remember the network access level must allow npm and the Chromium download when browsers are not preinstalled.

## page.json

`title`, `mode` (`pr` | `issue`), `storageKey`, `eyebrow`, `h1`, `tags[]` (`{text, kind: ok|warn}`; state what is real, what is fictional, what is mocked, what was masked), `meta[]` (html lines), `cards[]` (`{k, v, list[], f, kind: req}`; three cards: what changes per screen, or 現状 / 要件 / 提案の作り方), `lanes.before / lanes.after` (`{label, short, who, file, absent}`), `defaultView` (`after` for a PR so the screen is big; `split` for an issue so the difference is visible), `viewHint`, `dbTitle`, `dbWho`, `dbLane`, `logHint`, `annotate` (`{"/path": "label"}` or `{"/path": {text, status}}` for request lines), `externalLabels` (guard rule id → Japanese name), `durations` (`default` plus per frame id), `checksHead`, `checks[]` (`{st: ok|todo|none, stText, title, text, jump, jumpText, disabled}`), `details[]` (`{summary, items[]}`; always one 撮影の条件), `foot[]`.

## Design rules (each learned from a real page)

- **The screen is the page.** Default to one big lane (PR: `after`) with the DB panel beside it; 並べて is one click away. A reviewer said the two-column version was too small.
- **Pixels, not markup.** Screens are viewport screenshots at 2x, JPEG around 86. Rebuilding the DOM elsewhere broke on Next image URLs, self-hosted fonts, canvas previews and inner scroll containers; screenshots have none of those failure classes. Identical frames share one file.
- **One operation per frame; the press and the result are separate frames.** The press frame shows the button highlighted with 「↑ 押す」 and is clickable; the result frame highlights what appeared. A DB change is shown in the frame where it happened.
- **Notes are one line each and tell the truth.** `warn` for a limitation of the current app or a fact the reader might miss, `ok` for what the change achieves. Say when something happened in the background (「この裏で校正も走っている」) and when a response was 503 by design.
- **Tags say what is real.** 「画面は本物のスクリーンショット」, 「データは架空」, 「<外部サービス名> は Claude の代替応答」, 「ロゴは差し替え」, 「未撮影」 on parts you did not capture.
- **Color meanings** are visual-explainer's: amber = being pressed now, green = added or proposed, navy = source; a green outline marks a proposal's edited nodes.
- **Requests**: annotate what a path means in the app's words (品目判定, AI校正の本体, 画面の再取得). Show server actions with their arguments; name the action from the code and say it is an annotation. External calls get the 外部 API badge with the mock rule's Japanese name.
- **Copy density** follows visual-explainer: captions are one line, card titles under 25 characters, no paragraphs under a screen.

## Pitfalls met so far

- A file input may open a modal (crop, confirm) right after `setInputFiles`; record it as its own frame and confirm it in the scenario.
- A native `<select>` never shows its open list in a screenshot; note it (「開いたプルダウンはブラウザ側の描画なので撮影に写らない」) instead of faking it.
- Next dev issues prefetch `document` requests and the guard's mask changes trigger nothing, but `blob:` fetches from PDF previews do appear; the recorder already drops both.
- The app may finish background work before the user acts (a job kicked off on upload completes while a confirmation card is still showing); the DB diff then appears in that earlier frame. Say so in the note.
- Server actions all POST to the page URL. Tell them apart by the shape of their arguments and rewrite `q.path` to `/page#actionName` after the run, saying in the page that the name is an annotation from the code.
- Hide the framework's dev-only chrome (Next's `nextjs-portal` indicator) with an init script before recording; it is not part of the app.
- Playwright inside the repo may not match the browsers in `~/Library/Caches/ms-playwright`; run `npx playwright install chromium` in that repo once.
- Port collisions with other local Postgres instances are common; pick a free port and a distinct container name.
- Respect the repo's Node pin (`.nvmrc`, `engines`, CI's `node-version`) and package manager (`pnpm` when the repo says so). A dev server started with the wrong Node fails in ways that look like app bugs (undici errors, missing APIs); switch with `nvm use` or prepend the right `~/.nvm/versions/node/<v>/bin` to `PATH` for the server and the recorder alike.
- `next/font/google` downloads at dev start; allow the two Google Fonts hosts or the page falls back to system fonts, which the screenshots would then show.
- When the fixture is a document (a label, an invoice), author it in HTML and render with Playwright (`page.pdf()` gives a vector PDF with a text layer; `page.screenshot()` gives the image). Put the deliberate error in the text so the app's own locator finds it. Photos cannot be generated; borrow the repo's samples or ask.

## Verification

Screenshots of the published artifact fail behind the sign-in wall, so measure locally with `scripts/verify.mjs`: zero console errors and failed requests, `scrollWidth === clientWidth` at 1440 and 390, every visible lane has a loaded image, the highlighted frames have `.hl`, press frames have a hotspot, the request log and tables render, and the screenshots it writes look right when you open them. Say in the reply what you measured and that the look in the claude.ai viewer is unconfirmed.
