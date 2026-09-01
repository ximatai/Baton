#!/usr/bin/env python3
"""Tiny in-memory Baton Companion Profile fixture with an optional LLM backend."""
from __future__ import annotations

import argparse
import copy
import html
import json
import secrets
import threading
import time
import uuid
import zlib
from io import BytesIO
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib import error as urlerror
from urllib import request as urlrequest


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def fixture_log(event, **fields):
    """Emit useful local diagnostics without writing conversation secrets."""
    details = " ".join(f"{key}={value}" for key, value in fields.items() if value is not None)
    suffix = f" {details}" if details else ""
    print(f"[Baton mock] {now()} {event}{suffix}", flush=True)


def _png_chunk(kind, payload):
    import struct
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


def demo_image_png():
    """Generate a small deterministic, static RGB PNG without an image dependency."""
    import struct
    width, height = 320, 200
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # PNG's no-filter byte
        for x in range(width):
            rows.extend((35 + x * 90 // width, 110 + y * 80 // height, 190 - x * 70 // width))
    return b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + _png_chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + _png_chunk(b"IEND", b"")


DEMO_IMAGE_PATH = "/v1/baton/media/mock-chart.png"
DEMO_IMAGE_ID = "med_mock_chart_v1"
DEMO_IMAGE_ALT = "蓝色渐变的本地 Mock 图表示例"
DEMO_IMAGE_BYTES = demo_image_png()


class Store:
    def __init__(self, base_url, *, event_retention=64):
        self.base_url, self.lock = base_url.rstrip("/"), threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.pairings, self.tokens, self.events = {}, {}, []
        self.runs, self.messages, self.next_sequence = {}, [], 1
        self.conversation_closed = False
        self.conversation_epoch = 0
        self.fail_next_completion_for_test = False
        self.slow_next_completion_seconds = 0
        self.event_retention = max(1, event_retention)
        self.conversation_id = None
        self.reset_conversation()

    def reset_conversation(self):
        self.conversation_epoch += 1
        # A new handoff is a new server-owned conversation, rather than a
        # recycled fixture ID with an unrelated event sequence.
        self.conversation_id = "conv_" + uuid.uuid4().hex
        self.messages, self.runs, self.events, self.next_sequence = [], {}, [], 1
        self.conversation_closed = False
        welcome = self.add_message(
            "msg_welcome", None, "assistant", content=[
                {"type": "text", "text": "这是本地 Baton Mock Server，可以直接开始对话。\n\n这是一个受认证图片示例："},
                {"type": "image", "media_id": DEMO_IMAGE_ID, "url": self.base_url + DEMO_IMAGE_PATH, "mime_type": "image/png", "width": 320, "height": 200, "alt": DEMO_IMAGE_ALT},
                {"type": "text", "text": "\n\n图片与会话一样仅从同源服务读取。"},
            ]
        )
        self.event("conversation.snapshot", {"conversation_id": self.conversation_id, "messages": [welcome]})

    def close_conversation(self):
        if self.conversation_closed: return False
        self.conversation_closed = True
        self.conversation_epoch += 1
        # Invitations and credentials are capabilities for this exact
        # conversation. End is a single shared boundary, not local UI state.
        for pairing in self.pairings.values():
            pairing["status"] = "expired"
            if pairing.get("request"):
                pairing["request"]["access_token"] = None
        self.tokens.clear()
        self.event("conversation.closed", {"conversation_id": self.conversation_id})
        return True

    def add_message(self, message_id, client_id, role, text=None, status="completed", content=None):
        message = {"id": message_id, "client_message_id": client_id,
                   "conversation_id": self.conversation_id, "role": role,
                   "content": copy.deepcopy(content) if content is not None else [{"type": "text", "text": text}], "created_at": now(), "status": status}
        self.messages.append(message)
        return message

    def event(self, event_type, data):
        with self.condition:
            event = {"id": "evt_" + uuid.uuid4().hex[:16], "sequence": self.next_sequence,
                     "type": event_type, "occurred_at": now(), "data": copy.deepcopy(data)}
            self.next_sequence += 1
            self.events.append(event)
            del self.events[:-self.event_retention]
            self.condition.notify_all()
        fixture_log("conversation.event", type=event_type, sequence=event["sequence"])
        return event

    def event_cursor(self):
        """Return the latest *retained* event as a resumable snapshot cursor."""
        latest = self.events[-1]
        return {"id": latest["id"], "sequence": latest["sequence"]}

    def set_event_retention_for_test(self, retain_last):
        """Fixture-only deterministic retention hook; never part of Baton/1.1."""
        self.event_retention = max(1, retain_last)
        del self.events[:-self.event_retention]

    def active_pairing(self, pairing_id):
        pairing = self.pairings.get(pairing_id)
        if not pairing:
            return None, "pairing_not_found"
        if time.time() >= pairing["expires_at"] and pairing["status"] != "rejected":
            pairing["status"] = "expired"
        return pairing, "pairing_expired" if pairing["status"] == "expired" else None

    def new_token(self, device_id, conversation_id):
        token = "baton_local_" + secrets.token_urlsafe(18)
        session_id = "ses_" + secrets.token_urlsafe(18)
        self.tokens[token] = {"device_id": device_id, "session_id": session_id,
                              "conversation_id": conversation_id}
        return token, session_id

    def is_current_run(self, run_id, epoch, *, status="active"):
        run = self.runs.get(run_id)
        return (not self.conversation_closed and self.conversation_epoch == epoch
                and run is not None and run["epoch"] == epoch and run["status"] == status)

    def cancel_run(self, run_id):
        """Make cancellation terminal immediately; a blocked provider is irrelevant."""
        with self.lock:
            run = self.runs.get(run_id)
            if not run:
                return None, None
            if run["status"] == "cancelled":
                return "cancelled", False
            if run["status"] != "active":
                return run["status"], False
            run["status"] = "cancelled"
            message = next((item for item in self.messages if item["id"] == run["message_id"]), None)
            if message:
                message["status"] = "cancelled"
            self.event("message.completed", {"message_id": run["message_id"], "status": "cancelled"})
            self.event("run.cancelled", {"run_id": run_id, "status": "cancelled"})
            return "cancelled", True


STORE = None
CHAT_COMPLETER = None
SSE_LIVE_SECONDS = 300
REVIEW_DEMO_TOKEN = None
REVIEW_DEMO_TTL_SECONDS = 45


class ChatCompletionError(Exception):
    """An upstream chat provider failed without exposing its response to clients."""


class OpenAICompatibleChatCompleter:
    """Small OpenAI-compatible, non-streaming adapter for local integration tests.

    Baton still streams its own message events. Keeping the upstream request
    non-streaming makes this fixture deliberately small and keeps cancellation
    semantics owned by the Baton run rather than an external provider's SSE.
    """

    def __init__(self, endpoint, model, api_key, reasoning_effort=None):
        self.endpoint, self.model, self.api_key = endpoint, model, api_key
        self.reasoning_effort = reasoning_effort

    def complete(self, messages):
        provider_messages = [{
            "role": "system",
            "content": "You are Baton’s helpful Chinese-speaking assistant. Reply directly and concisely.",
        }]
        # This fixture deliberately sends only the latest user turn. The
        # configured LM Studio model's prompt template rejects assistant turns;
        # conversation history belongs to the real Companion/Java server, not
        # this small local test adapter.
        latest_user = next((message for message in reversed(messages) if message["role"] == "user"), None)
        if latest_user:
            content = "".join(part.get("text", "") for part in latest_user["content"] if part.get("type") == "text")
            if content:
                provider_messages.append({"role": "user", "content": content})
        if len(provider_messages) == 1:
            raise ChatCompletionError("no user message to complete")
        payload = {"model": self.model, "messages": provider_messages, "temperature": 0.4}
        if self.reasoning_effort:
            payload["reasoning_effort"] = self.reasoning_effort
        payload = json.dumps(payload).encode()
        request = urlrequest.Request(self.endpoint, data=payload, method="POST", headers={
            "Authorization": "Bearer " + self.api_key,
            "Content-Type": "application/json",
        })
        try:
            with urlrequest.urlopen(request, timeout=90) as response:
                body = json.load(response)
            content = body["choices"][0]["message"]["content"]
        except (urlerror.URLError, urlerror.HTTPError, KeyError, IndexError, TypeError, ValueError) as exc:
            raise ChatCompletionError("upstream chat completion failed") from exc
        if not isinstance(content, str) or not content.strip():
            raise ChatCompletionError("upstream chat completion was empty")
        return content.strip()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        # urllib and URLSession may close a one-shot SSE socket immediately
        # after the terminal envelope. That is a normal client disconnect, not
        # a fixture failure worth printing as a server traceback.
        try:
            super().handle()
        except ConnectionResetError:
            pass

    def log_message(self, fmt, *args):
        # BaseHTTPRequestHandler includes the whole request path in its
        # default logs. Pairing paths contain short-lived capability IDs, so
        # report only a stable route category instead.
        path = urlparse(self.path).path.rstrip("/")
        if path == "": route = "console"
        elif path == "/v1/baton/mock/web/conversation": route = "fixture.web.snapshot"
        elif path == "/v1/baton/mock/web/events": route = "fixture.web.events"
        elif path == "/v1/baton/mock/web/messages": route = "fixture.web.messages"
        elif path.startswith("/.well-known/baton/pair/"): route = "pairing.discovery"
        elif path == "/v1/baton/pairings": route = "pairing.create"
        elif path.endswith("/requests"): route = "pairing.request"
        elif "/pairings/" in path and "/requests/" in path: route = "pairing.claim"
        elif "/pairings/" in path and path.endswith("/approval"): route = "pairing.approval"
        elif "/pairings/" in path and path.endswith("/mock-status"): route = "pairing.status"
        elif path == DEMO_IMAGE_PATH: route = "conversation.media"
        elif path.endswith("/events"): route = "conversation.events"
        elif path.endswith("/messages"): route = "conversation.messages"
        elif "/runs/" in path: route = "conversation.cancel"
        elif "/conversations/" in path: route = "conversation.snapshot"
        elif path.startswith("/v1/baton/devices/"): route = "device.session"
        elif path.startswith("/v1/baton/mock/"): route = "fixture.control"
        else: route = "other"
        status = args[1] if len(args) > 1 else None
        fixture_log("http.request", method=self.command, route=route, status=status)

    def raw_body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def send_json(self, value, status=200):
        payload = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "private, no-store")
        self.end_headers()
        self.wfile.write(payload)

    def send_html(self, value, status=200, headers=None):
        payload = value.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def send_media(self, value, mime_type):
        self.send_response(200)
        self.send_header("Content-Type", mime_type)
        self.send_header("Content-Length", str(len(value)))
        # Baton uses a bounded, active-session-only decoded-image cache. It
        # never delegates media to URLSession or disk caches, regardless of
        # this transport directive.
        self.send_header("Cache-Control", "private, no-store")
        self.end_headers()
        self.wfile.write(value)

    def error(self, status, code, message):
        self.send_json({"error": {"code": code, "message": message}}, status)

    def active_pairing(self, pairing_id):
        pairing, code = STORE.active_pairing(pairing_id)
        if not code: return pairing
        self.error(404 if code == "pairing_not_found" else 410, code, "Pairing is unknown or no longer active.")
        return None

    def auth(self):
        value = self.headers.get("Authorization", "")
        with STORE.lock:
            credential = STORE.tokens.get(value[7:] if value.startswith("Bearer ") else "")
            if not credential or STORE.conversation_closed:
                return None
            return credential if credential["conversation_id"] == STORE.conversation_id else None

    def create_pairing(self, body):
        # Fixture-only test hook. It is explicitly not a Companion Profile field.
        # The profile's invitation lifetime is intentionally short.  The
        # sub-second hook is solely for deterministic expiry testing, never a
        # way for this fixture UI to relax the protocol's security boundary.
        ttl = body.get("mock_ttl_seconds", 60)
        if not isinstance(ttl, (int, float)) or isinstance(ttl, bool) or not 0 <= ttl <= 60:
            return self.error(400, "invalid_mock_ttl", "mock_ttl_seconds must be between 0 and 60.")
        approval_mode = body.get("approval_mode", "manual")
        if approval_mode not in ("manual", "auto"):
            return self.error(400, "invalid_approval_mode", "approval_mode must be manual or auto.")
        with STORE.lock:
            if STORE.conversation_closed: STORE.reset_conversation()
        pairing_id, expires_at = "ps_" + secrets.token_urlsafe(32), time.time() + ttl
        with STORE.lock:
            STORE.pairings[pairing_id] = {"expires_at": expires_at, "status": "created", "request": None,
                                          "conversation_id": STORE.conversation_id, "approval_mode": approval_mode}
        return self.send_json({"pairing_id": pairing_id,
            "qr_url": f"{STORE.base_url}/.well-known/baton/pair/{pairing_id}",
            "approval_url": f"{STORE.base_url}/v1/baton/pairings/{pairing_id}/approval",
            "approval_mode": approval_mode,
            "expires_at": datetime.fromtimestamp(expires_at, timezone.utc).isoformat().replace("+00:00", "Z")})

    def join_pairing(self, pairing_id, body):
        with STORE.lock:
            pairing = self.active_pairing(pairing_id)
            if not pairing: return
            if pairing["status"] != "created":
                return self.error(409, "pairing_not_available", "This pairing already has a device request.")
            device_id, device_name = body.get("device_id"), body.get("device_name") or "Baton device"
            device_proof = body.get("device_proof")
            if (not isinstance(device_id, str) or not device_id.strip() or not isinstance(device_name, str)
                    or not isinstance(device_proof, str) or len(device_proof) < 32):
                return self.error(400, "invalid_device", "device_id, device_name, and a high-entropy device_proof are required.")
            request_id = "pr_" + secrets.token_urlsafe(18)
            pairing["request"] = {"id": request_id, "device_id": device_id,
                                  "device_name": device_name[:120], "device_proof": device_proof,
                                  "access_token": None}
            pairing["status"] = "approved" if pairing["approval_mode"] == "auto" else "pending"
        return self.send_json({"pairing_id": pairing_id, "request_id": request_id, "status": pairing["status"],
            "poll_url": f"{STORE.base_url}/v1/baton/pairings/{pairing_id}/requests/{request_id}",
            "retry_after_seconds": 2}, 202)

    def decide_pairing(self, pairing_id, decision, redirect=False):
        with STORE.lock:
            pairing = self.active_pairing(pairing_id)
            if not pairing: return
            if pairing["status"] != "pending":
                return self.error(409, "pairing_not_pending", "Only a pending device request can be decided.")
            if decision not in {"approved", "rejected"}:
                return self.error(400, "invalid_decision", "decision must be approved or rejected.")
            pairing["status"] = decision
            if decision == "approved":
                token, session_id = STORE.new_token(pairing["request"]["device_id"], pairing["conversation_id"])
                pairing["request"]["access_token"] = token
                pairing["request"]["session_id"] = session_id
        if redirect:
            return self.send_html("", 303, {"Location": f"/v1/baton/pairings/{pairing_id}/approval"})
        return self.send_json({"pairing_id": pairing_id, "status": decision})

    def poll_pairing(self, pairing_id, request_id):
        with STORE.lock:
            pairing = self.active_pairing(pairing_id)
            if not pairing: return
            request = pairing.get("request")
            if not request or not secrets.compare_digest(request["id"], request_id):
                return self.error(404, "request_not_found", "Pairing request not found.")
            proof = self.headers.get("X-Baton-Device-Proof", "")
            if not secrets.compare_digest(request["device_proof"], proof):
                return self.error(403, "invalid_device_proof", "This device cannot read or claim the pairing request.")
            if pairing["status"] == "pending":
                return self.send_json({"pairing_id": pairing_id, "request_id": request_id,
                                       "status": "pending", "retry_after_seconds": 2})
            if pairing["status"] == "rejected":
                return self.send_json({"pairing_id": pairing_id, "request_id": request_id, "status": "rejected"})
            if pairing["status"] not in {"approved", "consumed"}:
                return self.error(409, "pairing_not_available", "Pairing is not available.")
            # Mark the invitation consumed on first successful claim, but return the
            # exact same token for retried claims made by the proving device until expiry.
            if pairing["status"] == "approved" and request["access_token"] is None:
                token, session_id = STORE.new_token(request["device_id"], pairing["conversation_id"])
                request["access_token"] = token
                request["session_id"] = session_id
            pairing["status"] = "consumed"
            token = request["access_token"]
        return self.send_json({"pairing_id": pairing_id, "request_id": request_id, "status": "approved", "pairing_status": "consumed",
            "access_token": token, "token_type": "Bearer", "expires_in": 86400,
            "device_id": request["device_id"],
            "session_id": request["session_id"],
            "conversation": {"id": pairing["conversation_id"], "title": "Local test conversation"}})

    def approval_page(self, pairing_id):
        with STORE.lock:
            pairing = self.active_pairing(pairing_id)
            if not pairing: return
            if pairing["status"] == "pending":
                device = html.escape(pairing["request"]["device_name"])
                page = f'''<!doctype html><meta charset="utf-8"><title>Baton device request</title>
<h1>Allow {device} to join this conversation?</h1>
<form method="post" action="/v1/baton/pairings/{pairing_id}/approval"><button name="decision" value="approved">Allow</button><button name="decision" value="rejected">Deny</button></form>'''
            elif pairing["status"] == "created":
                page = '<!doctype html><meta charset="utf-8"><title>Baton pairing</title><p>Waiting for a device to scan this pairing.</p>'
            else:
                page = f'<!doctype html><meta charset="utf-8"><title>Baton pairing</title><p>Pairing status: {html.escape(pairing["status"])}.</p>'
        return self.send_html(page)

    def qr_page(self, pairing_id):
        with STORE.lock:
            pairing = self.active_pairing(pairing_id)
            if not pairing: return
        discovery_url = f"{STORE.base_url}/.well-known/baton/pair/{pairing_id}"
        page = f'''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Baton pairing QR</title><style>body{{font:16px -apple-system,sans-serif;text-align:center;margin:40px;color:#1d1d1f}}img{{width:min(82vw,360px);image-rendering:pixelated}}code{{overflow-wrap:anywhere;color:#666}}</style>
<h1>Scan with Baton</h1><img src="/v1/baton/pairings/{pairing_id}/qr.png" alt="Baton pairing QR code"><p>This pairing expires soon.</p><code>{html.escape(discovery_url)}</code>'''
        return self.send_html(page)

    def qr_png(self, pairing_id):
        with STORE.lock:
            pairing = self.active_pairing(pairing_id)
            if not pairing: return
        try:
            import qrcode
        except ImportError:
            return self.error(501, "qr_dependency_missing", "Install mock_server/requirements-qr.txt to enable the fixture QR page.")
        image = qrcode.make(f"{STORE.base_url}/.well-known/baton/pair/{pairing_id}")
        output = BytesIO()
        image.save(output, format="PNG")
        return self.send_png(output.getvalue())

    def review_demo_page(self):
        """Stable, opt-in page which creates a fresh short-lived review QR."""
        page = '''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Baton App Review Demo</title><style>
*{box-sizing:border-box}body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:0;min-height:100vh;display:grid;place-items:center}.card{max-width:540px;margin:24px;padding:32px;text-align:center;background:#fff;border-radius:24px;box-shadow:0 8px 30px #00000012}.eyebrow{color:#0071e3;font-weight:700;font-size:12px;letter-spacing:.08em;text-transform:uppercase}.title{font-size:28px;margin:10px 0}.copy{color:#6e6e73;line-height:1.5}.qr{width:min(76vw,320px);margin:18px auto;display:block;image-rendering:pixelated}.status{font-weight:600;min-height:24px}.hint{color:#6e6e73;font-size:14px;line-height:1.45}.new{border:0;border-radius:10px;background:#0071e3;color:white;font:inherit;font-weight:600;padding:11px 16px;cursor:pointer}</style>
<main class="card"><div class="eyebrow">Baton · App Review Demo</div><h1 class="title">Scan to join the demo</h1><p class="copy">Open this page on a separate screen, then scan the QR code with Baton. The demo uses isolated data and creates a fresh, short-lived invitation automatically.</p><img class="qr" id="qr" alt="Short-lived Baton review pairing QR code"><p class="status" id="status">Creating a secure review QR…</p><p class="hint" id="hint"></p><button class="new" id="new">Generate a fresh QR</button><p class="hint"><a href="https://ximatai.net/apps/baton">Learn more about Baton</a></p></main>
<script>
let expiresAt=0, timer=null; const $=id=>document.getElementById(id); const pairingEndpoint=location.pathname==='/'?'/pairing':location.pathname+'/pairing';
function show(text,hint=''){$('status').textContent=text;$('hint').textContent=hint;}
async function create(){clearInterval(timer);show('Creating a secure review QR…');const response=await fetch(pairingEndpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});if(!response.ok){show('Could not create the review QR.','Please reload this page.');return}const pairing=await response.json();$('qr').src='/v1/baton/pairings/'+pairing.pairing_id+'/qr.png';expiresAt=Date.parse(pairing.expires_at);tick();timer=setInterval(tick,1000);}
function tick(){const seconds=Math.max(0,Math.ceil((expiresAt-Date.now())/1000));if(!seconds){clearInterval(timer);create();return}show('Ready to scan.','This QR expires in '+seconds+' seconds and is valid for one device.');}
$('new').onclick=create; create();
</script>'''
        return self.send_html(page)

    def console_page(self):
        """Human-facing fixture console; never a Companion Profile endpoint."""
        page = '''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Baton local test console</title><style>
*{box-sizing:border-box}body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f;margin:0}main{max-width:1120px;margin:0 auto;padding:44px 24px}h1{margin:0 0 6px}.sub{color:#6e6e73;margin:0}.layout{display:grid;grid-template-columns:minmax(280px,.82fr) minmax(360px,1.35fr);gap:20px;margin-top:24px}.card{background:white;border-radius:20px;padding:24px;box-shadow:0 2px 12px #00000010}.pair{text-align:center}.eyebrow{font-size:12px;font-weight:700;letter-spacing:.08em;color:#0071e3;text-transform:uppercase}.title{font-size:20px;font-weight:700;margin:8px 0}.status{font-weight:600}.hint{font-size:14px;color:#6e6e73;line-height:1.45}.primary,.secondary{border:0;border-radius:10px;padding:12px 18px;font-size:16px;font-weight:600;cursor:pointer}.primary{background:#0071e3;color:white}.primary:disabled{background:#aab4c0;cursor:default}.secondary{background:#f0f0f3;color:#3a3a3c;font-size:14px;padding:8px 12px}#qr{width:min(75vw,280px);margin:18px auto;display:none}.chat{display:flex;flex-direction:column;height:min(640px,calc(100vh - 210px));min-height:480px;padding:0;overflow:hidden}.chat-head{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:22px 24px 15px;border-bottom:1px solid #e8e8ed}.messages{min-height:0;flex:1;overflow-y:scroll;scrollbar-gutter:stable;padding:20px;display:flex;flex-direction:column;gap:12px;background:#fbfbfc}.message{max-width:82%;padding:11px 13px;border-radius:16px;line-height:1.45;white-space:pre-wrap;word-break:break-word}.message.user{align-self:flex-end;background:#0071e3;color:#fff;border-bottom-right-radius:5px}.message.assistant{align-self:flex-start;background:#fff;box-shadow:0 1px 5px #00000010;border-bottom-left-radius:5px}.message.empty{align-self:center;color:#6e6e73;background:transparent;box-shadow:none;text-align:center;margin:auto}.composer{display:flex;gap:10px;padding:14px;border-top:1px solid #e8e8ed}.composer input{min-width:0;flex:1;border:1px solid #d7d7dc;border-radius:12px;padding:11px 12px;font:inherit}.composer button{padding:10px 15px}.chat-status{font-size:13px;color:#6e6e73;padding:0 20px 10px}@media(max-width:760px){main{padding:28px 16px}.layout{grid-template-columns:1fr}.chat{height:min(560px,calc(100vh - 56px));min-height:440px}}</style>
<main><h1>Baton 本地联调</h1><div class="layout"><section class="card pair"><div class="eyebrow">Baton Connect</div><h2 class="title">将当前会话交接到手机</h2><button class="primary" id="new">生成新的配对二维码</button><img id="qr" alt="Baton pairing QR"><p id="status" class="status">点击按钮开始。</p><p id="hint" class="hint">手机扫码后，此页面会显示“允许加入”。</p><button class="primary" id="allow" hidden>允许此设备加入</button></section><section class="card chat"><div class="chat-head"><div><div class="eyebrow">Shared Conversation</div><div class="title">Local test conversation</div></div><button class="secondary" id="end">结束</button></div><div id="messages" class="messages"><div class="message empty">正在连接共享会话…</div></div><div id="chat-status" class="chat-status">正在订阅会话事件…</div><form id="composer" class="composer"><input id="text" autocomplete="off" placeholder="在 Web 端继续这段对话"><button class="primary">发送</button></form></section></div></main>
<script>
let pairing=null, timer=null, stream=null, conversationEnded=false;
const $=id=>document.getElementById(id), set=(text,hint)=>{$('status').textContent=text;$('hint').textContent=hint||''};
async function create(){
  if($('end').disabled){location.reload();return}
  $('new').disabled=true; $('allow').hidden=true; set('正在生成二维码…');
  const r=await fetch('/v1/baton/pairings',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
  if(!r.ok){set('生成失败，请重试。');$('new').disabled=false;return}
  pairing=await r.json(); $('qr').src='/v1/baton/pairings/'+pairing.pairing_id+'/qr.png'; $('qr').style.display='block';
  set('请使用 Baton App 扫描二维码。','二维码有效期 60 秒。扫描完成后可直接在此页允许。'); $('new').disabled=false;
  clearInterval(timer); timer=setInterval(refresh,1000); refresh();
}
async function refresh(){
  if(!pairing)return;
  const r=await fetch('/v1/baton/pairings/'+pairing.pairing_id+'/mock-status');
  if(!r.ok){clearInterval(timer);$('allow').hidden=true;set('二维码已过期，正在生成新的二维码。');setTimeout(create,300);return}
  const state=await r.json();
  if(state.status==='created')return;
  if(state.status==='pending'){set('手机已扫描：'+state.device_name,'确认后点击“允许此设备加入”。');$('allow').hidden=false;return}
  if(state.status==='approved'){set('已允许，正在等待 App 建立会话…');$('allow').hidden=true;return}
  if(state.status==='consumed'){clearInterval(timer);set('设备已连接。','现在可以在 Baton App 发送消息。');$('allow').hidden=true;return}
  clearInterval(timer);$('allow').hidden=true;set('配对未完成：'+state.status,'请生成新的二维码。');
}
$('new').onclick=create;
$('allow').onclick=async()=>{ $('allow').disabled=true; const r=await fetch('/v1/baton/pairings/'+pairing.pairing_id+'/approval',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({decision:'approved'})}); if(!r.ok)set('授权失败，请重试。'); await refresh(); $('allow').disabled=false; };
const messages=new Map(), messageList=$('messages');
function put(message){if(!message||!message.id)return;messages.set(message.id,message);render();}
function update(id, change){const message=messages.get(id)||{id,role:'assistant',content:[{type:'text',text:''}],status:'streaming'};change(message);messages.set(id,message);render();}
function textOf(message){return (message.content||[]).map(part=>part.text||'').join('');}
function render(){messageList.replaceChildren();if(!messages.size){const empty=document.createElement('div');empty.className='message empty';empty.textContent='开始这段共享对话。';messageList.append(empty);return}for(const message of messages.values()){const item=document.createElement('div');item.className='message '+(message.role==='user'?'user':'assistant');item.textContent=textOf(message)||(message.status==='streaming'?'正在思考…':'');messageList.append(item)}messageList.scrollTop=messageList.scrollHeight;}
async function loadConversation(){const response=await fetch('/v1/baton/mock/web/conversation');if(!response.ok)throw new Error('snapshot');const snapshot=await response.json();for(const message of snapshot.messages.slice().reverse())put(message);$('chat-status').textContent='已连接 · Local Baton Mock';}
function closeWebConversation(){if(conversationEnded)return;conversationEnded=true;if(stream)stream.close();messages.clear();render();$('chat-status').textContent='对话已结束。生成新二维码可开始新会话。';$('text').disabled=true;$('end').disabled=true;}
function subscribe(){stream=new EventSource('/v1/baton/mock/web/events');stream.onopen=()=>{if(!conversationEnded)$('chat-status').textContent='已连接 · 实时同步中';};stream.onerror=()=>{if(!conversationEnded)$('chat-status').textContent='连接中断，正在重试…';};stream.addEventListener('message.created',event=>put(JSON.parse(event.data).data));stream.addEventListener('message.delta',event=>{const data=JSON.parse(event.data).data;update(data.message_id,message=>{message.content=message.content||[{type:'text',text:''}];message.content[0].text=(message.content[0].text||'')+data.delta;message.status='streaming';});});stream.addEventListener('message.completed',event=>{const data=JSON.parse(event.data).data;update(data.message_id,message=>{message.status=data.status||'completed';});});stream.addEventListener('message.content.appended',event=>{const data=JSON.parse(event.data).data;update(data.message_id,message=>{message.content=(message.content||[]).concat(data.content||[]);});});stream.addEventListener('message.failed',event=>{const data=JSON.parse(event.data).data;update(data.message_id,message=>{message.status='failed';message.content=[{type:'text',text:data.message||'回复失败，请重试。'}];});});stream.addEventListener('conversation.closed',closeWebConversation);}
function webMessageID(){if(globalThis.crypto&&typeof globalThis.crypto.randomUUID==='function')return globalThis.crypto.randomUUID();return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{const r=Math.floor(Math.random()*16),v=c==='x'?r:(r&3)|8;return v.toString(16)});}
$('composer').onsubmit=async event=>{event.preventDefault();const input=$('text'),text=input.value.trim();if(!text)return;input.disabled=true;try{const response=await fetch('/v1/baton/mock/web/messages',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_message_id:webMessageID(),content:[{type:'text',text}]})});if(!response.ok)throw new Error('send');input.value='';}catch{$('chat-status').textContent='发送失败，请重试。';}finally{input.disabled=false;input.focus();}};
$('end').onclick=async()=>{if(!confirm('结束当前对话？手机端也将自动退出。'))return;const response=await fetch('/v1/baton/mock/web/conversation:end',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});if(response.ok)closeWebConversation();else $('chat-status').textContent='结束失败，请重试。';};
subscribe();loadConversation().catch(()=>{$('chat-status').textContent='无法加载会话。';});
create();
</script>'''
        return self.send_html(page)

    def mock_pairing_status(self, pairing_id):
        with STORE.lock:
            pairing = self.active_pairing(pairing_id)
            if not pairing: return
            request = pairing.get("request") or {}
            return self.send_json({"pairing_id": pairing_id, "status": pairing["status"],
                                   "device_name": request.get("device_name")})

    def submit_message(self, body):
        """Shared message path for the mobile API and fixture-only Web client."""
        client_id = body.get("client_message_id")
        text = ((body.get("content") or [{}])[0].get("text") if isinstance(body.get("content"), list) else body.get("text"))
        try:
            valid_client_id = isinstance(client_id, str) and str(uuid.UUID(client_id)) == client_id.lower()
        except (ValueError, AttributeError):
            valid_client_id = False
        if not valid_client_id or not isinstance(text, str) or not text.strip():
            return self.error(400, "invalid_message", "client_message_id and text content are required.")
        with STORE.condition:
            if STORE.conversation_closed:
                return self.error(410, "conversation_closed", "Conversation has ended.")
            for message in STORE.messages:
                if message.get("client_message_id") == client_id: return self.send_json(message)
            message = STORE.add_message("msg_" + uuid.uuid4().hex[:16], client_id, "user", text)
            STORE.event("message.created", message)
            run_id = "run_" + uuid.uuid4().hex[:12]
            assistant = STORE.add_message("msg_" + uuid.uuid4().hex[:16], None, "assistant", "", status="streaming")
            STORE.runs[run_id] = {"status": "active", "message_id": assistant["id"],
                                  "epoch": STORE.conversation_epoch}
            epoch = STORE.conversation_epoch
            STORE.event("run.started", {"run_id": run_id})
            STORE.event("message.created", assistant)
        fixture_log("agent.input.accepted", characters=len(text))
        threading.Thread(target=self.stream_reply, args=(run_id, text, epoch), daemon=True).start()
        return self.send_json(message, 201)

    def conversation_snapshot(self):
        with STORE.lock:
            if STORE.conversation_closed: return self.error(410, "conversation_closed", "Conversation has ended.")
            active_runs = [
                {"run_id": run_id, "status": run["status"], "message_id": run["message_id"]}
                for run_id, run in STORE.runs.items()
                if run["status"] == "active" and run["epoch"] == STORE.conversation_epoch
            ]
            return self.send_json({"id": STORE.conversation_id, "title": "Local test conversation", "agent_name": "Mock Agent",
                                   "messages": list(reversed(STORE.messages)),
                                   "event_cursor": STORE.event_cursor(), "active_runs": active_runs})

    def do_POST(self):
        path, raw = urlparse(self.path).path.rstrip("/"), self.raw_body()
        if REVIEW_DEMO_TOKEN and path == f"/review/{REVIEW_DEMO_TOKEN}/pairing":
            # This route is separate from normal pairing, which stays manual by default.
            return self.create_pairing({"approval_mode": "auto", "mock_ttl_seconds": REVIEW_DEMO_TTL_SECONDS})
        if path.startswith("/review/"):
            return self.error(404, "not_found", "Not found.")
        prefix = "/v1/baton/pairings/"
        if path == "/v1/baton/pairings":
            try: return self.create_pairing(json.loads(raw or b"{}"))
            except (ValueError, TypeError): return self.error(400, "invalid_json", "Invalid JSON.")
        if path.startswith(prefix) and path.endswith("/requests"):
            try: return self.join_pairing(path[len(prefix):-len("/requests")].strip("/"), json.loads(raw or b"{}"))
            except (ValueError, TypeError): return self.error(400, "invalid_json", "Invalid JSON.")
        if path.startswith(prefix) and path.endswith("/approval"):
            pairing_id = path[len(prefix):-len("/approval")].strip("/")
            if self.headers.get("Content-Type", "").startswith("application/x-www-form-urlencoded"):
                decision = parse_qs(raw.decode(), keep_blank_values=True).get("decision", [None])[0]
                return self.decide_pairing(pairing_id, decision, redirect=True)
            try: return self.decide_pairing(pairing_id, json.loads(raw or b"{}").get("decision"))
            except (ValueError, TypeError): return self.error(400, "invalid_json", "Invalid JSON.")
        try: body = json.loads(raw or b"{}")
        except (ValueError, TypeError): return self.error(400, "invalid_json", "Invalid JSON.")
        if path == "/v1/baton/mock/web/messages":
            # A local fixture convenience for the browser demo. Real Web
            # clients use their existing authenticated Java session instead.
            return self.submit_message(body)
        if path == "/v1/baton/mock/web/conversation:end":
            with STORE.lock: ended = STORE.close_conversation()
            return self.send_json({"status": "ended" if ended else "already_ended"})
        conversation_path = f"/v1/baton/conversations/{STORE.conversation_id}"
        if path == conversation_path + ":end":
            if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
            with STORE.lock: ended = STORE.close_conversation()
            return self.send_json({"status": "ended" if ended else "already_ended"})
        if path == conversation_path + "/messages":
            if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
            return self.submit_message(body)
        if path.startswith(conversation_path + "/runs/") and path.endswith(":cancel"):
            if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
            run_id = path[len(conversation_path + "/runs/"):-len(":cancel")]
            if not run_id: return self.error(404, "run_not_found", "Run not found.")
            status, emitted = STORE.cancel_run(run_id)
            if status is None: return self.error(404, "run_not_found", "Run not found.")
            if emitted: fixture_log("agent.reply.cancelled")
            return self.send_json({"run_id": run_id, "status": status}, 202 if emitted else 200)
        if path == "/v1/baton/mock/events:retention":
            # This authenticated endpoint exists only to make a finite-log
            # resync test deterministic.  It is intentionally undocumented as
            # a Companion Profile endpoint.
            if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
            retain_last = body.get("retain_last")
            if not isinstance(retain_last, int) or isinstance(retain_last, bool) or retain_last < 1:
                return self.error(400, "invalid_mock_retention", "retain_last must be a positive integer.")
            with STORE.lock: STORE.set_event_retention_for_test(retain_last)
            return self.send_json({"retain_last": retain_last, "retained_events": len(STORE.events)})
        if path == "/v1/baton/mock/chat:fail-next":
            # Authenticated, one-shot smoke hook. It verifies the Baton error
            # terminal order without depending on an external LLM outage.
            if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
            with STORE.lock: STORE.fail_next_completion_for_test = True
            return self.send_json({"status": "armed"})
        if path == "/v1/baton/mock/chat:slow-next":
            # Authenticated test hook for a provider that cannot be cancelled
            # mid-request. It proves Baton terminal state wins immediately.
            if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
            seconds = body.get("seconds", 1)
            if not isinstance(seconds, (int, float)) or isinstance(seconds, bool) or not 0 < seconds <= 3:
                return self.error(400, "invalid_mock_delay", "seconds must be between 0 and 3.")
            with STORE.lock: STORE.slow_next_completion_seconds = seconds
            return self.send_json({"status": "armed"})
        return self.error(404, "not_found", "Not found.")

    def stream_reply(self, run_id, text, epoch):
        """Stream only while this run still belongs to the live conversation.

        Provider calls cannot always be interrupted.  The Store terminal state is
        therefore authoritative: a late result after cancel/end is silently
        discarded instead of becoming an event in a later fixture conversation.
        """
        with STORE.lock:
            if not STORE.is_current_run(run_id, epoch): return
            run = STORE.runs[run_id]
            message_id = run["message_id"]
            history = list(STORE.messages)
            fail_for_smoke = STORE.fail_next_completion_for_test
            STORE.fail_next_completion_for_test = False
            slow_seconds = STORE.slow_next_completion_seconds
            STORE.slow_next_completion_seconds = 0
        try:
            fixture_log("agent.reply.requested")
            if slow_seconds:
                time.sleep(slow_seconds)
            if fail_for_smoke:
                # Deliberately ordinary, non-provider failure. The same safe
                # terminal sequence must handle any upstream implementation bug.
                raise RuntimeError("fixture completion failure")
            reply = CHAT_COMPLETER.complete(history) if CHAT_COMPLETER else "Mock 回复：" + text
            if not isinstance(reply, str) or not reply:
                raise RuntimeError("fixture completion was invalid")
            fixture_log("agent.reply.ready", characters=len(reply))
        except Exception:
            with STORE.lock:
                if not STORE.is_current_run(run_id, epoch): return
                run = STORE.runs[run_id]
                run["status"] = "failed"
                message = next(item for item in STORE.messages if item["id"] == message_id)
                message["status"] = "failed"
                STORE.event("message.failed", {"message_id": message_id, "message": "LLM 暂时不可用，请重试。"})
                STORE.event("run.completed", {"run_id": run_id, "status": "failed"})
            fixture_log("agent.reply.failed")
            return
        for chunk in [reply[i:i + 4] for i in range(0, len(reply), 4)]:
            time.sleep(.04)
            with STORE.lock:
                if not STORE.is_current_run(run_id, epoch): return
                message = next(item for item in STORE.messages if item["id"] == message_id)
                message["content"][0]["text"] += chunk
                STORE.event("message.delta", {"message_id": message_id, "delta": chunk})
        with STORE.lock:
            if not STORE.is_current_run(run_id, epoch): return
            run = STORE.runs[run_id]
            run["status"] = "completed"
            message = next(item for item in STORE.messages if item["id"] == message_id)
            message["status"] = "completed"
            STORE.event("message.completed", {"message_id": message_id, "status": "completed"})
            appended = [{"type": "image", "media_id": DEMO_IMAGE_ID,
                         "url": STORE.base_url + DEMO_IMAGE_PATH, "mime_type": "image/png",
                         "width": 320, "height": 200, "alt": DEMO_IMAGE_ALT}]
            message["content"].extend(copy.deepcopy(appended))
            STORE.event("message.content.appended", {"message_id": message_id, "content": appended})
            STORE.event("run.completed", {"run_id": run_id, "status": "completed"})
        fixture_log("agent.reply.completed")

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        discovery_prefix, pairing_prefix = "/.well-known/baton/pair/", "/v1/baton/pairings/"
        if path == "": return self.console_page()
        if REVIEW_DEMO_TOKEN and path == f"/review/{REVIEW_DEMO_TOKEN}":
            return self.review_demo_page()
        if path.startswith("/review/"):
            return self.error(404, "not_found", "Not found.")
        if path.startswith(discovery_prefix):
            pairing_id = path[len(discovery_prefix):]
            with STORE.lock:
                pairing = self.active_pairing(pairing_id)
                if not pairing: return
            return self.send_json({"protocol": "baton/1.1", "pairing_id": pairing_id,
                "expires_at": datetime.fromtimestamp(pairing["expires_at"], timezone.utc).isoformat().replace("+00:00", "Z"),
                "service": {"id": "local-mock", "name": "Local Baton Mock"},
                "conversation": {"id": pairing["conversation_id"], "title": "Local test conversation", "agent_name": "Mock Agent"},
                "approval_mode": pairing["approval_mode"],
                "endpoints": {"join": f"{STORE.base_url}/v1/baton/pairings/{pairing_id}/requests",
                              "approval": f"{STORE.base_url}/v1/baton/pairings/{pairing_id}/approval",
                              "conversation": f"{STORE.base_url}/v1/baton/conversations/{STORE.conversation_id}"},
                "capabilities": {"text": True, "markdown": True, "streaming": True, "image": True, "content_append": True}})
        if path.startswith(pairing_prefix) and path.endswith("/approval"):
            return self.approval_page(path[len(pairing_prefix):-len("/approval")].strip("/"))
        if path.startswith(pairing_prefix) and path.endswith("/qr"):
            return self.qr_page(path[len(pairing_prefix):-len("/qr")].strip("/"))
        if path.startswith(pairing_prefix) and path.endswith("/qr.png"):
            return self.qr_png(path[len(pairing_prefix):-len("/qr.png")].strip("/"))
        if path.startswith(pairing_prefix) and path.endswith("/mock-status"):
            return self.mock_pairing_status(path[len(pairing_prefix):-len("/mock-status")].strip("/"))
        if path.startswith(pairing_prefix) and "/requests/" in path:
            pairing_id, request_id = path[len(pairing_prefix):].split("/requests/", 1)
            return self.poll_pairing(pairing_id, request_id)
        if path == "/v1/baton/mock/web/conversation": return self.conversation_snapshot()
        if path == "/v1/baton/mock/web/events": return self.sse()
        if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
        if path == DEMO_IMAGE_PATH: return self.send_media(DEMO_IMAGE_BYTES, "image/png")
        conversation_path = f"/v1/baton/conversations/{STORE.conversation_id}"
        if path == conversation_path: return self.conversation_snapshot()
        if path == conversation_path + "/events": return self.sse()
        return self.error(404, "not_found", "Not found.")

    def sse(self):
        # The fixture deliberately closes each finite SSE response after its
        # heartbeat window.  Prevent BaseHTTPRequestHandler from attempting to
        # parse another request on a client socket that has already gone away.
        self.close_connection = True
        requested_id = self.headers.get("Last-Event-ID", "")
        with STORE.lock:
            cursor = next((e for e in STORE.events if e["id"] == requested_id), None)
            # A fresh subscriber is a live tail, never an implicit replay.  A
            # snapshot client supplies its atomic event_cursor as Last-Event-ID.
            last = cursor["sequence"] if cursor else STORE.events[-1]["sequence"]
            resync = bool(requested_id) and cursor is None
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        # HTTP/1.1 SSE is an open-ended response. Chunk framing lets URLSession
        # deliver each flushed envelope immediately instead of waiting for the
        # fixture's eventual connection close.
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        if resync:
            # This is a standard Baton envelope, but deliberately not appended
            # to the event log: a bad cursor from one client must not become an
            # observable conversation event for every other client.  Reusing
            # the latest retained id gives legacy clients a safe reconnection
            # cursor while the required snapshot refresh obtains the same point.
            with STORE.lock:
                latest = STORE.events[-1]
                control = {"id": latest["id"], "sequence": latest["sequence"],
                           "type": "conversation.resync", "occurred_at": now(),
                           "data": {"reason": "cursor_unknown_or_expired"}}
            if not self.write_sse(control): return
        deadline = time.time() + SSE_LIVE_SECONDS
        while time.time() < deadline:
            with STORE.condition:
                pending = [e for e in STORE.events if e["sequence"] > last]
                if not pending:
                    STORE.condition.wait(timeout=2)
                    pending = [e for e in STORE.events if e["sequence"] > last]
            if not pending:
                try:
                    self.write_chunk(b": heartbeat\n\n")
                except (BrokenPipeError, ConnectionResetError):
                    return
                continue
            for event in pending:
                if not self.write_sse(event): return
                last = event["sequence"]
        self.write_chunk(b"", final=True)

    def write_sse(self, event):
        raw = ("id: %s\nevent: %s\ndata: %s\n\n" % (event["id"], event["type"], json.dumps(event, ensure_ascii=False))).encode()
        return self.write_chunk(raw)

    def write_chunk(self, payload, *, final=False):
        frame = b"0\r\n\r\n" if final else f"{len(payload):X}\r\n".encode() + payload + b"\r\n"
        try:
            self.wfile.write(frame); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return False
        return True

    def do_DELETE(self):
        if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
        path = urlparse(self.path).path.rstrip("/")
        prefix = "/v1/baton/devices/"
        if path.startswith(prefix) and "/sessions/" in path:
            device_id, session_id = path[len(prefix):].split("/sessions/", 1)
            token = self.headers["Authorization"][7:]
            with STORE.lock:
                credential = STORE.tokens.get(token)
                if not credential or credential["device_id"] != device_id or credential["session_id"] != session_id:
                    return self.error(404, "session_not_found", "Device session not found.")
                STORE.tokens.pop(token, None)
            return self.send_json({"status": "revoked"})
        return self.error(404, "not_found", "Not found.")


def main():
    global STORE, CHAT_COMPLETER, SSE_LIVE_SECONDS, REVIEW_DEMO_TOKEN
    parser = argparse.ArgumentParser(description="Local Baton Companion mock server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--public-base-url", help="advertised URL when binding a LAN interface (fixture only)")
    parser.add_argument("--event-retention", type=int, default=64, help="retained SSE event envelopes per conversation (fixture only)")
    parser.add_argument("--sse-live-seconds", type=int, default=300, help="maximum duration of one fixture SSE connection")
    parser.add_argument("--review-demo-token", help="enable token-protected /review/<token> auto-pairing demo (fixture only)")
    parser.add_argument("--openai-chat-completions-url", help="optional OpenAI-compatible chat completion endpoint")
    parser.add_argument("--openai-model", help="model for the optional OpenAI-compatible endpoint")
    parser.add_argument("--openai-reasoning-effort", choices=("none", "low", "medium", "high"), help="optional provider-specific reasoning setting")
    parser.add_argument("--api-key-env", default="LM_STUDIO_KEY", help="environment variable holding the optional provider key")
    args = parser.parse_args()
    if args.sse_live_seconds < 1:
        parser.error("--sse-live-seconds must be positive")
    if args.review_demo_token is not None and len(args.review_demo_token) < 16:
        parser.error("--review-demo-token must contain at least 16 characters")
    if bool(args.openai_chat_completions_url) != bool(args.openai_model):
        parser.error("--openai-chat-completions-url and --openai-model must be supplied together")
    if args.openai_chat_completions_url:
        import os
        api_key = os.environ.get(args.api_key_env)
        if not api_key:
            parser.error(f"environment variable {args.api_key_env} is required when an OpenAI-compatible backend is enabled")
        CHAT_COMPLETER = OpenAICompatibleChatCompleter(
            args.openai_chat_completions_url,
            args.openai_model,
            api_key,
            reasoning_effort=args.openai_reasoning_effort,
        )
    SSE_LIVE_SECONDS = args.sse_live_seconds
    REVIEW_DEMO_TOKEN = args.review_demo_token
    STORE = Store(args.public_base_url or f"http://{args.host}:{args.port}", event_retention=args.event_retention)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    provider = f" with OpenAI-compatible model {args.openai_model}" if CHAT_COMPLETER else " with deterministic replies"
    print(f"Baton mock server listening at {STORE.base_url}{provider}", flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()


if __name__ == "__main__": main()
