// HTML のラベルを PNG（プレビュー用）と、文字が生きたベクター PDF（版下として投入する用）にする。
import { createRequire } from "node:module";
import path from "node:path";
const require = createRequire(path.resolve(process.argv[2] || "package.json")) // 対象リポジトリの package.json（その node_modules の playwright を使う）;
const { chromium } = require("playwright");

const src = path.resolve("label/label.html");
const browser = await chromium.launch();
// 180mm × 70mm を CSS px にすると 680 × 265。ビューポートをラベル実寸に合わせて撮る。
const page = await browser.newPage({ viewport: { width: 680, height: 265 }, deviceScaleFactor: 3 });
await page.goto("file://" + src);
await page.waitForTimeout(300);
await page.screenshot({ path: "label/label.png" });
await page.pdf({ path: "label/label.pdf", width: "180mm", height: "70mm", printBackground: true, margin: { top: 0, right: 0, bottom: 0, left: 0 } });
// 誤字の位置（後で赤枠の座標に使う）: ラベル全体に対する正規化座標
const typo = await page.evaluate(() => {
  const th = Array.from(document.querySelectorAll(".ikkatsu th")).find((n) => n.textContent === "原材科名");
  const r = th.getBoundingClientRect(), b = document.body.getBoundingClientRect();
  return { x: r.left / b.width, y: r.top / b.height, w: r.width / b.width, h: r.height / b.height };
});
console.log(JSON.stringify({ typo }));
await browser.close();
