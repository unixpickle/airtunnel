# Airtunnel DNS (Byte Echo + Signed Session)

A Flutter app and Go DNS server that exchange raw bytes over DNS. The client
encodes bytes into subdomains under a delegated root domain, and the server
returns response bytes inside a TXT record. A signed handshake establishes a
session key used for symmetric encryption.

## Features
- Pure Dart UDP client; no FFI/native libraries.
- Go DNS server with a simple byte handler (echo).
- Size-safe encoding with computed max request/response sizes.
- Auto-detects system DNS servers on Android, iOS, macOS, and Linux.
- Signed handshake and symmetric encryption for payloads.

## Security model
The app ships with the server **public** key. The server signs the handshake
response that includes a session ID and symmetric key. The client verifies the
signature before accepting the key.

Note: Because the symmetric key is sent in the clear (but signed), this provides
**authenticity** (prevents MITM) but **not confidentiality** against passive
observers. If you want confidentiality against passive eavesdroppers, switch to
an ECDH-based handshake.

## Protocol overview
- Client encodes payload with base32 (DNS-safe chars only).
- Encoded text is split into 63-character labels and appended to the root domain.
- DNS query type is TXT.
- Server decodes the QNAME payload, runs the handler, and returns a TXT answer
  containing base32-encoded response bytes.

### Handshake
- Client sends: `[version=1][type=1][client_nonce(8)]`
- Server responds: `[version=1][type=2][session_id(8)][key(32)][sig(64)]`
- Signature covers: `version|type|session_id|key|client_nonce` (ed25519).

### Encrypted messages
- Client sends: `[session_id(8)][nonce(12)][ciphertext+tag]`
- Server responds in the same format.
- AES-256-GCM with AAD = session_id.
 - Max plaintext sizes are reduced by the session id, nonce, and GCM tag.

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
- Root domain (delegated zone like `someserver.google.com`).
- DNS server (auto-filled if detected).
- Text to send.

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
- Responses are conservative and fit into a single TXT string.
- UDP DNS size limits still apply; for larger payloads, add chunking or TCP.
