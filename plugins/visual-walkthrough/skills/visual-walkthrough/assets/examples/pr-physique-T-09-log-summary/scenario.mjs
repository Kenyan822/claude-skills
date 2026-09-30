// お手本（physique-analytics PR #238 の撮影）。実行するときは capture-lib.mjs の import 先、playwrightFrom、コンテナ名、ポートを自分の環境に合わせる。
// feat/T-09-web-log-per-exercise-summary の撮影シナリオ。/log で 2 種目・3 セットを記録し、1 本消す。
// lane = before（main 0ed0e7e）| after（8664c8e）。同じ操作を両方で行う。
// 実行: node scenario.mjs <before|after>   （run-lane.sh が dev サーバーの起動と DB の掃除をしてから呼ぶ）
import { createCapture, dockerPsqlTables } from "../../../scripts/capture-lib.mjs";
import fs from "node:fs";
import path from "node:path";

const lane = process.argv[2];
if (!["before", "after"].includes(lane)) throw new Error("usage: scenario.mjs <before|after>");
const S = path.dirname(new URL(import.meta.url).pathname);
const BASE = "http://localhost:3100";
const EXT_LOG = path.join(S, "auth-stub.log");

const cap = await createCapture({
  base: BASE, lane, outDir: path.join(S, "page", "capture"),
  playwrightFrom: path.join(S, "pw", "package.json"),
  externalLog: EXT_LOG,
  // Supabase Auth は手元の代替サーバー。ログイン画面を 1 回通して Cookie を作らせる（撮影には含めない）
  login: async (ctx) => {
    const p = await ctx.newPage();
    await p.goto(BASE + "/login");
    await p.getByLabel("メールアドレス").fill("capture@example.com");
    await p.getByLabel("パスワード").fill("capture-dummy-password");
    await Promise.all([p.waitForURL((u) => u.pathname === "/"), p.getByRole("button", { name: "ログイン" }).click()]);
    // /log を一度開いてコンパイルを済ませる（Turbopack の初回が撮影に入らないように）
    await p.goto(BASE + "/log");
    await p.getByRole("button", { name: /^種目/ }).waitFor();
    await p.close();
    fs.writeFileSync(EXT_LOG, "");
  },
  tables: dockerPsqlTables({
    container: "physique-capture-db", user: "physique", db: "physique",
    queries: [
      { name: "workout_sessions", columns: ["id", "date", "sets"],
        sql: `select left(s.id::text, 8), to_char(s.date, 'YYYY-MM-DD'), count(w.id) filter (where w.deleted_at is null) from workout_sessions s left join workout_sets w on w.session_id = s.id group by s.id, s.date, s.created_at order by s.date, s.created_at` },
      { name: "workout_sets", columns: ["id", "date", "種目", "#", "kg", "reps", "RIR", "deleted_at"],
        sql: `select left(w.id::text, 8), to_char(s.date, 'YYYY-MM-DD'), e.name, w.set_no, w.weight_kg, w.reps, coalesce(w.rir::text, 'NULL'), coalesce(to_char(w.deleted_at, 'HH24:MI:SS'), '-') from workout_sets w join workout_sessions s on s.id = w.session_id join exercises e on e.id = w.exercise_id order by s.date, w.created_at, e.name, w.set_no`,
        format: (r) => [r[0], r[1], r[2], "#" + r[3], String(Number(r[4])), r[5], r[6] === "NULL" ? "NULL" : "@" + r[6], r[7] === "-" ? "" : r[7]] },
    ],
  }),
});

const page = cap.page;
// Next.js の開発インジケータ（左下の N）はアプリの一部ではないので写さない
// 初期化スクリプトの時点では document がまだ無いので、DOMContentLoaded で head に足す
await page.addInitScript(() => {
  document.addEventListener("DOMContentLoaded", () => {
    const style = document.createElement("style");
    style.textContent = "nextjs-portal{display:none!important}";
    document.head.appendChild(style);
  });
});
const isAfter = lane === "after";
const pickBtn = page.getByRole("button", { name: /^種目/ });
const dialog = page.getByRole("dialog", { name: "種目を選ぶ" });
const search = dialog.getByPlaceholder("種目を探す");
const exRow = (re) => dialog.getByRole("button", { name: re });
const recordBtn = (n) => page.getByRole("button", { name: `${n} セット目を記録` });
const today = page.locator("section").filter({ has: page.getByRole("heading", { name: "今日の記録" }) });
const total = (n) => today.getByText(new RegExp(`^${n} セット / `));
const chips = page.getByRole("list", { name: "種目ごとの小計" });
const chip = (name) => chips.getByRole("listitem").filter({ hasText: name });
const weightIs = (v) => page.waitForFunction((v) => document.querySelector('input[aria-label="重量"]')?.value === v, v);

await cap.goto("/log");
await cap.step("open", "/log を開く。今日はまだ何も記録していない", {
  wait: () => pickBtn.waitFor(), note: "「今日の記録」の欄は 1 セット記録すると現れる",
});

await cap.press("pick-press", "「種目」を押す", pickBtn);
await cap.press("pick-bench", "「ベンチ」で絞り、ベンチプレスを押す", exRow(/^ベンチプレス/), {
  run: async () => { await search.waitFor(); await search.fill("ベンチ"); },
  note: "49 種目から検索で 4 件に絞る（T-01）",
});
await cap.press("rec1-press", "前回値のまま「1 セット目を記録」を押す", recordBtn(1), {
  wait: () => weightIs("60"), note: "前回（9/28）の 60×8 @2 が初期値に入る（T-02）", up: true,
});
await cap.step("rec1", "今日の記録に 1 行入る", {
  wait: () => total(1).waitFor(),
  ...(isAfter
    ? { target: chips, act: "種目ごとの小計が出る", note: "ベンチプレス 1 セット · 480 kg", ok: true }
    : { target: total(1), act: "出るのは合計だけ", note: "1 種目のうちは合計と同じなので困らない" }),
});

await cap.press("rec2-press", "「2 セット目を記録」を押す", recordBtn(2), { note: "値は据え置き。次のセットも同じ重量で入ることが多い（T-04）", up: true });
await cap.step("rec2", "2 セット目が入る", {
  wait: () => total(2).waitFor(),
  ...(isAfter
    ? { target: chip("ベンチプレス"), act: "2 セット · 960 kg に更新", ok: true }
    : { target: total(2), act: "合計 2 セット / 960 kg" }),
});

await cap.press("pick2-press", "種目を切り替える", pickBtn);
await cap.press("pick2-squat", "「スクワット」で絞り、スクワットを押す", exRow(/^スクワット/), {
  run: async () => { await search.waitFor(); await search.fill("スクワット"); },
  note: "3 件に絞られる",
});
await cap.press("rec3-press", "前回値のまま「1 セット目を記録」を押す", recordBtn(1), {
  wait: () => weightIs("80"), note: "スクワットの前回値 80×5 @2 が入る。セット番号は種目ごとに 1 から", up: true,
});
await cap.step("rec3", "今日の記録が 3 行になる", {
  wait: () => total(3).waitFor(),
  ...(isAfter
    ? { target: chips, act: "2 種目の小計が並ぶ", note: "ベンチプレス 2 セット · 960 kg ／ スクワット 1 セット · 400 kg", ok: true }
    : { target: total(3), act: "合計 3 セット / 1,360 kg だけ", note: "種目ごとの数は一覧を上から数えるしかない", warn: true }),
});

await cap.press("del-press", "ベンチプレス #1 の × を押す（T-10）", page.getByRole("button", { name: "ベンチプレス 1セット目を削除" }));
await cap.step("deleted", "1 行消える", {
  wait: () => total(2).waitFor(),
  ...(isAfter
    ? { target: chip("ベンチプレス"), act: "小計も 1 セット · 480 kg に減る", note: "DB は deleted_at が立つだけ（論理削除、ADR-0014）", ok: true }
    : { target: total(2), act: "合計 2 セット / 880 kg", note: "DB は deleted_at が立つだけ（論理削除、ADR-0014）" }),
});

// Server Action は全部 POST /log で区別が付かない。引数の形から関数名（actions.ts）を推定して path に付ける。
// 名前はコードから特定した注記であり、通信に含まれていたものではない
const setIds = new Set();
for (const f of cap.frames) {
  for (const q of f.req) {
    if (q.kind !== "http" || q.sub !== "server-action" || !q.body) continue;
    let arg;
    try { arg = JSON.parse(q.body)[0]; } catch { continue; }
    if (arg && typeof arg === "object" && "setNo" in arg) { setIds.add(arg.id); q.path = "/log#recordSet"; }
    else if (typeof arg === "string") q.path = setIds.has(arg) ? "/log#deleteSet" : "/log#loadLastPerformance";
  }
}
await cap.finish();
