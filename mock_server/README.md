# Local Baton Mock Server

Dependency-free development fixture for the V1 Companion Profile. It stores
one conversation in memory and generates deterministic streaming replies. It
does not call LM Studio and never reads `LM_STUDIO_KEY`.

`agui_adapter.py` is a separately installed, optional reference boundary. It
uses the official AG-UI Python event models to translate the narrow V1 Agent
event subset into existing Baton event drafts. It does not add AG-UI event names
to the iOS wire format and does not make this mock an Agent framework.

## Start

```sh
python3 mock_server/mock_server.py
```

The default address is `http://127.0.0.1:8787`. For an iOS Simulator, this
address is reachable as-is. HTTP is intentionally allowed only for this local
fixture; a real deployment must use HTTPS.

## Pair, approve in the browser, and call the conversation API

```sh
PAIR=$(curl -s -X POST http://127.0.0.1:8787/v1/baton/pairings)
PAIRING_ID=$(printf '%s' "$PAIR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pairing_id"])')
curl -s "http://127.0.0.1:8787/.well-known/baton/pair/$PAIRING_ID"
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
  http://127.0.0.1:8787/v1/baton/conversations/conv_local
curl -N -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8787/v1/baton/conversations/conv_local/events
```

Send with `client_message_id` twice to verify idempotency. The first request
returns `201`; retries return the original message with `200`.

The conversation snapshot includes an atomic `event_cursor`:

```json
"event_cursor": { "id": "evt_…", "sequence": 12 }
```

Use its `id` as `Last-Event-ID` when opening `/events`; only later persisted
envelopes replay. Opening `/events` without that header is a new live-tail
subscription, not an implicit replay. The mock keeps a finite event log (64 by
default; adjustable with `--event-retention`), so an unknown or expired cursor
returns one standard `conversation.resync` SSE/Baton envelope instead of
replaying history from the beginning. Fetch another snapshot and continue from
its new cursor. The authenticated `POST /v1/baton/mock/events:retention` hook
exists solely for the smoke test; it is not part of Baton/1.0.

Cancellation is asynchronous: `POST .../runs/{run_id}:cancel` first returns
`202 cancellation_requested`. The stream then emits exactly one terminal
`message.completed` with `status: cancelled`, followed by `run.cancelled`.

The mock is single-process and memory-only. The browser approval form is only a
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

`mock_ttl_seconds` is accepted only by this fixture's create endpoint to make
the expiration test instantaneous. It is not part of the Baton protocol.

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
