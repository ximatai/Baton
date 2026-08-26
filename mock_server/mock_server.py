#!/usr/bin/env python3
"""Tiny in-memory Baton Companion Profile fixture; never reads LM_STUDIO_KEY."""
from __future__ import annotations

import argparse
import html
import json
import secrets
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class Store:
    def __init__(self, base_url, *, event_retention=64):
        self.base_url, self.lock = base_url.rstrip("/"), threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.pairings, self.tokens, self.events = {}, {}, []
        self.runs, self.messages, self.next_sequence = {}, [], 1
        self.event_retention = max(1, event_retention)
        self.conversation_id = "conv_local"
        welcome = self.add_message("msg_welcome", None, "assistant", "这是本地 Baton Mock Server，可以直接开始对话。")
        # A conversation always has a cursor, including before the first user
        # message.  A fetched snapshot and this cursor are therefore atomic.
        self.event("conversation.snapshot", {"conversation_id": self.conversation_id, "messages": [welcome]})

    def add_message(self, message_id, client_id, role, text, status="completed"):
        message = {"id": message_id, "client_message_id": client_id,
                   "conversation_id": self.conversation_id, "role": role,
                   "content": [{"type": "text", "text": text}], "created_at": now(), "status": status}
        self.messages.append(message)
        return message

    def event(self, event_type, data):
        with self.condition:
            event = {"id": "evt_" + uuid.uuid4().hex[:16], "sequence": self.next_sequence,
                     "type": event_type, "occurred_at": now(), "data": data}
            self.next_sequence += 1
            self.events.append(event)
            del self.events[:-self.event_retention]
            self.condition.notify_all()
            return event

    def event_cursor(self):
        """Return the latest *retained* event as a resumable snapshot cursor."""
        latest = self.events[-1]
        return {"id": latest["id"], "sequence": latest["sequence"]}

    def set_event_retention_for_test(self, retain_last):
        """Fixture-only deterministic retention hook; never part of Baton/1.0."""
        self.event_retention = max(1, retain_last)
        del self.events[:-self.event_retention]

    def active_pairing(self, pairing_id):
        pairing = self.pairings.get(pairing_id)
        if not pairing:
            return None, "pairing_not_found"
        if time.time() >= pairing["expires_at"] and pairing["status"] != "rejected":
            pairing["status"] = "expired"
        return pairing, "pairing_expired" if pairing["status"] == "expired" else None

    def new_token(self, device_id):
        token = "baton_local_" + secrets.token_urlsafe(18)
        session_id = "ses_" + secrets.token_urlsafe(18)
        self.tokens[token] = {"device_id": device_id, "session_id": session_id,
                              "conversation_id": self.conversation_id}
        return token, session_id


STORE = None


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
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))

    def raw_body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def send_json(self, value, status=200):
        payload = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
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
            return STORE.tokens.get(value[7:] if value.startswith("Bearer ") else "")

    def create_pairing(self, body):
        # Fixture-only test hook. It is explicitly not a Companion Profile field.
        ttl = body.get("mock_ttl_seconds", 60)
        if not isinstance(ttl, (int, float)) or isinstance(ttl, bool) or not 0 <= ttl <= 60:
            return self.error(400, "invalid_mock_ttl", "mock_ttl_seconds must be between 0 and 60.")
        pairing_id, expires_at = "ps_" + secrets.token_urlsafe(32), time.time() + ttl
        with STORE.lock:
            STORE.pairings[pairing_id] = {"expires_at": expires_at, "status": "created", "request": None}
        return self.send_json({"pairing_id": pairing_id,
            "qr_url": f"{STORE.base_url}/.well-known/baton/pair/{pairing_id}",
            "approval_url": f"{STORE.base_url}/v1/baton/pairings/{pairing_id}/approval",
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
            pairing["status"] = "pending"
        return self.send_json({"pairing_id": pairing_id, "request_id": request_id, "status": "pending",
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
                token, session_id = STORE.new_token(pairing["request"]["device_id"])
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
            pairing["status"] = "consumed"
            token = request["access_token"]
        return self.send_json({"pairing_id": pairing_id, "request_id": request_id, "status": "approved", "pairing_status": "consumed",
            "access_token": token, "token_type": "Bearer", "expires_in": 86400,
            "device_id": request["device_id"],
            "session_id": request["session_id"],
            "conversation": {"id": STORE.conversation_id, "title": "Local test conversation"}})

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

    def do_POST(self):
        path, raw = urlparse(self.path).path.rstrip("/"), self.raw_body()
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
        if path.endswith("/messages"):
            if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
            parts = path.split("/")
            if len(parts) < 5 or parts[4] != STORE.conversation_id: return self.error(404, "conversation_not_found", "Conversation not found.")
            client_id = body.get("client_message_id")
            text = ((body.get("content") or [{}])[0].get("text") if isinstance(body.get("content"), list) else body.get("text"))
            if not client_id or not text: return self.error(400, "invalid_message", "client_message_id and text content are required.")
            with STORE.condition:
                for message in STORE.messages:
                    if message.get("client_message_id") == client_id: return self.send_json(message)
                message = STORE.add_message("msg_" + uuid.uuid4().hex[:16], client_id, "user", text)
                STORE.event("message.created", message)
                run_id = "run_" + uuid.uuid4().hex[:12]
                STORE.runs[run_id] = {"status": "active", "message_id": None}
                STORE.event("run.started", {"run_id": run_id})
            threading.Thread(target=self.stream_reply, args=(run_id, text), daemon=True).start()
            return self.send_json(message, 201)
        if ":cancel" in path and "/runs/" in path:
            if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
            run_id = path.split("/runs/", 1)[1].split(":", 1)[0]
            with STORE.lock:
                run = STORE.runs.get(run_id)
                if not run: return self.error(404, "run_not_found", "Run not found.")
                if run["status"] == "active": run["status"] = "cancellation_requested"
                status = run["status"]
            return self.send_json({"run_id": run_id, "status": status}, 202 if status == "cancellation_requested" else 200)
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
        return self.error(404, "not_found", "Not found.")

    def stream_reply(self, run_id, text):
        reply, message_id = "Mock 回复：" + text, "msg_" + uuid.uuid4().hex[:16]
        with STORE.lock:
            run = STORE.runs.get(run_id)
            if not run: return
            run["message_id"] = message_id
        STORE.event("message.created", {"id": message_id, "conversation_id": STORE.conversation_id,
                    "role": "assistant", "content": [{"type": "text", "text": ""}], "status": "streaming"})
        for chunk in [reply[i:i + 4] for i in range(0, len(reply), 4)]:
            time.sleep(.04)
            with STORE.lock:
                run = STORE.runs.get(run_id)
                if not run or run["status"] == "cancellation_requested":
                    if run: run["status"] = "cancelled"
                    STORE.event("message.completed", {"message_id": message_id, "status": "cancelled"})
                    STORE.event("run.cancelled", {"run_id": run_id, "status": "cancelled"})
                    return
            STORE.event("message.delta", {"message_id": message_id, "delta": chunk})
        with STORE.condition:
            run = STORE.runs.get(run_id)
            if not run or run["status"] != "active":
                if run and run["status"] != "cancelled":
                    run["status"] = "cancelled"
                    STORE.event("message.completed", {"message_id": message_id, "status": "cancelled"})
                    STORE.event("run.cancelled", {"run_id": run_id, "status": "cancelled"})
                return
            run["status"] = "completed"
            STORE.add_message(message_id, None, "assistant", reply)
        STORE.event("message.completed", {"message_id": message_id, "status": "completed"})
        STORE.event("run.completed", {"run_id": run_id, "status": "completed"})

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        discovery_prefix, pairing_prefix = "/.well-known/baton/pair/", "/v1/baton/pairings/"
        if path.startswith(discovery_prefix):
            pairing_id = path[len(discovery_prefix):]
            with STORE.lock:
                pairing = self.active_pairing(pairing_id)
                if not pairing: return
            return self.send_json({"protocol": "baton/1.0", "pairing_id": pairing_id,
                "expires_at": datetime.fromtimestamp(pairing["expires_at"], timezone.utc).isoformat().replace("+00:00", "Z"),
                "service": {"id": "local-mock", "name": "Local Baton Mock"},
                "conversation": {"id": STORE.conversation_id, "title": "Local test conversation", "agent_name": "Mock Agent"},
                "endpoints": {"join": f"{STORE.base_url}/v1/baton/pairings/{pairing_id}/requests",
                              "approval": f"{STORE.base_url}/v1/baton/pairings/{pairing_id}/approval",
                              "conversation": f"{STORE.base_url}/v1/baton/conversations/{STORE.conversation_id}"},
                "capabilities": {"text": True, "markdown": True, "streaming": True}})
        if path.startswith(pairing_prefix) and path.endswith("/approval"):
            return self.approval_page(path[len(pairing_prefix):-len("/approval")].strip("/"))
        if path.startswith(pairing_prefix) and "/requests/" in path:
            pairing_id, request_id = path[len(pairing_prefix):].split("/requests/", 1)
            return self.poll_pairing(pairing_id, request_id)
        if not self.auth(): return self.error(401, "invalid_token", "Missing or invalid bearer token.")
        conversation_path = f"/v1/baton/conversations/{STORE.conversation_id}"
        if path == conversation_path:
            with STORE.lock:
                return self.send_json({"id": STORE.conversation_id, "title": "Local test conversation", "agent_name": "Mock Agent",
                                       "messages": list(reversed(STORE.messages)), "next_cursor": None,
                                       "event_cursor": STORE.event_cursor()})
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
        self.send_header("Connection", "keep-alive")
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
        deadline = time.time() + 30
        while time.time() < deadline:
            with STORE.condition:
                pending = [e for e in STORE.events if e["sequence"] > last]
                if not pending:
                    STORE.condition.wait(timeout=2)
                    pending = [e for e in STORE.events if e["sequence"] > last]
            if not pending:
                try:
                    self.wfile.write(b": heartbeat\n\n"); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
                continue
            for event in pending:
                if not self.write_sse(event): return
                last = event["sequence"]

    def write_sse(self, event):
        raw = ("id: %s\nevent: %s\ndata: %s\n\n" % (event["id"], event["type"], json.dumps(event, ensure_ascii=False))).encode()
        try:
            self.wfile.write(raw); self.wfile.flush()
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
    global STORE
    parser = argparse.ArgumentParser(description="Local Baton Companion mock server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--event-retention", type=int, default=64, help="retained SSE event envelopes per conversation (fixture only)")
    args = parser.parse_args()
    STORE = Store(f"http://{args.host}:{args.port}", event_retention=args.event_retention)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Baton mock server listening at {STORE.base_url}", flush=True)
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()


if __name__ == "__main__": main()
