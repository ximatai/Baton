#!/usr/bin/env python3
"""Focused in-memory authorization and expiry regressions for the V1.3 fixture."""
import copy
import sys
import uuid

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mock_server as fixture


fixture.VISION_ENABLED = True
fixture.STORE = fixture.Store("http://127.0.0.1:0")
handler = object.__new__(fixture.Handler)
handler.error = lambda status, code, message: (status, code)
handler.send_json = lambda value, status=200: (status, value)

with fixture.STORE.lock:
    token, _ = fixture.STORE.new_token("unit-device", fixture.STORE.conversation_id)
    active = copy.deepcopy(fixture.STORE.tokens[token])
    active.update({"_token": token, "_conversation_id": fixture.STORE.conversation_id, "_epoch": fixture.STORE.conversation_epoch})

body = {"client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": "first"}]}
status, message = handler.submit_message(body, active)
assert status == 201
with fixture.STORE.lock:
    fixture.STORE.revoke_session(token)

# Authorization is checked before both a new commit and an idempotent return.
assert handler.submit_message(body, active) == (401, "session_revoked")
assert handler.submit_message({"client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": "after revoke"}]}, active) == (401, "session_revoked")

# An expired object is a tombstone only to its original session; another device
# receives no ownership oracle.
with fixture.STORE.lock:
    fixture.STORE.media_tombstones["med_expired"] = {"session_id": active["session_id"], "conversation_id": active["_conversation_id"], "retained_until": 10**12}
    owner_token, _ = fixture.STORE.new_token("owner", fixture.STORE.conversation_id)
    owner = copy.deepcopy(fixture.STORE.tokens[owner_token])
    owner.update({"_token": owner_token, "_conversation_id": fixture.STORE.conversation_id, "_epoch": fixture.STORE.conversation_epoch})
    fixture.STORE.media_tombstones["med_expired"] = {"session_id": owner["session_id"], "conversation_id": owner["_conversation_id"], "retained_until": 10**12}
    other_token, _ = fixture.STORE.new_token("other", fixture.STORE.conversation_id)
    other = copy.deepcopy(fixture.STORE.tokens[other_token])
    other.update({"_token": other_token, "_conversation_id": fixture.STORE.conversation_id, "_epoch": fixture.STORE.conversation_epoch})

expired = {"client_message_id": str(uuid.uuid4()), "content": [{"type": "image_ref", "media_id": "med_expired"}]}
assert handler.submit_message(expired, owner) == (410, "media_expired")
assert handler.submit_message(expired, other) == (409, "media_not_owned")

# Decode happens outside the lock; revocation during that work must block the
# second lock acquisition instead of writing a staged object.
with fixture.STORE.lock:
    race_token, _ = fixture.STORE.new_token("race", fixture.STORE.conversation_id)
    race = copy.deepcopy(fixture.STORE.tokens[race_token])
    race.update({"_token": race_token, "_conversation_id": fixture.STORE.conversation_id, "_epoch": fixture.STORE.conversation_epoch})
handler.headers = {"Idempotency-Key": str(uuid.uuid4())}
handler.multipart_file = lambda raw: (b"image", "image/png")
def revoke_during_decode(value, mime):
    with fixture.STORE.lock: fixture.STORE.revoke_session(race_token)
    return {"bytes": b"image", "mime_type": "image/png", "width": 1, "height": 1}, None
handler.decode_static_image = revoke_during_decode
assert handler.upload_media(b"ignored", race) == (401, "session_revoked")
print("media unit test passed: post-auth revoke and owner-only expiry tombstone")
