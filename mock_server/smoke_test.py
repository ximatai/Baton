#!/usr/bin/env python3
"""Repeatable pairing and conversation smoke test; starts no server itself."""
import json
import sys
import time
import urllib.error
import urllib.request
import uuid

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8787"


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


def read_sse_until(token, last_event_id, predicate, maximum=20):
    """Read well-formed SSE envelopes until predicate(events) is true."""
    headers = {"Authorization": "Bearer " + token, "Accept": "text/event-stream"}
    if last_event_id:
        headers["Last-Event-ID"] = last_event_id
    req = urllib.request.Request(BASE + "/v1/baton/conversations/conv_local/events", headers=headers)
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
assert status == 200 and discovery["conversation"]["id"] == "conv_local" and "join" in discovery["endpoints"]
status, denied = request("/v1/baton/conversations/conv_local")
assert status == 401 and denied["error"]["code"] == "invalid_token"

# The iPhone joins, then waits for the existing web client to decide.
proof = "proof_" + uuid.uuid4().hex + uuid.uuid4().hex
status, joined = request("/v1/baton/pairings/" + pairing_id + "/requests", "POST",
                         {"device_id": "smoke", "device_name": "Smoke iPhone", "device_proof": proof})
assert status == 202 and joined["status"] == "pending"
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

# The granted token can now use the normal conversation API and retains send idempotency.
status, snapshot = request("/v1/baton/conversations/conv_local", token=token)
assert status == 200 and snapshot["messages"] and snapshot["event_cursor"]["id"]
client_id = str(uuid.uuid4())
payload = {"client_message_id": client_id, "content": [{"type": "text", "text": "hello"}]}
status, first = request("/v1/baton/conversations/conv_local/messages", "POST", payload, token)
status2, second = request("/v1/baton/conversations/conv_local/messages", "POST", payload, token)
assert status == 201 and status2 == 200 and first["id"] == second["id"]

# A snapshot is atomically paired with its event cursor: only envelopes newer
# than that cursor replay, and every envelope uses standard SSE id/event/data.
time.sleep(.5)  # Let the small deterministic reply above finish before the next assertion.
status, resume_snapshot = request("/v1/baton/conversations/conv_local", token=token)
assert status == 200
cursor = resume_snapshot["event_cursor"]
resume_payload = {"client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": "resume cursor"}]}
status, _ = request("/v1/baton/conversations/conv_local/messages", "POST", resume_payload, token)
assert status == 201
replayed = read_sse_until(token, cursor["id"], lambda events: any(event["type"] == "run.started" for event in events))
assert all(event["sequence"] > cursor["sequence"] for event in replayed)
assert all(event["type"] != "conversation.snapshot" for event in replayed)
run_id = next(event["data"]["run_id"] for event in replayed if event["type"] == "run.started")

# Cancellation is requested once and reaches one terminal, ordered outcome:
# assistant message terminal state followed by run.cancelled. Repeating cancel
# is harmless and never emits a duplicate terminal event.
status, cancelling = request(f"/v1/baton/conversations/conv_local/runs/{run_id}:cancel", "POST", {}, token)
assert status == 202 and cancelling == {"run_id": run_id, "status": "cancellation_requested"}
cancelled_events = read_sse_until(
    token,
    next(event["id"] for event in replayed if event["type"] == "run.started"),
    lambda events: any(event["type"] == "run.cancelled" for event in events),
)
terminal_types = [event["type"] for event in cancelled_events if event["type"] in {"message.completed", "run.cancelled"}]
assert terminal_types == ["message.completed", "run.cancelled"]
assert next(event for event in cancelled_events if event["type"] == "message.completed")["data"]["status"] == "cancelled"
status, repeated_cancel = request(f"/v1/baton/conversations/conv_local/runs/{run_id}:cancel", "POST", {}, token)
assert status == 200 and repeated_cancel == {"run_id": run_id, "status": "cancelled"}

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
status, denied_after_revoke = request("/v1/baton/conversations/conv_local", token=token)
assert status == 401 and denied_after_revoke["error"]["code"] == "invalid_token"

print("smoke test passed: pairing safety, idempotent messages, atomic snapshot cursor/SSE replay, terminal cancel, invalid-cursor resync, and exact session revocation")
