import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

class DnsByteClient {
  DnsByteClient({required this.rootDomain, this.server = '1.1.1.1:53'})
      : maxRequestSize = _maxRequestSize(rootDomain),
        maxResponseSize = _maxResponseSize();

  final String rootDomain;
  final String server;
  final int maxRequestSize;
  final int maxResponseSize;
  io.RawDatagramSocket? _socket;
  StreamController<Uint8List>? _incoming;
  Future<io.RawDatagramSocket>? _socketReady;

  Future<Uint8List> send(Uint8List payload, {int timeoutMs = 3000}) async {
    if (payload.length > maxRequestSize) {
      throw ArgumentError(
          'Payload too large: ${payload.length} > $maxRequestSize');
    }

    final queryName = _encodeToName(payload, rootDomain);
    final query = _buildQuery(queryName);

    final parsed = _parseServer(server);
    final serverHost = parsed.host;
    final serverPort = parsed.port;

    final serverAddress = await _resolveServer(serverHost);
    final socket = await _ensureSocket();

    const backoff = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 8),
    ];

    Object? lastError;
    for (var attempt = 0; attempt < backoff.length; attempt++) {
      socket.send(query, serverAddress, serverPort);
      final result = await _awaitResponse(queryName, backoff[attempt]);
      if (result.response != null) {
        final resp = result.response!;
        if (resp.length > maxResponseSize) {
          throw StateError(
              'Response too large: ${resp.length} > $maxResponseSize');
        }
        return resp;
      }
      if (result.error != null) {
        lastError = result.error;
      }
    }
    if (lastError != null) {
      throw StateError('DNS request failed: $lastError');
    }
    throw StateError('DNS request timed out (no response).');
  }

  Future<_AwaitResult> _awaitResponse(
      String expectedName, Duration timeout) async {
    final completer = Completer<_AwaitResult>();
    Object? lastError;
    Timer? timer;
    late final StreamSubscription sub;

    sub = _incoming!.stream.listen((data) {
      final decoded = _tryDecodeResponse(data, expectedName);
      if (decoded.response != null) {
        if (!completer.isCompleted) {
          completer.complete(_AwaitResult(response: decoded.response));
        }
        return;
      }
      if (decoded.error != null) {
        lastError = decoded.error;
      }
    });

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(_AwaitResult(error: lastError));
      }
    });

    final result = await completer.future;
    await sub.cancel();
    timer.cancel();
    return result;
  }

  Future<io.RawDatagramSocket> _ensureSocket() async {
    if (_socket != null) {
      return _socket!;
    }
    _socketReady ??=
        io.RawDatagramSocket.bind(io.InternetAddress.anyIPv4, 0).then((socket) {
      _socket = socket;
      _incoming ??= StreamController<Uint8List>.broadcast();
      socket.listen((event) {
        if (event == io.RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            _incoming!.add(Uint8List.fromList(datagram.data));
          }
        }
      });
      return socket;
    });
    return _socketReady!;
  }
}

class _ParsedServer {
  _ParsedServer(this.host, this.port);

  final String host;
  final int port;
}

_ParsedServer _parseServer(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return _ParsedServer('1.1.1.1', 53);
  }
  if (trimmed.startsWith('[')) {
    final end = trimmed.indexOf(']');
    if (end > 0) {
      final host = trimmed.substring(1, end);
      var port = 53;
      if (end + 1 < trimmed.length && trimmed[end + 1] == ':') {
        port = int.tryParse(trimmed.substring(end + 2)) ?? 53;
      }
      return _ParsedServer(host, port);
    }
  }
  final first = trimmed.indexOf(':');
  final last = trimmed.lastIndexOf(':');
  if (first != -1 && first == last) {
    final host = trimmed.substring(0, first);
    final port = int.tryParse(trimmed.substring(first + 1)) ?? 53;
    return _ParsedServer(host, port);
  }
  return _ParsedServer(trimmed, 53);
}

Future<io.InternetAddress> _resolveServer(String host) async {
  final direct = io.InternetAddress.tryParse(host);
  if (direct != null) {
    return direct;
  }
  final results = await io.InternetAddress.lookup(host);
  if (results.isEmpty) {
    throw io.SocketException('Failed to resolve server $host');
  }
  return results.first;
}

class _AwaitResult {
  _AwaitResult({this.response, this.error});

  final Uint8List? response;
  final Object? error;
}

Uint8List _buildQuery(String name) {
  final builder = BytesBuilder();
  final id = Random().nextInt(0x10000);

  builder.addByte((id >> 8) & 0xff);
  builder.addByte(id & 0xff);
  builder.addByte(0x01); // recursion desired
  builder.addByte(0x00);
  builder.addByte(0x00);
  builder.addByte(0x01); // QDCOUNT
  builder.addByte(0x00);
  builder.addByte(0x00); // ANCOUNT
  builder.addByte(0x00);
  builder.addByte(0x00); // NSCOUNT
  builder.addByte(0x00);
  builder.addByte(0x00); // ARCOUNT

  builder.add(_encodeName(name));
  builder.addByte(0x00);
  builder.addByte(0x10); // QTYPE TXT
  builder.addByte(0x00);
  builder.addByte(0x01); // QCLASS IN

  return builder.takeBytes();
}

class _DecodeResult {
  _DecodeResult({this.response, this.error});

  final Uint8List? response;
  final Object? error;
}

_DecodeResult _tryDecodeResponse(Uint8List data, String expectedName) {
  if (data.length < 12) {
    return _DecodeResult(error: 'DNS response too short');
  }

  final rcode = data[3] & 0x0f;
  if (rcode != 0) {
    return _DecodeResult(
        error: 'DNS error: ${_rcodeName(rcode)} (rcode=$rcode)');
  }

  final qdCount = (data[4] << 8) | data[5];
  final anCount = (data[6] << 8) | data[7];
  var offset = 12;

  for (var i = 0; i < qdCount; i++) {
    offset = _skipName(data, offset);
    offset += 4;
    if (offset > data.length) {
      return _DecodeResult(error: 'DNS response truncated');
    }
  }

  var sawMismatch = false;
  for (var i = 0; i < anCount; i++) {
    final name = _readName(data, offset);
    offset = name.nextOffset;
    if (offset + 10 > data.length) {
      return _DecodeResult(error: 'DNS answer truncated');
    }
    final type = (data[offset] << 8) | data[offset + 1];
    final rdLength = (data[offset + 8] << 8) | data[offset + 9];
    offset += 10;
    if (offset + rdLength > data.length) {
      return _DecodeResult(error: 'DNS rdata truncated');
    }

    if (type == 16) {
      if (name.name != expectedName) {
        sawMismatch = true;
      } else {
        final rdata = data.sublist(offset, offset + rdLength);
        final text = _parseTxt(rdata);
        return _DecodeResult(response: _decodeBase32(text));
      }
    }
    offset += rdLength;
  }

  if (sawMismatch) {
    return _DecodeResult(error: 'DNS name mismatch (expected $expectedName)');
  }
  return _DecodeResult(
      error: 'No TXT response (qd=$qdCount an=$anCount name=$expectedName)');
}

String _rcodeName(int rcode) {
  switch (rcode) {
    case 1:
      return 'FORMERR';
    case 2:
      return 'SERVFAIL';
    case 3:
      return 'NXDOMAIN';
    case 4:
      return 'NOTIMP';
    case 5:
      return 'REFUSED';
    default:
      return 'UNKNOWN';
  }
}

String _parseTxt(Uint8List rdata) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < rdata.length) {
    final len = rdata[i];
    i++;
    if (i + len > rdata.length) {
      throw FormatException('Invalid TXT rdata');
    }
    buffer.write(utf8.decode(rdata.sublist(i, i + len)));
    i += len;
  }
  return buffer.toString();
}

class _NameRead {
  _NameRead(this.name, this.nextOffset);

  final String name;
  final int nextOffset;
}

_NameRead _readName(Uint8List data, int offset) {
  final labels = <String>[];
  var i = offset;
  var jumped = false;
  var jumpOffset = 0;

  while (i < data.length) {
    final len = data[i];
    if (len == 0) {
      i++;
      break;
    }
    if ((len & 0xc0) == 0xc0) {
      if (i + 1 >= data.length) {
        throw FormatException('Name pointer truncated');
      }
      final pointer = ((len & 0x3f) << 8) | data[i + 1];
      if (!jumped) {
        jumpOffset = i + 2;
      }
      i = pointer;
      jumped = true;
      continue;
    }
    i++;
    if (i + len > data.length) {
      throw FormatException('Name label truncated');
    }
    labels.add(utf8.decode(data.sublist(i, i + len)));
    i += len;
  }

  final next = jumped ? jumpOffset : i;
  return _NameRead(labels.join('.'), next);
}

int _skipName(Uint8List data, int offset) {
  var i = offset;
  while (i < data.length) {
    final len = data[i];
    if (len == 0) {
      return i + 1;
    }
    if ((len & 0xc0) == 0xc0) {
      return i + 2;
    }
    i += len + 1;
  }
  throw FormatException('Name truncated');
}

Uint8List _encodeName(String name) {
  final builder = BytesBuilder();
  for (final label in name.split('.')) {
    final bytes = utf8.encode(label);
    if (bytes.length > 63) {
      throw FormatException('Label too long: $label');
    }
    builder.addByte(bytes.length);
    builder.add(bytes);
  }
  builder.addByte(0x00);
  return builder.takeBytes();
}

String _encodeToName(Uint8List data, String root) {
  final encoded = _encodeBase32(data);
  final labels = <String>[];
  for (var i = 0; i < encoded.length; i += 63) {
    final end = (i + 63 < encoded.length) ? i + 63 : encoded.length;
    labels.add(encoded.substring(i, end));
  }
  final rootNorm =
      root.endsWith('.') ? root.substring(0, root.length - 1) : root;
  if (labels.isEmpty) {
    return rootNorm;
  }
  return '${labels.join('.')}.${rootNorm}';
}

String _encodeBase32(Uint8List data) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  final buffer = StringBuffer();
  var value = 0;
  var bits = 0;

  for (final byte in data) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      final idx = (value >> (bits - 5)) & 0x1f;
      buffer.write(alphabet[idx]);
      bits -= 5;
    }
  }
  if (bits > 0) {
    final idx = (value << (5 - bits)) & 0x1f;
    buffer.write(alphabet[idx]);
  }
  return buffer.toString();
}

Uint8List _decodeBase32(String text) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  final map = <int, int>{};
  for (var i = 0; i < alphabet.length; i++) {
    map[alphabet.codeUnitAt(i)] = i;
  }

  var value = 0;
  var bits = 0;
  final bytes = <int>[];
  for (final unit in text.toLowerCase().codeUnits) {
    final v = map[unit];
    if (v == null) {
      throw FormatException('Invalid base32 character');
    }
    value = (value << 5) | v;
    bits += 5;
    if (bits >= 8) {
      final b = (value >> (bits - 8)) & 0xff;
      bytes.add(b);
      bits -= 8;
    }
  }
  return Uint8List.fromList(bytes);
}

int _maxRequestSize(String root) {
  final maxChars = _maxEncodedChars(root);
  return _maxBytesForChars(maxChars);
}

int _maxResponseSize() {
  return _maxBytesForChars(255);
}

int _maxEncodedChars(String root) {
  final rootNorm =
      root.endsWith('.') ? root.substring(0, root.length - 1) : root;
  if (rootNorm.isEmpty) {
    return 0;
  }
  const maxTotal = 253;
  var best = 0;
  for (var n = 0; n <= maxTotal; n++) {
    final labels = (n + 62) ~/ 63;
    final dots = labels > 1 ? labels - 1 : 0;
    final total = n + dots + 1 + rootNorm.length;
    if (total <= maxTotal) {
      best = n;
    }
  }
  return best;
}

int _maxBytesForChars(int maxChars) {
  var best = 0;
  for (var b = 0; b <= 2048; b++) {
    final enc = (b * 8 + 4) ~/ 5;
    if (enc <= maxChars) {
      best = b;
    }
  }
  return best;
}
