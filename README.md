# Airtunnel DNS (Byte Echo)

A Flutter app and Go DNS server that exchange raw bytes over DNS. The client
encodes bytes into subdomains under a delegated root domain, and the server
returns the response bytes inside a TXT record. The current handler is an echo.

## Features
- Pure Dart UDP client; no FFI/native libraries.
- Go DNS server with a simple byte handler.
- Size-safe encoding with computed max request/response sizes.
- Auto-detects system DNS servers on Android, iOS, macOS, and Linux.

## Protocol overview
- Client encodes payload with base32 (DNS-safe chars only).
- Encoded text is split into 63-character labels and appended to the root domain.
- DNS query type is TXT.
- Server decodes the QNAME payload, runs the handler, and returns a TXT answer
  containing base32-encoded response bytes.

## Flutter app
Run on Android or desktop:

```sh
cd /Users/alex/code/github.com/unixpickle/airtunnel
/Users/alex/develop/flutter/bin/flutter run -d <device>
```

DNS server auto-detection:
- Android: `ConnectivityManager` + `LinkProperties`.
- iOS/macOS: Network framework (`NWPathMonitor`).
- Linux: `/etc/resolv.conf`.

The UI lets you set:
- Root domain (delegated zone like `ns.aqnichol.com`).
- DNS server (auto-filled if detected).
- Text to send.

## Go DNS server
Build and run:

```sh
cd /Users/alex/code/github.com/unixpickle/airtunnel/go

go mod tidy

go run . -root ns.aqnichol.com -addr :5353
```

Flags:
- `-root`: delegated root domain.
- `-addr`: UDP listen address.

The server logs computed max request/response sizes at startup.

## Notes
- Responses are conservative and fit into a single TXT string.
- UDP DNS size limits still apply; for larger payloads, add chunking or TCP.
