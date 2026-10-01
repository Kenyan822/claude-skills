// visual-walkthrough 撮影ライブラリ。本物のアプリを Playwright で操作し、1 操作ごとに
//   ・画面（2 倍解像度の JPEG。Chromium が描いたピクセルそのもの）
//   ・押した要素の位置と role / name（次のコマへ飛ぶホットスポットになる）
//   ・ブラウザ→サーバーの通信と、サーバー→外部 API の呼び出し（capture-guard の記録）
//   ・DB / ストレージの差分（テーブルの現在値は呼び手が返す。差分はここで取る）
// を記録して <outDir>/<lane>.json と <outDir>/frames/<lane>-NN.jpg に書く。
// 画面を描き直す処理は持たない。写してはいけない要素（顧客ロゴなど）は mask で撮影直前に差し替える。
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";

export async function createCapture(opts) {
  const {
    base, lane, outDir,
    viewport = { width: 1280, height: 860 }, scale = 2, jpegQuality = 86,
    playwrightFrom, login, cookies, tables, externalLog, mask = [],
    ignoreRequest = () => false, locale = "ja-JP", timezoneId = "Asia/Tokyo",
  } = opts;
  if (!base || !lane || !outDir) throw new Error("createCapture: base / lane / outDir は必須");
  const require = createRequire(path.resolve(playwrightFrom ?? "package.json"));
  const { chromium } = require("playwright");

  const framesDir = path.join(outDir, "frames");
  fs.mkdirSync(framesDir, { recursive: true });
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: scale, locale, timezoneId });
  if (cookies) await ctx.addCookies(cookies);
  if (login) await login(ctx);
  const page = await ctx.newPage();

  // ── 通信ログ（ブラウザ→サーバー）────────────────────────────
  const netLog = [];
  let netMark = 0;
  page.on("request", (req) => {
    let u;
    try { u = new URL(req.url()); } catch { return; }
    if (u.protocol !== "http:" && u.protocol !== "https:") return;
    if (u.origin !== new URL(base).origin) return;
    if (!["document", "fetch", "xhr"].includes(req.resourceType())) return;
    if (req.resourceType() === "document" && !req.isNavigationRequest()) return;
    if (/^\/(_next\/|__nextjs|favicon\.ico$)/.test(u.pathname) || ignoreRequest(u, req)) return;
    const h = req.headers();
    const e = {
      ts: Date.now() / 1000, kind: "http", method: req.method(), path: u.pathname + u.search, status: null,
      sub: h["next-action"] ? "server-action" : h["rsc"] === "1" ? "rsc" : "",
      body: h["next-action"] ? (req.postData() ?? "").slice(0, 600) : null,
    };
    netLog.push(e);
    req.response().then((r) => { if (r) e.status = r.status(); }).catch(() => {});
  });
  // ── 外部 API の記録（capture-guard の JSON Lines）────────────
  let extMark = 0;
  function externalEntries() {
    if (!externalLog || !fs.existsSync(externalLog)) return [];
    const lines = fs.readFileSync(externalLog, "utf8").split("\n").filter(Boolean);
    const fresh = lines.slice(extMark).map((l) => JSON.parse(l));
    extMark = lines.length;
    return fresh.map((m) => ({
      ts: m.ts, kind: "external",
      service: m.service ?? (m.kind === "gemini" || m.kind === "gemini-embed" ? "Vertex AI Gemini" : m.kind),
      method: m.method ?? (m.kind === "gemini-embed" ? "embed_content" : "generate_content"),
      path: m.model ?? "", status: m.mocked ? "mock" : "blocked", note: m.rule ?? "", images: m.images ?? 0,
    }));
  }
  // ── DB 差分 ───────────────────────────────────────────────
  let prevTables = tables ? await tables() : [];
  async function tablesDiff() {
    if (!tables) return [];
    const cur = await tables();
    const out = cur.map((t, i) => {
      const p = new Map((prevTables[i]?.rows ?? []).map((r) => [r.id, JSON.stringify(r.cells)]));
      const ins = [], upd = [];
      for (const r of t.rows) { if (!p.has(r.id)) ins.push(r.id); else if (p.get(r.id) !== JSON.stringify(r.cells)) upd.push(r.id); }
      return { ...t, ins, upd };
    });
    prevTables = cur;
    return out;
  }
  // ── マスク：撮影直前に差し替える（顧客ロゴ・実名など）─────────
  async function applyMask(p = page) {
    if (!mask.length) return;
    await p.evaluate((rules) => {
      for (const r of rules) {
        for (const el of document.querySelectorAll(r.selector)) {
          if (el.hasAttribute("data-cap-masked")) continue;
          const rect = el.getBoundingClientRect();
          const box = document.createElement("span");
          box.setAttribute("data-cap-masked", "");
          box.textContent = r.label ?? "SAMPLE";
          box.style.cssText = `display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;width:${rect.width}px;height:${rect.height}px;border-radius:6px;background:${r.background ?? "#1E3A5C"};color:${r.color ?? "#fff"};font:700 ${Math.max(10, Math.min(16, rect.height * 0.5))}px/1 "Hiragino Sans",sans-serif;letter-spacing:.08em;vertical-align:middle;${r.style ?? ""}`;
          el.replaceWith(box);
        }
      }
    }, mask);
  }
  // ── 画面の保存（同じ画面は 1 枚に共有）──────────────────────
  const imageByHash = new Map();
  let seq = 0;
  async function shoot(p, fullPage = false) {
    const buf = await p.screenshot({ type: "jpeg", quality: jpegQuality, fullPage, scale: "device" });
    const hash = createHash("sha1").update(buf).digest("hex");
    let file = imageByHash.get(hash);
    if (!file) {
      file = `frames/${lane}-${String(++seq).padStart(2, "0")}.jpg`;
      fs.writeFileSync(path.join(outDir, file), buf);
      imageByHash.set(hash, file);
    }
    const size = fullPage
      ? await p.evaluate(() => ({ w: document.documentElement.scrollWidth, h: document.documentElement.scrollHeight }))
      : { w: viewport.width, h: viewport.height };
    return { image: file, ...size };
  }
  async function measure(target) {
    if (!target) return { hl: null, target: null };
    const el = target.first();
    await el.waitFor({ state: "visible", timeout: 10000 });
    await el.scrollIntoViewIfNeeded();
    await page.waitForTimeout(120);
    const box = await el.boundingBox();
    const meta = await el.evaluate((n) => ({
      role: n.getAttribute("role") || n.tagName.toLowerCase(),
      name: (n.getAttribute("aria-label") || n.textContent || "").trim().replace(/\s+/g, " ").slice(0, 60),
    }));
    return { hl: box ? { x: box.x, y: box.y, w: box.width, h: box.height } : null, target: meta };
  }

  const frames = [];
  async function record(id, cap, o = {}) {
    if (o.run) await o.run(page);
    if (o.wait) await o.wait(page);
    await page.waitForTimeout(o.settle ?? 300);
    await applyMask();
    const { hl, target } = await measure(o.target);
    const shot = await shoot(page);
    const req = [...netLog.slice(netMark).map((e) => ({ ...e })), ...externalEntries()].sort((a, b) => a.ts - b.ts);
    netMark = netLog.length;
    const frame = {
      id, cap, act: o.act ?? null, note: o.note ?? "", warn: !!o.warn, ok: !!o.ok, up: !!o.up, absent: !!o.absent,
      ...shot, dpr: scale, hl, hotspots: [], target, req, db: { tables: await tablesDiff() },
    };
    if (o.hotspot && hl) frame.hotspots.push({ ...hl, next: frames.length + 1, role: target?.role, name: target?.name });
    frames.push(frame);
    console.error(`[${lane}] ${id}: img=${shot.image} hl=${!!hl} req=${req.length} ins=${frame.db.tables.map((t) => t.ins.length).join("/") || "-"}`);
    return frame;
  }

  const api = {
    page, ctx, lane, frames,
    goto: (p, o) => page.goto(p.startsWith("http") ? p : base + p, o),
    /** 画面を 1 コマ記録する。o.run は撮る前に実行する操作、o.target は光らせる要素。 */
    step: record,
    /** 押す前のコマを記録し（対象を光らせ、次のコマへのホットスポットを付け）、それから押す。結果は次の step で記録する。 */
    async press(id, cap, target, o = {}) {
      await record(id, cap, { ...o, target, act: o.act ?? "↑ 押す", hotspot: true });
      await target.first().click(o.click);
    },
    /** 入力してからコマを記録する。 */
    async type(id, cap, target, text, o = {}) {
      await target.first().fill(text);
      return record(id, cap, { ...o, target, act: o.act ?? "入力" });
    },
    /** 選択してからコマを記録する。 */
    async select(id, cap, target, option, o = {}) {
      await target.first().selectOption(option);
      return record(id, cap, { ...o, target, act: o.act ?? "選ぶ" });
    },
    /** trigger() が開く別タブを 1 コマとして記録する（全体をスクロール込みで撮る）。ready(popup) で描画完了を待つ。 */
    async popup(id, cap, trigger, o = {}) {
      const [pop] = await Promise.all([page.waitForEvent("popup"), trigger(page)]);
      if (o.ready) await o.ready(pop);
      await pop.waitForTimeout(o.settle ?? 300);
      await applyMask(pop);
      const shot = await shoot(pop, true);
      const req = [...netLog.slice(netMark).map((e) => ({ ...e })), ...externalEntries()];
      netMark = netLog.length;
      const frame = { id, cap, act: o.act ?? null, note: o.note ?? "", warn: !!o.warn, ok: !!o.ok, up: false, absent: false, ...shot, dpr: scale, hl: null, hotspots: [], target: null, req, db: { tables: await tablesDiff() }, popup: true };
      frames.push(frame);
      console.error(`[${lane}] ${id}: popup img=${shot.image} ${shot.w}x${shot.h}`);
      const extra = o.extract ? await o.extract(pop) : null;
      if (!o.keep) await pop.close();
      return { frame, extra };
    },
    /** このレーンに対応する操作が無いコマ。直前の画面を据え置きで記録する。 */
    absent(id, cap, note) {
      const prev = frames[frames.length - 1];
      const frame = { ...prev, id, cap, act: null, note: note ?? "", warn: true, ok: false, absent: true, hl: null, hotspots: [], req: [], db: { tables: (prev?.db.tables ?? []).map((t) => ({ ...t, ins: [], upd: [] })) } };
      frames.push(frame);
      return frame;
    },
    /** ブラウザの中で DOM を編集してから記録する（issue の「提案」画面。実装前の見え方を本物の画面の上に作る）。 */
    async edit(id, cap, editFn, o = {}) {
      await page.evaluate(editFn, o.arg ?? null);
      return record(id, cap, { ...o, proposal: true });
    },
    async finish(extra = {}) {
      const out = path.join(outDir, `${lane}.json`);
      fs.writeFileSync(out, JSON.stringify({ lane, base, viewport, dpr: scale, capturedAt: new Date().toISOString(), frames, ...extra }));
      await browser.close();
      console.error(`[${lane}] wrote ${out}: ${frames.length} frames, ${imageByHash.size} images, ${(fs.readdirSync(framesDir).filter((f) => f.startsWith(lane + "-")).reduce((a, f) => a + fs.statSync(path.join(framesDir, f)).size, 0) / 1024 | 0)} KB`);
      return out;
    },
  };
  return api;
}

// ── DB / ストレージの現在値を返すヘルパー ──────────────────────────
/** docker コンテナ内の psql で複数のテーブルを読む。queries: [{ name, sql, columns }]。sql の 1 列目が行の id。 */
export function dockerPsqlTables({ container, user, db, queries }) {
  return async () => queries.map((q) => {
    const out = execFileSync("docker", ["exec", container, "psql", "-U", user, "-d", db, "-At", "-F", "\t", "-c", q.sql], { encoding: "utf8" }).trim();
    const rows = out ? out.split("\n").map((l) => l.split("\t")) : [];
    return { name: q.name, columns: q.columns, rows: rows.map((r) => ({ id: r[0], cells: (q.format ? q.format(r) : r) })) };
  });
}
/** 接続 URL で Node の pg から複数のテーブルを読む（Docker 無しのローカル Postgres 用。psql コマンドが要らない）。queries は dockerPsqlTables と同じ形。requireFrom は pg を入れた package.json（bootstrap.sh の env.json の pg_from）。 */
export function pgTables({ url, queries, requireFrom }) {
  const { Client } = createRequire(requireFrom)("pg");
  return async () => {
    const c = new Client({ connectionString: url });
    await c.connect();
    try {
      const out = [];
      for (const q of queries) {
        const res = await c.query({ text: q.sql, rowMode: "array" });
        const rows = res.rows.map((r) => r.map((v) => (v === null ? "NULL" : v instanceof Date ? v.toISOString() : String(v))));
        out.push({ name: q.name, columns: q.columns, rows: rows.map((r) => ({ id: r[0], cells: q.format ? q.format(r) : r })) });
      }
      return out;
    } finally {
      await c.end();
    }
  };
}
/** bootstrap.sh が書いた env.json を読み、pg.mode に応じて dockerPsqlTables / pgTables を選ぶ。 */
export function tablesFromEnv(envJsonPath, queries) {
  const env = JSON.parse(fs.readFileSync(envJsonPath, "utf8"));
  if (env.pg?.mode === "docker") return dockerPsqlTables({ container: env.pg.container, user: env.pg.user, db: env.pg.db, queries });
  if (env.pg?.mode === "local") return pgTables({ url: env.pg.url, queries, requireFrom: env.pg_from });
  throw new Error("env.json に使える Postgres がありません（bootstrap.sh を先に実行）");
}
/** fake-gcs-server のバケット内オブジェクト一覧を 1 テーブルとして返す。 */
export function gcsEmulatorTable({ url, bucket, name }) {
  return async () => {
    const res = await fetch(`${url}/storage/v1/b/${bucket}/o`);
    const items = res.ok ? ((await res.json()).items ?? []) : [];
    return [{ name: name ?? `GCS ${bucket}`, columns: ["object", "size", "content-type"], rows: items.map((o) => ({ id: o.name, cells: [o.name, `${Math.round(o.size / 1024)} KB`, o.contentType ?? ""] })) }];
  };
}
/** 複数のテーブル取得関数をまとめる。 */
export function combineTables(...fns) {
  return async () => (await Promise.all(fns.map((f) => f()))).flat();
}
