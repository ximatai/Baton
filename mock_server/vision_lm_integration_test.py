#!/usr/bin/env python3
"""Opt-in live LM Studio V1.3 image round trip; the fixture must already run."""
import json, sys, time, uuid, urllib.request
from io import BytesIO
from PIL import Image, ImageDraw, ImageFont

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8792"

def request(path, method="GET", body=None, headers=None, raw=False):
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=10) as response:
        return response.status, response.read() if raw else json.load(response)

def json_request(path, method="GET", value=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token: headers["Authorization"] = "Bearer " + token
    return request(path, method, json.dumps(value or {}).encode(), headers)

def pair():
    _, pairing = json_request("/v1/baton/pairings", "POST")
    _, discovery = request("/.well-known/baton/pair/" + pairing["pairing_id"])
    assert discovery["protocol"] == "baton/1.3"
    proof = "proof_" + uuid.uuid4().hex * 2
    _, joined = json_request("/v1/baton/pairings/" + pairing["pairing_id"] + "/requests", "POST", {"device_id":"vision-live", "device_name":"vision-live", "device_proof":proof, "client_capabilities":{"selection_interaction":True}})
    json_request("/v1/baton/pairings/" + pairing["pairing_id"] + "/approval", "POST", {"decision":"approved"})
    _, credential = request("/v1/baton/pairings/" + pairing["pairing_id"] + "/requests/" + joined["request_id"], headers={"X-Baton-Device-Proof":proof})
    return discovery["conversation"]["id"], credential["access_token"]

def png():
    image = Image.new("RGB", (160, 100), "white"); draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, 79, 99), fill="red"); draw.rectangle((80, 0, 159, 99), fill="blue")
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 56)
    draw.text((25, 18), "3", fill="white", font=font); draw.text((105, 18), "8", fill="white", font=font)
    output = BytesIO(); image.save(output, "PNG"); return output.getvalue()

conversation, token = pair(); path = "/v1/baton/conversations/" + conversation
image = png(); boundary = "baton-" + uuid.uuid4().hex
body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"geometry.png\"\r\nContent-Type: image/png\r\n\r\n".encode() + image + f"\r\n--{boundary}--\r\n".encode())
_, staged = request(path + "/media", "POST", body, {"Authorization":"Bearer " + token, "Idempotency-Key":str(uuid.uuid4()), "Content-Type":"multipart/form-data; boundary=" + boundary})
payload = {"client_message_id":str(uuid.uuid4()), "content":[{"type":"text", "text":"Describe the two colors and numbers in this image."}, {"type":"image_ref", "media_id":staged["media_id"]}]}
def assistant_messages():
    _, snapshot = json_request(path, token=token)
    return [m for m in snapshot["messages"] if m["role"] == "assistant" and m.get("status") == "completed" and m.get("content")]

def send_and_wait(payload, existing_ids):
    json_request(path + "/messages", "POST", payload, token)
    deadline = time.time() + 120
    while time.time() < deadline:
        replies = [m for m in assistant_messages() if m.get("id") not in existing_ids]
        if replies:
            text = "".join(part.get("text", "") for part in replies[0]["content"] if part.get("type") == "text").strip()
            if text: return text
        time.sleep(.5)
    raise AssertionError("LM reply did not complete (safe fixture status only)")

first = send_and_wait(payload, {m.get("id") for m in assistant_messages()})
assert not first.lower().startswith("mock"), "fixture fallback reply is not a live LM answer"
assert "red" in first.lower() and "blue" in first.lower(), "live LM did not identify both image colors"
_, resolved = request("/v1/baton/mock/web/media/" + staged["media_id"], raw=True)
assert resolved == image
second = send_and_wait({"client_message_id":str(uuid.uuid4()), "content":[{"type":"text", "text":"For the same image, repeat only the two numbers."}]}, {m.get("id") for m in assistant_messages()})
assert "3" in second and "8" in second, "live LM did not answer the image-number follow-up"
print("vision LM integration passed: paired upload, committed resolver byte equality, image reply, and same-image follow-up")
