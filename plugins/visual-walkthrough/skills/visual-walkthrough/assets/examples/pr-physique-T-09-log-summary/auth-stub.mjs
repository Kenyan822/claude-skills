// Supabase Auth の代替（撮影専用）。web の proxy.ts / login が叩く 3 エンドポイントだけ持つ。
// 応答は Claude が書いた固定値。呼び出しは CAPTURE_MOCK_LOG に JSON Lines で残し、撮影ページの通信ログに載せる。
import http from "node:http";
import fs from "node:fs";
import crypto from "node:crypto";

const PORT = Number(process.env.PORT || 54329);
const LOG = process.env.CAPTURE_MOCK_LOG;
const USER_ID = "00000000-0000-4000-8000-000000000001";
const EMAIL = "capture@example.com";
const now = () => Math.floor(Date.now() / 1000);
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

// 形だけ正しい HS256 JWT。署名の鍵はダミー（API 側は AUTH_DISABLED=true なので検証しない）
function jwt() {
  const exp = now() + 365 * 24 * 3600;
  const h = b64({ alg: "HS256", typ: "JWT" });
  const p = b64({
    iss: `http://127.0.0.1:${PORT}/auth/v1`, sub: USER_ID, aud: "authenticated", role: "authenticated",
    email: EMAIL, iat: now(), exp, session_id: crypto.randomUUID(), is_anonymous: false, aal: "aal1",
    amr: [{ method: "password", timestamp: now() }],
    app_metadata: { provider: "email", providers: ["email"] }, user_metadata: {},
  });
  const s = crypto.createHmac("sha256", "capture-dummy-secret").update(`${h}.${p}`).digest("base64url");
  return { token: `${h}.${p}.${s}`, exp };
}
const user = () => ({
  id: USER_ID, aud: "authenticated", role: "authenticated", email: EMAIL,
  email_confirmed_at: "2026-01-01T00:00:00Z", phone: "", confirmed_at: "2026-01-01T00:00:00Z",
  last_sign_in_at: new Date().toISOString(),
  app_metadata: { provider: "email", providers: ["email"] }, user_metadata: {}, identities: [],
  created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", is_anonymous: false,
});
function log(rule, method, path) {
  if (LOG) fs.appendFileSync(LOG, JSON.stringify({ ts: Date.now() / 1000, service: "Supabase Auth", method, model: path, mocked: true, rule }) + "\n");
}

http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const send = (code, obj) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
    process.stderr.write(`[auth-stub] ${req.method} ${u.pathname}${u.search}\n`);
    if (u.pathname === "/auth/v1/token" && req.method === "POST") {
      const grant = u.searchParams.get("grant_type");
      const { token, exp } = jwt();
      log(grant === "password" ? "auth-login" : "auth-refresh", "POST", `/auth/v1/token?grant_type=${grant}`);
      return send(200, { access_token: token, token_type: "bearer", expires_in: exp - now(), expires_at: exp, refresh_token: crypto.randomUUID(), user: user() });
    }
    if (u.pathname === "/auth/v1/user" && req.method === "GET") {
      log("auth-user", "GET", "/auth/v1/user");
      const auth = req.headers.authorization || "";
      if (!auth.startsWith("Bearer ")) return send(401, { code: 401, msg: "no token" });
      return send(200, user());
    }
    if (u.pathname === "/auth/v1/logout") { log("auth-logout", "POST", "/auth/v1/logout"); return send(204, {}); }
    log("auth-other", req.method, u.pathname);
    return send(404, { code: 404, msg: "not found in stub" });
  });
}).listen(PORT, "127.0.0.1", () => process.stderr.write(`[auth-stub] listening ${PORT}\n`));
