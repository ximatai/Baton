#!/usr/bin/env python3
"""Repeatable pairing and conversation smoke test; starts no server itself."""
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from urllib.parse import urlparse

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8787"
CONVERSATION_ID = None
REVIEW_DEMO_TOKEN = os.environ.get("BATON_REVIEW_DEMO_TOKEN")


def request(path, method="GET", payload=None, token=None, expect_json=True, extra_headers=None):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    if token:
        headers["Authorization"] = "Bearer " + token
    headers.update(extra_headers or {})
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            return response.status, json.load(response) if expect_json else response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, json.load(error) if expect_json else error.read().decode()


def create_pairing(payload=None):
    status, pairing = request("/v1/baton/pairings", "POST", payload or {})
    assert status == 200 and pairing["pairing_id"].startswith("ps_")
    return pairing


if REVIEW_DEMO_TOKEN:
    # A stable review URL is not itself a pairing credential. It creates a
    # normal, short-lived, auto-approved invitation for a single scanner.
    status, page = request(f"/review/{REVIEW_DEMO_TOKEN}", expect_json=False)
    assert status == 200 and "App Review Demo" in page
    status, review_pair = request(f"/review/{REVIEW_DEMO_TOKEN}/pairing", "POST", {})
    assert status == 200 and review_pair["approval_mode"] == "auto"
    assert review_pair["expires_at"].endswith("Z")
    status, review_discovery = request("/.well-known/baton/pair/" + review_pair["pairing_id"])
    assert status == 200 and review_discovery["approval_mode"] == "auto"


def read_sse_until(token, last_event_id, predicate, maximum=20):
    """Read well-formed SSE envelopes until predicate(events) is true."""
    headers = {"Authorization": "Bearer " + token, "Accept": "text/event-stream"}
    if last_event_id:
        headers["Last-Event-ID"] = last_event_id
    req = urllib.request.Request(BASE + f"/v1/baton/conversations/{CONVERSATION_ID}/events", headers=headers)
    response = urllib.request.urlopen(req, timeout=3)
    events, fields = [], {}
    try:
        while len(events) < maximum:
            line = response.readline().decode("utf-8").rstrip("\r\n")
            if not line:
                if not fields:
                    continue  # heartbeat
                assert {"id", "event", "data"} <= fields.keys(), fields
                envelope = json.loads(fields["data"])
                # The HTTP event field and the Baton envelope deliberately say
                # the same thing; this catches nonstandard SSE framing.
                assert fields["id"] == envelope["id"] and fields["event"] == envelope["type"], fields
                assert isinstance(envelope.get("sequence"), int) and envelope["sequence"] > 0, envelope
                events.append(envelope)
                fields = {}
                if predicate(events): return events
                continue
            if line.startswith(":"):
                continue
            key, value = line.split(":", 1)
            fields[key] = value.lstrip(" ")
    finally:
        response.close()
    raise AssertionError(f"SSE predicate was not met; received {events!r}")


# A device does not gain authority merely by scanning a QR code.
pair = create_pairing()
pairing_id = pair["pairing_id"]
status, discovery = request("/.well-known/baton/pair/" + pairing_id)
assert status == 200 and discovery["conversation"]["id"].startswith("conv_") and "join" in discovery["endpoints"]
assert discovery["protocol"] == "baton/1.1"
assert discovery["capabilities"] == {"text": True, "markdown": True, "streaming": True, "image": True, "content_append": True}
CONVERSATION_ID = discovery["conversation"]["id"]
status, denied = request(f"/v1/baton/conversations/{CONVERSATION_ID}")
assert status == 401 and denied["error"]["code"] == "invalid_token"

# The iPhone joins, then waits for the existing web client to decide.
proof = "proof_" + uuid.uuid4().hex + uuid.uuid4().hex
status, joined = request("/v1/baton/pairings/" + pairing_id + "/requests", "POST",
                         {"device_id": "smoke", "device_name": "Smoke iPhone", "device_proof": proof})
assert status == 202 and joined["status"] == "pending"
poll = urlparse(joined["poll_url"])
base = urlparse(BASE)
assert poll.scheme and poll.netloc and (poll.scheme, poll.netloc) == (base.scheme, base.netloc)
status, duplicate_join = request("/v1/baton/pairings/" + pairing_id + "/requests", "POST",
                                 {"device_id": "second-device", "device_proof": proof})
assert status == 409 and duplicate_join["error"]["code"] == "pairing_not_available"
status, waiting = request("/v1/baton/pairings/" + pairing_id + "/requests/" + joined["request_id"], extra_headers={"X-Baton-Device-Proof": proof})
assert status == 200 and waiting["status"] == "pending" and "access_token" not in waiting
status, approval_page = request("/v1/baton/pairings/" + pairing_id + "/approval", expect_json=False)
assert status == 200 and "Smoke iPhone" in approval_page

status, approved = request("/v1/baton/pairings/" + pairing_id + "/approval", "POST", {"decision": "approved"})
assert status == 200 and approved["status"] == "approved"
status, forbidden_claim = request("/v1/baton/pairings/" + pairing_id + "/requests/" + joined["request_id"], extra_headers={"X-Baton-Device-Proof": "wrong-proof"})
assert status == 403 and forbidden_claim["error"]["code"] == "invalid_device_proof"
status, credential = request("/v1/baton/pairings/" + pairing_id + "/requests/" + joined["request_id"], extra_headers={"X-Baton-Device-Proof": proof})
assert status == 200 and credential["status"] == "approved" and credential["access_token"]
token = credential["access_token"]
session_id = credential["session_id"]
status, replayed_claim = request("/v1/baton/pairings/" + pairing_id + "/requests/" + joined["request_id"], extra_headers={"X-Baton-Device-Proof": proof})
assert status == 200 and replayed_claim["access_token"] == token and replayed_claim["pairing_status"] == "consumed"

# Auto approval remains a server-side policy: discovery informs the App, but
# only the first proof-bound join is atomically approved and claim still needs
# that proof. The Join response never carries a credential.
auto_pair = create_pairing({"approval_mode": "auto"})
status, auto_discovery = request("/.well-known/baton/pair/" + auto_pair["pairing_id"])
assert status == 200 and auto_pair["approval_mode"] == "auto" and auto_discovery["approval_mode"] == "auto"
auto_proof = "proof_" + uuid.uuid4().hex + uuid.uuid4().hex
status, auto_join = request("/v1/baton/pairings/" + auto_pair["pairing_id"] + "/requests", "POST",
                            {"device_id": "auto-smoke", "device_name": "Auto Smoke iPhone", "device_proof": auto_proof})
assert status == 202 and auto_join["status"] == "approved" and "access_token" not in auto_join
status, auto_forbidden = request("/v1/baton/pairings/" + auto_pair["pairing_id"] + "/requests/" + auto_join["request_id"],
                                 extra_headers={"X-Baton-Device-Proof": "wrong-proof"})
assert status == 403 and auto_forbidden["error"]["code"] == "invalid_device_proof"
status, auto_credential = request("/v1/baton/pairings/" + auto_pair["pairing_id"] + "/requests/" + auto_join["request_id"],
                                  extra_headers={"X-Baton-Device-Proof": auto_proof})
assert status == 200 and auto_credential["status"] == "approved" and auto_credential["access_token"]

# The granted token can now use the normal conversation API and retains send idempotency.
status, snapshot = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=token)
assert status == 200 and snapshot["messages"] and snapshot["event_cursor"]["id"]
welcome_image = next(part for message in snapshot["messages"] for part in message["content"] if part["type"] == "image")
assert welcome_image["mime_type"] == "image/png" and welcome_image["width"] == 320 and welcome_image["height"] == 200
assert welcome_image["media_id"] == "med_mock_chart_v1"
assert welcome_image["alt"] == "蓝色渐变的本地 Mock 图表示例"
image_url, origin = urlparse(welcome_image["url"]), urlparse(BASE)
assert (image_url.scheme, image_url.netloc) == (origin.scheme, origin.netloc)
status, denied_image = request(image_url.path)
assert status == 401 and denied_image["error"]["code"] == "invalid_token"
image_request = urllib.request.Request(welcome_image["url"], headers={"Authorization": "Bearer " + token, "Accept": "image/png"})
with urllib.request.urlopen(image_request, timeout=3) as image_response:
    image_bytes = image_response.read()
    assert image_response.status == 200 and image_response.headers.get_content_type() == "image/png"
    assert image_response.headers.get("Cache-Control") == "private, no-store"
assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n") and len(image_bytes) < 12 * 1024 * 1024
client_id = str(uuid.uuid4())
payload = {"client_message_id": client_id, "content": [{"type": "text", "text": "hello"}]}
status, first = request(f"/v1/baton/conversations/{CONVERSATION_ID}/messages", "POST", payload, token)
status2, second = request(f"/v1/baton/conversations/{CONVERSATION_ID}/messages", "POST", payload, token)
assert status == 201 and status2 == 200 and first["id"] == second["id"]

# The assistant placeholder and the streamed prefix are source-of-truth state,
# not merely transient SSE. A reconnecting client can render them from a
# snapshot while the run remains active.
time.sleep(.08)
status, streaming_snapshot = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=token)
assert status == 200 and streaming_snapshot["active_runs"]
streaming_assistant = next(message for message in streaming_snapshot["messages"] if message["role"] == "assistant" and message["status"] == "streaming")
assert streaming_assistant["content"][0]["text"]

# A snapshot is atomically paired with its event cursor: only envelopes newer
# than that cursor replay, and every envelope uses standard SSE id/event/data.
time.sleep(.5)  # Let the small deterministic reply above finish before the next assertion.
status, resume_snapshot = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=token)
assert status == 200
cursor = resume_snapshot["event_cursor"]

# V1.1 keeps a server-created evidence image attached to the same completed
# assistant message. It is persisted, replayable, and uses the same immutable
# media identity as the image found in a later atomic snapshot.
append_payload = {"client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": "append evidence"}]}
status, _ = request(f"/v1/baton/conversations/{CONVERSATION_ID}/messages", "POST", append_payload, token)
assert status == 201
appended_events = read_sse_until(token, cursor["id"], lambda events: any(event["type"] == "message.content.appended" for event in events))
append_event = next(event for event in appended_events if event["type"] == "message.content.appended")
assert append_event["data"]["content"] and append_event["data"]["content"][0]["media_id"] == "med_mock_chart_v1"
assert append_event["data"]["content"][0]["alt"] == welcome_image["alt"]
replayed_append = read_sse_until(token, cursor["id"], lambda events: any(event["id"] == append_event["id"] for event in events))
assert sum(event["id"] == append_event["id"] for event in replayed_append) == 1
status, appended_snapshot = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=token)
assert status == 200
appended_message = next(message for message in appended_snapshot["messages"] if message["id"] == append_event["data"]["message_id"])
assert appended_message["status"] == "completed"
assert appended_message["content"][-1]["media_id"] == append_event["data"]["content"][0]["media_id"]
assert appended_message["content"][-1] == append_event["data"]["content"][0]

# Continue with a separate run for cancellation semantics.
cursor = appended_snapshot["event_cursor"]
resume_payload = {"client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": "resume cursor"}]}
status, _ = request(f"/v1/baton/conversations/{CONVERSATION_ID}/messages", "POST", resume_payload, token)
assert status == 201
replayed = read_sse_until(token, cursor["id"], lambda events: any(event["type"] == "run.started" for event in events))
assert all(event["sequence"] > cursor["sequence"] for event in replayed)
assert all(event["type"] != "conversation.snapshot" for event in replayed)
run_id = next(event["data"]["run_id"] for event in replayed if event["type"] == "run.started")

# Cancellation is requested once and reaches one terminal, ordered outcome:
# assistant message terminal state followed by run.cancelled. Repeating cancel
# is harmless and never emits a duplicate terminal event.
status, cancelling = request(f"/v1/baton/conversations/{CONVERSATION_ID}/runs/{run_id}:cancel", "POST", {}, token)
assert status == 202 and cancelling == {"run_id": run_id, "status": "cancelled"}
cancelled_events = read_sse_until(
    token,
    next(event["id"] for event in replayed if event["type"] == "run.started"),
    lambda events: any(event["type"] == "run.cancelled" for event in events),
)
terminal_types = [event["type"] for event in cancelled_events if event["type"] in {"message.completed", "run.cancelled"}]
assert terminal_types == ["message.completed", "run.cancelled"]
assert next(event for event in cancelled_events if event["type"] == "message.completed")["data"]["status"] == "cancelled"
status, repeated_cancel = request(f"/v1/baton/conversations/{CONVERSATION_ID}/runs/{run_id}:cancel", "POST", {}, token)
assert status == 200 and repeated_cancel == {"run_id": run_id, "status": "cancelled"}

# Provider failure terminates through the V1 sequence: the message reports a
# safe failure first, then the same run reaches run.completed(status: failed).
# This one-shot, authenticated hook avoids relying on a real provider outage.
status, armed = request("/v1/baton/mock/chat:fail-next", "POST", {}, token)
assert status == 200 and armed == {"status": "armed"}
failure_snapshot_status, failure_snapshot = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=token)
assert failure_snapshot_status == 200
failure_payload = {"client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": "fixture failure"}]}
status, _ = request(f"/v1/baton/conversations/{CONVERSATION_ID}/messages", "POST", failure_payload, token)
assert status == 201
failed_events = read_sse_until(
    token,
    failure_snapshot["event_cursor"]["id"],
    lambda events: any(event["type"] == "run.completed" and event["data"]["status"] == "failed" for event in events),
)
failure_terminals = [event for event in failed_events if event["type"] in {"message.failed", "run.completed", "run.failed"}]
assert [event["type"] for event in failure_terminals] == ["message.failed", "run.completed"]
assert failure_terminals[1]["data"]["status"] == "failed"

# Cancellation becomes terminal at the Baton boundary, even while a provider
# call is still blocked. The late provider result must be silent.
status, armed = request("/v1/baton/mock/chat:slow-next", "POST", {"seconds": 1}, token)
assert status == 200 and armed == {"status": "armed"}
status, slow_snapshot = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=token)
assert status == 200
status, _ = request(f"/v1/baton/conversations/{CONVERSATION_ID}/messages", "POST", {
    "client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": "slow cancel"}]
}, token)
assert status == 201
slow_started = read_sse_until(token, slow_snapshot["event_cursor"]["id"], lambda events: any(event["type"] == "run.started" for event in events))
slow_run = next(event["data"]["run_id"] for event in slow_started if event["type"] == "run.started")
status, cancelled = request(f"/v1/baton/conversations/{CONVERSATION_ID}/runs/{slow_run}:cancel", "POST", {}, token)
assert status == 202 and cancelled == {"run_id": slow_run, "status": "cancelled"}
slow_terminal = read_sse_until(token, next(event["id"] for event in slow_started if event["type"] == "run.started"),
                               lambda events: any(event["type"] == "run.cancelled" for event in events))
terminal_cursor = next(event["id"] for event in slow_terminal if event["type"] == "run.cancelled")
time.sleep(1.1)
status, after_slow = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=token)
assert status == 200 and after_slow["event_cursor"]["id"] == terminal_cursor

# The mock keeps a finite log. Expire an otherwise valid historical cursor via
# its authenticated test hook; the server must send a complete Baton resync
# envelope, never silently replay from the beginning.
stale_cursor = cursor["id"]
status, trimmed = request("/v1/baton/mock/events:retention", "POST", {"retain_last": 1}, token)
assert status == 200 and trimmed["retained_events"] == 1
resync = read_sse_until(token, stale_cursor, lambda events: bool(events))
assert len(resync) == 1 and resync[0]["type"] == "conversation.resync"
assert resync[0]["data"] == {"reason": "cursor_unknown_or_expired"}

# Rejection is terminal and never yields a token.
rejected_pair = create_pairing()
rejected_proof = "proof_" + uuid.uuid4().hex + uuid.uuid4().hex
status, rejected_join = request("/v1/baton/pairings/" + rejected_pair["pairing_id"] + "/requests", "POST", {"device_id": "rejected", "device_proof": rejected_proof})
assert status == 202
status, decision = request("/v1/baton/pairings/" + rejected_pair["pairing_id"] + "/approval", "POST", {"decision": "rejected"})
assert status == 200 and decision["status"] == "rejected"
status, rejected = request("/v1/baton/pairings/" + rejected_pair["pairing_id"] + "/requests/" + rejected_join["request_id"], extra_headers={"X-Baton-Device-Proof": rejected_proof})
assert status == 200 and rejected == {"pairing_id": rejected_pair["pairing_id"], "request_id": rejected_join["request_id"], "status": "rejected"}

# This mock-only TTL hook makes expiration repeatable without slowing the test.
expired_pair = create_pairing({"mock_ttl_seconds": .02})
expired_proof = "proof_" + uuid.uuid4().hex + uuid.uuid4().hex
status, expired_join = request("/v1/baton/pairings/" + expired_pair["pairing_id"] + "/requests", "POST",
                               {"device_id": "expired", "device_proof": expired_proof})
assert status == 202
time.sleep(.03)
status, expired = request("/v1/baton/pairings/" + expired_pair["pairing_id"] + "/requests/" + expired_join["request_id"],
                          extra_headers={"X-Baton-Device-Proof": expired_proof})
assert status == 410 and expired["error"]["code"] == "pairing_expired"

# Device revocation is exact: the bearer can revoke only its own opaque session.
status, revoked = request(f"/v1/baton/devices/smoke/sessions/{session_id}", "DELETE", token=token)
assert status == 200 and revoked == {"status": "revoked"}
status, denied_after_revoke = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=token)
assert status == 401 and denied_after_revoke["error"]["code"] == "invalid_token"

# Ending a conversation is shared, not a device-only disconnect: a connection
# already subscribed on another device receives the close event; pending
# invitations and bearer credentials become invalid; a new pairing gets a new
# conversation ID rather than a reset event sequence under the old ID.
end_pair = create_pairing()
end_proof = "proof_" + uuid.uuid4().hex + uuid.uuid4().hex
status, end_join = request("/v1/baton/pairings/" + end_pair["pairing_id"] + "/requests", "POST",
                           {"device_id": "end", "device_proof": end_proof})
assert status == 202
status, _ = request("/v1/baton/pairings/" + end_pair["pairing_id"] + "/approval", "POST", {"decision": "approved"})
assert status == 200
status, end_credential = request("/v1/baton/pairings/" + end_pair["pairing_id"] + "/requests/" + end_join["request_id"], extra_headers={"X-Baton-Device-Proof": end_proof})
assert status == 200
end_token = end_credential["access_token"]

observer_pair = create_pairing()
observer_proof = "proof_" + uuid.uuid4().hex + uuid.uuid4().hex
status, observer_join = request("/v1/baton/pairings/" + observer_pair["pairing_id"] + "/requests", "POST",
                                {"device_id": "observer", "device_proof": observer_proof})
assert status == 202
status, _ = request("/v1/baton/pairings/" + observer_pair["pairing_id"] + "/approval", "POST", {"decision": "approved"})
assert status == 200
status, observer_credential = request("/v1/baton/pairings/" + observer_pair["pairing_id"] + "/requests/" + observer_join["request_id"], extra_headers={"X-Baton-Device-Proof": observer_proof})
assert status == 200
observer_token = observer_credential["access_token"]
status, observer_snapshot = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=observer_token)
assert status == 200
observer_result = []
def observe_end():
    try:
        observer_result.append(read_sse_until(observer_token, observer_snapshot["event_cursor"]["id"],
                                              lambda events: any(event["type"] == "conversation.closed" for event in events)))
    except Exception as exc:
        observer_result.append(exc)
observer_thread = threading.Thread(target=observe_end, daemon=True)
observer_thread.start()
time.sleep(.08)

pending_pair = create_pairing()
pending_proof = "proof_" + uuid.uuid4().hex + uuid.uuid4().hex
status, pending_join = request("/v1/baton/pairings/" + pending_pair["pairing_id"] + "/requests", "POST",
                               {"device_id": "pending", "device_proof": pending_proof})
assert status == 202
status, ended = request(f"/v1/baton/conversations/{CONVERSATION_ID}:end", "POST", {}, token=end_token)
assert status == 200 and ended == {"status": "ended"}
observer_thread.join(2)
assert observer_result and not isinstance(observer_result[0], Exception)
assert any(event["type"] == "conversation.closed" for event in observer_result[0])
status, denied_after_end = request(f"/v1/baton/conversations/{CONVERSATION_ID}", token=end_token)
assert status == 401 and denied_after_end["error"]["code"] == "invalid_token"
status, expired_pending = request("/v1/baton/pairings/" + pending_pair["pairing_id"] + "/requests/" + pending_join["request_id"], extra_headers={"X-Baton-Device-Proof": pending_proof})
assert status == 410 and expired_pending["error"]["code"] == "pairing_expired"
next_pair = create_pairing()
status, next_discovery = request("/.well-known/baton/pair/" + next_pair["pairing_id"])
assert status == 200 and next_discovery["conversation"]["id"] != CONVERSATION_ID

print("smoke test passed: V1.1 media identity/append replay, pairing safety, source-of-truth streaming snapshots, terminal cancel/failure, invalid-cursor resync, exact session revocation, and shared conversation end")
