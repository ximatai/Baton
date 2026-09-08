#!/usr/bin/env python3
"""V1.3 staged-image regression check; starts no server itself."""
import json
import sys
import time
import uuid
import urllib.error
import urllib.request
from io import BytesIO

from PIL import Image

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8788"


def request(path, method="GET", body=None, headers=None):
    request = urllib.request.Request(BASE + path, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as response:
        return response.code, json.load(response)


def json_request(path, method="GET", value=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token: headers["Authorization"] = "Bearer " + token
    return request(path, method, json.dumps(value or {}).encode(), headers)


def image_bytes(color):
    output = BytesIO(); Image.new("RGB", (24, 18), color).save(output, "PNG"); return output.getvalue()


def multipart(value, token, key, mime="image/png"):
    boundary = "baton-" + uuid.uuid4().hex
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\nContent-Type: {mime}\r\n\r\n").encode() + value + f"\r\n--{boundary}--\r\n".encode()
    return body, {"Authorization": "Bearer " + token, "Idempotency-Key": key, "Content-Type": "multipart/form-data; boundary=" + boundary}


def pair(device):
    _, pairing = json_request("/v1/baton/pairings", "POST")
    status, discovery = request("/.well-known/baton/pair/" + pairing["pairing_id"])
    assert status == 200 and discovery["protocol"] == "baton/1.3" and "image_upload" in discovery["capabilities"]
    proof = "proof_" + uuid.uuid4().hex * 2
    status, joined = json_request("/v1/baton/pairings/" + pairing["pairing_id"] + "/requests", "POST", {"device_id": device, "device_name": device, "device_proof": proof, "client_capabilities": {"selection_interaction": True}})
    assert status == 202
    json_request("/v1/baton/pairings/" + pairing["pairing_id"] + "/approval", "POST", {"decision": "approved"})
    status, credential = request("/v1/baton/pairings/" + pairing["pairing_id"] + "/requests/" + joined["request_id"], headers={"X-Baton-Device-Proof": proof})
    assert status == 200
    return discovery["conversation"]["id"], credential["access_token"], credential["session_id"], device


conversation, token, session, device = pair("media-smoke")
path = "/v1/baton/conversations/" + conversation
key, one = str(uuid.uuid4()), image_bytes("red")
status, staged = request(path + "/media", "POST", *multipart(one, token, key))
assert status == 201
status, retry = request(path + "/media", "POST", *multipart(one, token, key))
assert status == 200 and retry == staged
status, conflict = request(path + "/media", "POST", *multipart(image_bytes("blue"), token, key))
assert status == 409 and conflict["error"]["code"] == "idempotency_key_conflict"

# A response-lost retry finds the same stage; expiry turns that same key into
# an explicit 410, after which a new upload UUID can supply a fresh reference.
expiry_key = str(uuid.uuid4())
status, expiring = request(path + "/media", "POST", *multipart(image_bytes("purple"), token, expiry_key))
assert status == 201
status, _ = json_request("/v1/baton/mock/media:expire", "POST", {"media_id": expiring["media_id"]}, token)
assert status == 200
status, expired = request(path + "/media", "POST", *multipart(image_bytes("purple"), token, expiry_key))
assert status == 410 and expired["error"]["code"] == "media_expired"
retry_message_id = str(uuid.uuid4())
status, expired_ref = json_request(path + "/messages", "POST", {"client_message_id": retry_message_id, "content": [{"type": "image_ref", "media_id": expiring["media_id"]}]}, token)
assert status == 410 and expired_ref["error"]["code"] == "media_expired"
status, replacement = request(path + "/media", "POST", *multipart(image_bytes("purple"), token, str(uuid.uuid4())))
assert status == 201
status, retried_message = json_request(path + "/messages", "POST", {"client_message_id": retry_message_id, "content": [{"type": "image_ref", "media_id": replacement["media_id"]}]}, token)
assert status == 201

# A staged upload does not create a message or run; the normal commit does.
_, before = json_request(path, token=token)
message_id = str(uuid.uuid4())
payload = {"client_message_id": message_id, "content": [{"type": "text", "text": "red image"}, {"type": "image_ref", "media_id": staged["media_id"]}]}
status, committed = json_request(path + "/messages", "POST", payload, token)
assert status == 201 and any(part["type"] == "image" for part in committed["content"])
_, after = json_request(path, token=token)
assert len(after["messages"]) >= len(before["messages"]) + 2
status, replay = json_request(path + "/messages", "POST", payload, token)
assert status == 200 and replay["id"] == committed["id"]
status, changed_message = json_request(path + "/messages", "POST", {"client_message_id": message_id, "content": [{"type": "text", "text": "different"}]}, token)
assert status == 409 and changed_message["error"]["code"] == "idempotency_key_conflict"

image_only_key = str(uuid.uuid4())
status, image_only_stage = request(path + "/media", "POST", *multipart(image_bytes("orange"), token, image_only_key))
assert status == 201
status, image_only = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "image_ref", "media_id": image_only_stage["media_id"]}]}, token)
assert status == 201 and image_only["content"][0]["type"] == "image"
status, bad_text = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": 123}, {"type": "image_ref", "media_id": image_only_stage["media_id"]}]}, token)
assert status == 400
status, bad_media = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "image_ref", "media_id": []}]}, token)
assert status == 400
status, unknown_content = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "unknown"}]}, token)
assert status == 400
status, root_array = request(path + "/messages", "POST", json.dumps([]).encode(), {"Authorization": "Bearer " + token, "Content-Type": "application/json"})
assert status == 400

# A second device cannot attach the first device's staged object.
_, other_token, _, _ = pair("media-other")
other_key = str(uuid.uuid4())
status, private = request(path + "/media", "POST", *multipart(image_bytes("green"), token, other_key))
assert status == 201
status, forbidden = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "image_ref", "media_id": private["media_id"]}]}, other_token)
assert status == 409 and forbidden["error"]["code"] == "media_not_owned"
status, _ = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "text", "text": "confirm"}]}, token)
assert status == 201
_, required_snapshot = json_request(path, token=token)
required = next(part for message in required_snapshot["messages"] for part in message["content"] if part.get("type") == "selection" and part.get("input_policy") == "selection_required")
status, blocked_image = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "image_ref", "media_id": "med_any"}]}, token)
assert status == 409 and blocked_image["error"]["code"] == "selection_required"
status, _ = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "selection_response", "interaction_id": required["interaction_id"], "option_id": "confirm"}]}, token)
assert status == 201

# Wrong declared MIME and animation are rejected by full decode/format checks.
status, wrong_mime = request(path + "/media", "POST", *multipart(image_bytes("black"), token, str(uuid.uuid4()), "image/jpeg"))
assert status == 415
oversized_body, oversized_headers = multipart(b"x" * (12 * 1024 * 1024 + 1), token, str(uuid.uuid4()))
status, oversized = request(path + "/media", "POST", oversized_body, oversized_headers)
assert status == 413 and oversized["error"]["code"] == "media_too_large"
animated = BytesIO(); Image.new("RGB", (8, 8), "red").save(animated, "GIF", save_all=True, append_images=[Image.new("RGB", (8, 8), "blue")])
status, animation = request(path + "/media", "POST", *multipart(animated.getvalue(), token, str(uuid.uuid4()), "image/gif"))
assert status in (415, 422)
animated_png = BytesIO(); Image.new("RGB", (8, 8), "red").save(animated_png, "PNG", save_all=True, append_images=[Image.new("RGB", (8, 8), "blue")])
status, animated_png_result = request(path + "/media", "POST", *multipart(animated_png.getvalue(), token, str(uuid.uuid4())))
assert status == 422 and animated_png_result["error"]["code"] == "invalid_image_content"

# Revocation clears uncommitted staging; close fences remaining work.
status, revoked = json_request("/v1/baton/devices/" + device + "/sessions/" + session, "DELETE", token=token)
assert status == 200 and revoked["status"] == "revoked"
status, old_ref = json_request(path + "/messages", "POST", {"client_message_id": str(uuid.uuid4()), "content": [{"type": "image_ref", "media_id": private["media_id"]}]}, other_token)
assert status == 409 and old_ref["error"]["code"] == "media_not_owned"
status, ended = json_request(path + ":end", "POST", {}, other_token)
assert status == 200 and ended["status"] == "ended"
status, closed = request(path + "/media", "POST", *multipart(image_bytes("yellow"), other_token, str(uuid.uuid4())))
assert status == 401
print("media smoke passed: staged upload, idempotency, atomic commit, ownership, decode rejection, revocation, and close")
