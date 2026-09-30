// capture-guard (Node): 撮影中の外向き通信を遮断する。
// 使い方: NODE_OPTIONS="--require /path/to/egress-guard.cjs" npm run dev
// アプリのコードは変えない。ソケット層（net / tls / dns）で止めるので fetch・http・undici を問わず効く。
// 許可: localhost / ループバック IP と CAPTURE_ALLOW_HOSTS（カンマ区切り。例: Google Fonts）。
"use strict";
const net = require("net");
const tls = require("tls");
const dns = require("dns");

const ALLOW = new Set(["localhost", "127.0.0.1", "::1", ...(process.env.CAPTURE_ALLOW_HOSTS || "").split(",").map((s) => s.trim()).filter(Boolean)]);

function blocked(host) {
  if (!host || ALLOW.has(host)) return false;
  if (net.isIP(host)) return !(host.startsWith("127.") || host === "::1" || host === "0.0.0.0");
  return true;
}
function deny(host) {
  const e = new Error(`[capture-guard] 外向き通信を遮断しました: ${host}`);
  e.code = "ECAPTUREGUARD";
  return e;
}
function hostOf(args) {
  const a = args[0];
  if (a && typeof a === "object" && !Array.isArray(a)) return a.host || a.hostname || (a.port ? "localhost" : undefined);
  if (typeof a === "number") return typeof args[1] === "string" ? args[1] : "localhost"; // connect(port, host)
  return undefined; // connect(path) など
}

const origSocketConnect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
  const h = hostOf(args);
  if (blocked(h)) throw deny(h);
  return origSocketConnect.apply(this, args);
};
const origTlsConnect = tls.connect;
tls.connect = function (...args) {
  const h = hostOf(args) || (args[0] && args[0].servername);
  if (blocked(h)) throw deny(h);
  return origTlsConnect.apply(this, args);
};
// undici（Node の fetch）は lookup → connect の順。ここでも止めて、エラーを早く返す。
const origLookup = dns.lookup;
dns.lookup = function (host, ...rest) {
  if (blocked(host)) {
    const cb = rest[rest.length - 1];
    if (typeof cb === "function") return process.nextTick(() => cb(deny(host)));
    throw deny(host);
  }
  return origLookup.call(this, host, ...rest);
};
if (dns.promises && dns.promises.lookup) {
  const origPLookup = dns.promises.lookup;
  dns.promises.lookup = function (host, ...rest) {
    if (blocked(host)) return Promise.reject(deny(host));
    return origPLookup.call(this, host, ...rest);
  };
}
process.stderr.write(`[capture-guard] 有効: 許可ホスト=${[...ALLOW].join(",")}\n`);
