# Airtunnel DNS Chat

A Flutter chat app and Go DNS server that send ChatGPT-style messages entirely
through DNS. The client chunks requests, retries with ACKs, and polls for
chunked responses. Messages are authenticated and encrypted at the session
layer.

## Features
- Pure Dart UDP client; no FFI/native libraries.
- Go DNS server that streams OpenAI Responses API output over DNS.
- Chunked upload with ACK + retries.
- Chunked response with polling and backoff.
- Auto-detects system DNS servers on Android, iOS, macOS, and Linux.
- Signed handshake and symmetric encryption for payloads.

## Security model
The app ships with the server **public** key. The server signs the handshake
response that includes a session ID and symmetric key. The client verifies the
signature before accepting the key. Payloads are encrypted with AES-256-GCM.

Note: Because the symmetric key is sent in the clear (but signed), this provides
**authenticity** (prevents MITM) but **not confidentiality** against passive
observers. If you want confidentiality against passive eavesdroppers, switch to
an ECDH-based handshake.

## Protocol overview
### DNS transport
- Client encodes payload with base32 (DNS-safe chars only).
- Encoded text is split into 63-character labels and appended to the root domain.
- DNS query type is TXT.
- Server decodes the QNAME payload, runs the handler, and returns a TXT answer
  containing base32-encoded response bytes.

### Session handshake
- Client sends: `[version=1][type=1][client_nonce(8)]`
- Server responds: `[version=1][type=2][session_id(8)][key(32)][sig(64)]`
- Signature covers: `version|type|session_id|key|client_nonce` (ed25519).

### Encrypted messages
- Client sends: `[session_id(8)][nonce(12)][ciphertext+tag]`
- Server responds in the same format.
- AES-256-GCM with AAD = session_id.
- Max plaintext sizes are reduced by the session id, nonce, and GCM tag.

### Chat protocol (inside encrypted payloads)
- Upload chunk: `type=0x01 | msg_id(8) | offset(4) | total_len(4) | data`
- Poll: `type=0x02 | msg_id(8) | next_offset(4)`
- Ack: `type=0x81 | msg_id(8) | offset(4)`
- Response chunk: `type=0x82 | msg_id(8) | offset(4) | flags(1) | data`
  - `flags`: bit0=done, bit1=pending, bit2=error
- Meta: `type=0x84 | msg_id(8) | response_id_len(2) | response_id`

Request JSON:
```json
{"api_key":"sk-...","model":"gpt-4o-mini","message":"Hello","previous_response_id":"..."}
```

## Flutter app
Run on Android or desktop:

```sh
cd /Users/alex/code/github.com/unixpickle/airtunnel
/Users/alex/develop/flutter/bin/flutter run -d <device>
```

DNS server auto-detection:
- Android: `ConnectivityManager` + `LinkProperties`.
- iOS: Network framework (`NWPathMonitor`).
- macOS/Linux: `/etc/resolv.conf`.

The UI lets you set:
- OpenAI API key (stored locally).
- Root domain (delegated zone like `someserver.google.com`).
- DNS server (auto-filled if detected).

## Key generation
Generate a new keypair and update the Dart public key:

```sh
/Users/alex/code/github.com/unixpickle/airtunnel/scripts/gen_keys.sh
```

This writes:
- `keys/server_private.pem` (ignored by git)
- `keys/server_public.pem`
- `lib/public_key.dart` (embedded in the app)

## Go DNS server
Build and run:

```sh
cd /Users/alex/code/github.com/unixpickle/airtunnel/go

go mod tidy

go run . -root someserver.google.com -addr :5353 -key ../keys/server_private.pem
```

Flags:
- `-root`: delegated root domain.
- `-addr`: UDP listen address.
- `-key`: ed25519 private key PEM.

The server logs computed max request/response sizes at startup.

## Notes
- Responses are conservative and fit into a single TXT string per DNS response.
- UDP DNS size limits still apply; for larger payloads, add chunking or TCP.
