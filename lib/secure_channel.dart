import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'dns_ffi.dart';
import 'public_key.dart';

class EncryptedDnsClient {
  EncryptedDnsClient({required this.rootDomain, this.server = '1.1.1.1:53'})
      : _inner = DnsByteClient(rootDomain: rootDomain, server: server);

  final String rootDomain;
  final String server;
  final DnsByteClient _inner;

  Uint8List? _sessionId;
  SecretKey? _sessionKey;
  DateTime? _sessionLastUsed;

  static const int _version = 1;
  static const int _typeHandshake = 1;
  static const int _typeHandshakeResp = 2;

  static const int _sessionIdSize = 8;
  static const int _nonceSize = 12;
  static const int _tagSize = 16;
  static const int _keySize = 32;
  static const int _signatureSize = 64;
  static const int _clientNonceSize = 8;
  static const int _x25519KeySize = 32;

  int get maxPlaintextRequestSize =>
      _clampMax(_inner.maxRequestSize - _sessionIdSize - _nonceSize - _tagSize);

  int get maxPlaintextResponseSize =>
      _clampMax(_inner.maxResponseSize - _sessionIdSize - _nonceSize - _tagSize);

  Future<Uint8List> send(Uint8List payload, {int timeoutMs = 3000}) async {
    if (payload.length > maxPlaintextRequestSize) {
      throw ArgumentError(
          'Payload too large: ${payload.length} > $maxPlaintextRequestSize');
    }

    await _ensureSession(timeoutMs);
    _sessionLastUsed = DateTime.now();
    final sessionId = _sessionId!;
    final key = _sessionKey!;

    final nonce = _randomBytes(_nonceSize);
    final encrypted = await _encrypt(key, nonce, payload, sessionId);

    final message = BytesBuilder();
    message.add(sessionId);
    message.add(nonce);
    message.add(encrypted);

    final respBytes = await _inner.send(message.takeBytes(), timeoutMs: timeoutMs);
    if (respBytes.isEmpty) {
      return Uint8List(0);
    }

    final decrypted = await _decryptMessage(respBytes, sessionId, key);
    _sessionLastUsed = DateTime.now();
    if (decrypted.length > maxPlaintextResponseSize) {
      throw StateError('Response too large: ${decrypted.length} > $maxPlaintextResponseSize');
    }
    return decrypted;
  }

  Future<void> _ensureSession(int timeoutMs) async {
    if (serverPublicKeyBase64.isEmpty) {
      throw StateError('Missing public key. Run scripts/gen_keys.sh.');
    }
    if (_sessionId != null && _sessionKey != null) {
      if (_sessionLastUsed == null ||
          DateTime.now().difference(_sessionLastUsed!) >
              const Duration(days: 1)) {
        _sessionId = null;
        _sessionKey = null;
      } else {
        return;
      }
    }

    final publicKey = SimplePublicKey(
      base64.decode(serverPublicKeyBase64),
      type: KeyPairType.ed25519,
    );
    final ed25519 = Ed25519();
    final x25519 = X25519();

    const backoff = [
      Duration(milliseconds: 200),
      Duration(milliseconds: 500),
      Duration(seconds: 1),
    ];

    for (var attempt = 0; attempt < backoff.length; attempt++) {
      try {
        final clientNonce = _randomBytes(_clientNonceSize);
        final clientKeyPair = await x25519.newKeyPair();
        final clientPub = await clientKeyPair.extractPublicKey();
        final clientPubBytes = Uint8List.fromList(clientPub.bytes);

        final req = Uint8List(1 + 1 + _x25519KeySize + _clientNonceSize);
        req[0] = _version;
        req[1] = _typeHandshake;
        req.setRange(2, 2 + _x25519KeySize, clientPubBytes);
        req.setRange(2 + _x25519KeySize, req.length, clientNonce);

        final resp = await _inner.send(req, timeoutMs: timeoutMs);
        if (resp.length !=
            1 + 1 + _sessionIdSize + _x25519KeySize + _signatureSize) {
          throw StateError('Invalid handshake response length');
        }
        if (resp[0] != _version || resp[1] != _typeHandshakeResp) {
          throw StateError('Invalid handshake response');
        }

        final sessionId = resp.sublist(2, 2 + _sessionIdSize);
        final serverPub = resp.sublist(
            2 + _sessionIdSize, 2 + _sessionIdSize + _x25519KeySize);
        final signature =
            resp.sublist(2 + _sessionIdSize + _x25519KeySize);

        final signed = BytesBuilder();
        signed.addByte(_version);
        signed.addByte(_typeHandshakeResp);
        signed.add(sessionId);
        signed.add(serverPub);
        signed.add(clientPubBytes);
        signed.add(clientNonce);

        final ok = await ed25519.verify(
          signed.takeBytes(),
          signature: Signature(signature, publicKey: publicKey),
        );
        if (!ok) {
          throw StateError('Invalid server signature');
        }

        final shared = await x25519.sharedSecretKey(
          keyPair: clientKeyPair,
          remotePublicKey:
              SimplePublicKey(serverPub, type: KeyPairType.x25519),
        );
        final derived = await _deriveSessionKey(
          shared,
          clientNonce,
          sessionId,
          clientPubBytes,
          serverPub,
          _keySize,
        );

        _sessionId = sessionId;
        _sessionKey = derived;
        return;
      } catch (_) {
        if (attempt == backoff.length - 1) {
          rethrow;
        }
        await Future.delayed(backoff[attempt]);
      }
    }
  }

  Future<Uint8List> _decryptMessage(
      Uint8List message, Uint8List sessionId, SecretKey key) async {
    if (message.length < _sessionIdSize + _nonceSize + _tagSize) {
      throw StateError('Encrypted response too short');
    }

    final respSession = message.sublist(0, _sessionIdSize);
    if (!_bytesEqual(respSession, sessionId)) {
      throw StateError('Session ID mismatch');
    }
    final nonce = message.sublist(_sessionIdSize, _sessionIdSize + _nonceSize);
    final ciphertext = message.sublist(_sessionIdSize + _nonceSize);

    return _decrypt(key, nonce, ciphertext, sessionId);
  }

  Future<Uint8List> _encrypt(
      SecretKey key, Uint8List nonce, Uint8List plaintext, Uint8List aad) async {
    final algo = AesGcm.with256bits();
    final secretBox = await algo.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    return Uint8List.fromList(secretBox.cipherText + secretBox.mac.bytes);
  }

  Future<Uint8List> _decrypt(
      SecretKey key, Uint8List nonce, Uint8List ciphertext, Uint8List aad) async {
    final algo = AesGcm.with256bits();
    if (ciphertext.length < _tagSize) {
      throw StateError('Ciphertext too short');
    }
    final ct = ciphertext.sublist(0, ciphertext.length - _tagSize);
    final tag = ciphertext.sublist(ciphertext.length - _tagSize);
    final box = SecretBox(ct, nonce: nonce, mac: Mac(tag));
    final plain = await algo.decrypt(
      box,
      secretKey: key,
      aad: aad,
    );
    return Uint8List.fromList(plain);
  }
}

Future<SecretKey> _deriveSessionKey(
  SecretKey shared,
  Uint8List clientNonce,
  Uint8List sessionId,
  Uint8List clientPub,
  Uint8List serverPub,
  int keySize,
) async {
  final info = BytesBuilder();
  info.add(utf8.encode('airtunnel/handshake'));
  info.add(sessionId);
  info.add(clientPub);
  info.add(serverPub);

  final hkdf = Hkdf(
    hmac: Hmac.sha256(),
    outputLength: keySize,
  );
  return hkdf.deriveKey(
    secretKey: shared,
    nonce: clientNonce,
    info: info.takeBytes(),
  );
}

Uint8List _randomBytes(int length) {
  final rand = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = rand.nextInt(256);
  }
  return bytes;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

int _clampMax(int value) {
  if (value < 0) {
    return 0;
  }
  return value;
}
