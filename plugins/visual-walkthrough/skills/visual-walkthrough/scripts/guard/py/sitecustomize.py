"""capture-guard (Python): 撮影中の外向き通信を遮断し、Gemini 呼び出しに Claude が書いた応答を返す。

アプリのコードは変えない。起動時に PYTHONPATH にこのディレクトリを足すだけで、Python が
sitecustomize として自動で読み込む。

環境変数:
  CAPTURE_ALLOW_HOSTS  追加で許可するホスト（カンマ区切り）。localhost / 127.0.0.1 / ::1 は常に許可
  CAPTURE_MOCK_FILE    Gemini の応答定義 JSON（{"rules": [{"id", "prompt_contains": [...], "text"}]}）
  CAPTURE_MOCK_LOG     呼び出し記録の出力先（JSON Lines）。撮影スクリプトが通信ログに載せる

遮断はソケット層（getaddrinfo / connect）で行うので、httpx・requests・asyncpg など
ライブラリを問わず効く。許可外への接続は OSError で即失敗させる（黙って素通しも、
黙って空応答も返さない）。
"""

import ipaddress
import json
import os
import socket
import sys
import time

_ALLOW = {"localhost", "127.0.0.1", "::1"} | {
    h.strip() for h in os.environ.get("CAPTURE_ALLOW_HOSTS", "").split(",") if h.strip()
}
_MOCK_FILE = os.environ.get("CAPTURE_MOCK_FILE", "")
_MOCK_LOG = os.environ.get("CAPTURE_MOCK_LOG", "")


def _blocked(host) -> bool:
    if host is None:
        return False
    h = str(host)
    if h in _ALLOW:
        return False
    try:
        return not ipaddress.ip_address(h).is_loopback
    except ValueError:
        return True  # 未知のホスト名は全部遮断


# ── ソケット層の遮断 ─────────────────────────────────────────
_orig_getaddrinfo = socket.getaddrinfo
_orig_connect = socket.socket.connect
_orig_connect_ex = socket.socket.connect_ex


def _getaddrinfo(host, *args, **kwargs):
    if _blocked(host):
        raise OSError(f"[capture-guard] 外向き通信を遮断しました: {host}")
    return _orig_getaddrinfo(host, *args, **kwargs)


def _connect(self, address):
    if isinstance(address, tuple) and _blocked(address[0]):
        raise OSError(f"[capture-guard] 外向き通信を遮断しました: {address[0]}")
    return _orig_connect(self, address)


def _connect_ex(self, address):
    if isinstance(address, tuple) and _blocked(address[0]):
        raise OSError(f"[capture-guard] 外向き通信を遮断しました: {address[0]}")
    return _orig_connect_ex(self, address)


socket.getaddrinfo = _getaddrinfo
socket.socket.connect = _connect
socket.socket.connect_ex = _connect_ex


# ── Gemini（google-genai）の代替応答 ─────────────────────────
def _log(entry: dict) -> None:
    if not _MOCK_LOG:
        return
    with open(_MOCK_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def _install_genai_mock() -> None:
    try:
        from google.genai import models as gm
        from google.genai import types
    except Exception:  # noqa: BLE001 - google-genai を使わないプロセスでは何もしない
        return

    rules = []
    if _MOCK_FILE:
        with open(_MOCK_FILE, encoding="utf-8") as f:
            rules = json.load(f).get("rules", [])

    def _collect(contents, config):
        """プロンプト本文と system_instruction の文字列を集め、画像 Part の枚数を数える。"""
        texts, images = [], 0

        def walk(x):
            nonlocal images
            if x is None:
                return
            if isinstance(x, str):
                texts.append(x)
                return
            if isinstance(x, (list, tuple)):
                for i in x:
                    walk(i)
                return
            if getattr(x, "inline_data", None) is not None or getattr(x, "file_data", None) is not None:
                images += 1
            t = getattr(x, "text", None)
            if isinstance(t, str):
                texts.append(t)
            parts = getattr(x, "parts", None)
            if parts:
                walk(parts)

        walk(contents)
        walk(getattr(config, "system_instruction", None) if config is not None else None)
        return "\n".join(texts), images

    def _response(text: str, prompt_chars: int, images: int):
        # トークン数は概算（アプリの usage ログ用。課金は発生していない）
        p = images * 1120 + prompt_chars // 2
        c = max(1, len(text) // 2)
        return types.GenerateContentResponse(
            candidates=[
                types.Candidate(
                    content=types.Content(role="model", parts=[types.Part(text=text)]),
                    finish_reason=types.FinishReason.STOP,
                )
            ],
            usage_metadata=types.GenerateContentResponseUsageMetadata(
                prompt_token_count=p, candidates_token_count=c, total_token_count=p + c
            ),
        )

    def generate_content(self, *, model, contents, config=None, **_kw):
        prompt, images = _collect(contents, config)
        rule = next(
            (r for r in rules if all(s in prompt for s in r.get("prompt_contains", []))),
            None,
        )
        _log(
            {
                "ts": time.time(),
                "kind": "gemini",
                "model": model,
                "rule": rule["id"] if rule else None,
                "images": images,
                "prompt_chars": len(prompt),
                "prompt_head": prompt[:120],
                "mocked": rule is not None,
            }
        )
        if rule is None:
            raise RuntimeError(
                "[capture-guard] この Gemini 呼び出しに対応するモック応答がありません: "
                f"model={model} prompt={prompt[:200]!r}"
            )
        return _response(rule["text"], len(prompt), images)

    async def generate_content_async(self, *, model, contents, config=None, **kw):
        return generate_content(self, model=model, contents=contents, config=config, **kw)

    def embed_content(self, **kw):
        _log({"ts": time.time(), "kind": "gemini-embed", "mocked": False})
        raise RuntimeError("[capture-guard] embed_content のモック応答は定義されていません")

    gm.Models.generate_content = generate_content
    gm.AsyncModels.generate_content = generate_content_async
    gm.Models.embed_content = embed_content
    gm.AsyncModels.embed_content = embed_content


_install_genai_mock()
print(
    f"[capture-guard] 有効: 許可ホスト={sorted(_ALLOW)} モック定義={_MOCK_FILE or '(なし)'}",
    file=sys.stderr,
)
