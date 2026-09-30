// 公開前のローカル検証: node verify.mjs <pageDir> [frames=0,5,9] [view=split|before|after] [playwrightFrom]
// publish スケルトンで包んで配信し、PC 幅とスマホ幅で「コンソールエラー・失敗した読み込み・横はみ出し・
// 画像が描かれたか・枠とホットスポットが載ったか」を測り、指定コマのスクリーンショットを <pageDir>/../shot-*.png に残す。
import { createRequire } from "node:module";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const DIR = path.resolve(process.argv[2] || ".");
const SHOTS = (process.argv[3] || "0").split(",").map(Number);
const VIEW = process.argv[4] || "";
const require = createRequire(path.resolve(process.argv[5] || "package.json"));
const { chromium } = require("playwright");

const skeleton = (body) => `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>:root{color-scheme:light}body{margin:0}img{max-width:100%}[hidden]{display:none!important}</style></head><body>${body}</body></html>`;
const types = { ".html": "text/html; charset=utf-8", ".json": "application/json", ".jpg": "image/jpeg", ".png": "image/png", ".woff2": "font/woff2" };
const server = http.createServer((req, res) => {
  const p = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = path.join(DIR, p === "/" ? "index.html" : p);
  if (!file.startsWith(DIR) || !fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  const ext = path.extname(file);
  res.writeHead(200, { "content-type": types[ext] ?? "application/octet-stream" });
  res.end(ext === ".html" && p === "/" ? skeleton(fs.readFileSync(file, "utf8")) : fs.readFileSync(file));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = `http://127.0.0.1:${server.address().port}/`;
const browser = await chromium.launch();
const out = { errors: [], failed: [] };
for (const [name, vp] of [["desktop", { width: 1440, height: 900 }], ["phone", { width: 390, height: 844 }]]) {
  const page = await browser.newPage({ viewport: vp });
  page.on("console", (m) => { if (m.type() === "error") out.errors.push(`${name}: ${m.text().slice(0, 160)}`); });
  page.on("pageerror", (e) => out.errors.push(`${name}: pageerror ${e.message.slice(0, 160)}`));
  page.on("requestfailed", (r) => out.failed.push(`${name}: ${r.url().slice(0, 100)} ${r.failure()?.errorText}`));
  page.on("response", (r) => { if (r.status() >= 400) out.failed.push(`${name}: ${r.status()} ${r.url().slice(0, 100)}`); });
  await page.goto(url);
  await page.waitForFunction(() => document.getElementById("capNo").textContent.trim() !== "– / –", null, { timeout: 30000 });
  await page.waitForTimeout(800);
  const measure = () => page.evaluate(() => {
    const shot = (id) => { const el = document.getElementById(id); if (el.closest(".screen").classList.contains("hidden")) return null; const img = el.querySelector("img"); return { img: !!img && img.complete && img.naturalWidth > 0, hl: !!el.querySelector(".hl"), hotspots: el.querySelectorAll(".hot").length, absent: el.classList.contains("absent") }; };
    return { capT: document.getElementById("capT").textContent, noHorizOverflow: document.documentElement.scrollWidth === document.documentElement.clientWidth, B: shot("shotB"), A: shot("shotA"), logLines: document.querySelectorAll("#log .ln").length, extLines: document.querySelectorAll("#log .ln.ext").length, tables: document.querySelectorAll("#tables .dbt").length, insRows: document.querySelectorAll("#tables tr.ins").length };
  });
  out[name] = { frame0: await measure() };
  if (name === "desktop") {
    if (VIEW) { await page.click(`.seg button[data-view="${VIEW}"]`); await page.waitForTimeout(400); }
    let idx = 0;
    for (const target of SHOTS) {
      while (idx < target) { await page.click("#next"); idx++; }
      await page.waitForTimeout(900);
      out[name][`frame${target}`] = await measure();
      await page.screenshot({ path: path.join(DIR, "..", `shot-${path.basename(DIR)}-${target}.png`) });
    }
  }
  await page.close();
}
await browser.close(); server.close();
console.log(JSON.stringify(out, null, 1));
