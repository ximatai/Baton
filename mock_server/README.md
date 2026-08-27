# Local Baton Mock Server

Dependency-free development fixture for the V1 Companion Profile. It stores
one conversation in memory and generates deterministic streaming replies by
default. An explicit command-line option can use any OpenAI-compatible chat
endpoint instead; its API key is read only at runtime from an environment
variable and is never stored by this repository.

`agui_adapter.py` is a separately installed, optional reference boundary. It
uses the official AG-UI Python event models to translate the narrow V1 Agent
event subset into existing Baton event drafts. It does not add AG-UI event names
to the iOS wire format and does not make this mock an Agent framework.

## Start

```sh
python3 mock_server/mock_server.py
```

Open `http://127.0.0.1:8787/` for the fixture-only **local test console**. It
keeps the Web client and handoff controls side by side: the left area creates a
pairing, renders its QR code, and approves the phone; the right area is a Web
chat client for that same server-owned conversation. Any Web or iOS message is
therefore reflected in both clients through the same event stream.

The browser chat calls `/v1/baton/mock/web/*`, an intentionally unauthenticated
fixture convenience. It is not part of Baton/1.0 and must not be copied into a
production integration: the real Java Web client uses its existing session and
the mobile client uses its paired bearer credential.

For a browser page that renders each test pairing as a scannable QR image,
install the small optional QR dependency before starting the fixture:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r mock_server/requirements-qr.txt
.venv/bin/python mock_server/mock_server.py
```

The default address is `http://127.0.0.1:8787`. For an iOS Simulator, this
address is reachable as-is. HTTP is intentionally allowed only for this local
fixture; a real deployment must use HTTPS.

For a Debug build on a phone sharing the same trusted LAN, bind the fixture to
all interfaces but advertise the Mac's private IP (never `0.0.0.0`):

```sh
python3 mock_server/mock_server.py --host 0.0.0.0 \
  --public-base-url http://172.20.10.3:8787
```

The iOS Debug client accepts only loopback or RFC1918 private IPv4 HTTP hosts;
Release remains HTTPS-only. This is a temporary local-network test path, not a
production deployment option.

After creating a pairing, open its fixture-only browser page at
`/v1/baton/pairings/{pairing_id}/qr`. The protocol discovery URL in the QR
remains `/.well-known/baton/pair/{pairing_id}` and correctly returns JSON to a
client; it is not intended to render an image itself.

## Optional LM Studio reply engine

To exercise a real model while retaining the same Baton pairing, messages, and
SSE contract, start the fixture with an OpenAI-compatible completion endpoint:

```sh
python3 mock_server/mock_server.py --host 0.0.0.0 \
  --public-base-url http://172.20.10.3:8787 \
  --openai-chat-completions-url https://llm.example.com/v1/chat/completions \
  --openai-model your-model-id \
  --openai-reasoning-effort none
```

Replace the endpoint and model with your OpenAI-compatible provider. The
command reads `LM_STUDIO_KEY` from the current process environment by default;
use `--api-key-env` to name a different environment variable. The
upstream call is intentionally non-streaming; this small fixture converts the
completed response into normal Baton `message.delta` events. It therefore
tests the iOS streaming UI without turning the fixture into an LLM gateway.
For compatibility with the configured local model, it forwards only the latest
user turn; multi-turn Agent context remains the real Java service's job.
`--openai-reasoning-effort` is optional and only useful for providers that
understand it; omitting it preserves generic OpenAI-compatible behavior.
If the provider fails, the app receives `message.failed`, followed by
`run.completed` with `status: "failed"`, using a generic retryable error and
never exposing provider response details.

## Pair, approve in the browser, and call the conversation API

```sh
PAIR=$(curl -s -X POST http://127.0.0.1:8787/v1/baton/pairings)
PAIRING_ID=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pairing_id"])')
DISCOVERY=$(curl -s "http://127.0.0.1:8787/.well-known/baton/pair/$PAIRING_ID")
CONVERSATION_ID=$(printf '%s' "$DISCOVERY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["conversation"]["id"])')
DEVICE_PROOF=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
JOIN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"device_id\":\"simulator-1\",\"device_name\":\"Simulator\",\"device_proof\":\"$DEVICE_PROOF\"}" \
  "http://127.0.0.1:8787/v1/baton/pairings/$PAIRING_ID/requests")
REQUEST_ID=$(printf '%s' "$JOIN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["request_id"])')
# Open this in the existing web browser and click Allow (the mock has no login):
open "http://127.0.0.1:8787/v1/baton/pairings/$PAIRING_ID/approval"
TOKEN=$(curl -s -H "X-Baton-Device-Proof: $DEVICE_PROOF" \
  "http://127.0.0.1:8787/v1/baton/pairings/$PAIRING_ID/requests/$REQUEST_ID" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8787/v1/baton/conversations/CONVERSATION_ID
curl -N -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8787/v1/baton/conversations/$CONVERSATION_ID/events"
```

Send with `client_message_id` twice to verify idempotency. The first request
returns `201`; retries return the original message with `200`.

The conversation snapshot includes an atomic `event_cursor`:

```json
"event_cursor": { "id": "evt_…", "sequence": 12 }
```

Use its `id` as `Last-Event-ID` when opening `/events`; only later persisted
envelopes replay. Opening `/events` without that header is a new live-tail
subscription, not an implicit replay. One fixture SSE connection stays open
for five minutes by default (adjust with `--sse-live-seconds`), then the iOS
client reconnects with its cursor. The mock keeps a finite event log (64 by
default; adjustable with `--event-retention`), so an unknown or expired cursor
returns one standard `conversation.resync` SSE/Baton envelope instead of
replaying history from the beginning. Fetch another snapshot and continue from
its new cursor. The authenticated `POST /v1/baton/mock/events:retention` hook
exists solely for the smoke test; it is not part of Baton/1.0.

Cancellation is terminal at the Baton boundary: `POST .../runs/{run_id}:cancel`
returns `202` with `status: cancelled` and immediately emits exactly one
`message.completed` with `status: cancelled`, followed by `run.cancelled`.
An optional provider request may finish later, but its result is silently
discarded and cannot add deltas after that terminal sequence.

`POST /v1/baton/conversations/{conversation_id}:end` is likewise a shared
terminal boundary: it invalidates every conversation credential and outstanding
pairing, then broadcasts `conversation.closed` to already-connected clients.
The local Web console closes its EventSource rather than showing a reconnect
error. Creating a new pairing after an end starts a fresh fixture conversation
with a new ID and new event sequence.

The mock is single-process and memory-only. Streaming assistant placeholders
and accumulated text live in the same in-memory conversation state as completed
messages, so a snapshot during a run includes the current prefix plus
`active_runs`. The browser approval form is only a
test stand-in: a real Java integration must authorize pairing creation and
approval with its existing web session and CSRF rules. `device_proof` is an
opaque, high-entropy secret held by the mobile client; it must not be placed in
the QR URL or logged. A proof-bound status retry returns the same approved token
until the short pairing window expires, which makes credential delivery robust
to a dropped response while keeping the pairing single-device.

Run the repeatable smoke test while the server is running:

```sh
python3 mock_server/smoke_test.py
```

`mock_ttl_seconds` is accepted only by this fixture's create endpoint (60
seconds by default and at most 60) to make expiration tests repeatable. It is
not part of the Baton protocol. The local console automatically replaces an
expired QR code rather than extending this security window.

## Local diagnostics

The fixture emits safe, structured console logs for pairing and conversation
progress. They identify the route category, HTTP status, event type and message
or reply length; they never print message text, bearer tokens, device proofs or
dynamic pairing URLs. A successful chat turn produces this sequence:

```text
agent.input.accepted
agent.reply.requested
agent.reply.ready
agent.reply.completed
```

## Optional AG-UI adapter contract test

Keep this dependency isolated from the standard-library mock server:

```sh
python3 -m venv /tmp/baton-agui-venv
/tmp/baton-agui-venv/bin/pip install -r mock_server/requirements-agui.txt
/tmp/baton-agui-venv/bin/python mock_server/agui_adapter_test.py
```

The pinned dependency set currently uses `ag-ui-protocol==0.1.20`. The test
constructs and encodes official SDK fixtures, then verifies that
`MESSAGES_SNAPSHOT`, run lifecycle, and text stream events map to the existing
Baton `conversation.snapshot`, `run.*`, and `message.*` event types. Unknown
AG-UI events are recorded as adapter diagnostics and intentionally omitted from
Baton SSE.
