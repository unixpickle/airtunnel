# AirTunnel

A Flutter chat app and Go DNS server that send ChatGPT-style messages entirely
through DNS. Messages are encrypted, and MITM attacks are prevented using a key
pair that is generated beforehand and baked into the app.

# Usage

## Key generation

Generate a new key pair and update the Dart public key:

```sh
./scripts/gen_keys.sh
```

This writes:
- `keys/server_private.pem` (ignored by git)
- `keys/server_public.pem`
- `lib/public_key.dart` (embedded in the app)

## Go DNS server

Build and run:

```sh
cd go
go mod tidy
go run . -root someserver.mydomain.com -addr :53 -key ../keys/server_private.pem
```

Flags:
- `-root`: delegated root domain.
- `-addr`: UDP listen address.
- `-key`: ed25519 private key PEM.

## Flutter app

Run on Android or desktop:

```sh
flutter run -d <device>
```

The UI lets you set:
- OpenAI API key (stored locally).
- Root domain (delegated zone like `someserver.google.com`).
- DNS server (auto-filled if detected).
