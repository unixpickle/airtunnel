import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'secure_channel.dart';

class ChatChunk {
  ChatChunk({this.responseId, this.delta, this.done = false});

  final String? responseId;
  final String? delta;
  final bool done;
}

class DnsChatClient {
  DnsChatClient({required this.rootDomain, required this.server})
      : _channel = EncryptedDnsClient(rootDomain: rootDomain, server: server);

  final String rootDomain;
  final String server;
  final EncryptedDnsClient _channel;

  static const int _typeChunk = 0x01;
  static const int _typePoll = 0x02;

  static const int _typeAck = 0x81;
  static const int _typeRespChunk = 0x82;
  static const int _typeError = 0x83;
  static const int _typeMeta = 0x84;

  static const int _flagDone = 0x01;
  static const int _flagPending = 0x02;

  static const int _msgIdSize = 8;
  static const int _offsetSize = 4;

  int get maxRequestBytes =>
      _clampMax(_channel.maxPlaintextRequestSize -
          (1 + _msgIdSize + _offsetSize + 4));

  int get maxResponseBytes =>
      _clampMax(_channel.maxPlaintextResponseSize -
          (1 + _msgIdSize + _offsetSize + 1));

  Stream<ChatChunk> sendMessage({
    required String apiKey,
    required String model,
    required String message,
    String? previousResponseId,
  }) async* {
    final msgId = _randomBytes(_msgIdSize);
    final request = _buildRequestJson(
      apiKey: apiKey,
      model: model,
      message: message,
      previousResponseId: previousResponseId,
    );
    await _sendChunked(msgId, request);

    var nextOffset = 0;
    var backoffIndex = 0;
    const backoff = [
      Duration(milliseconds: 500),
      Duration(seconds: 2),
      Duration(seconds: 5),
    ];

    while (true) {
      final response = await _poll(msgId, nextOffset);
      if (response is _PollError) {
        throw StateError(response.message);
      }
      if (response is _PollMeta) {
        yield ChatChunk(responseId: response.responseId);
        continue;
      }
      if (response is _PollPending) {
        await Future.delayed(backoff[backoffIndex]);
        if (backoffIndex < backoff.length - 1) {
          backoffIndex++;
        }
        continue;
      }
      if (response is _PollChunk) {
        backoffIndex = 0;
        if (response.data.isNotEmpty) {
          final text = utf8.decode(response.data, allowMalformed: true);
          yield ChatChunk(delta: text);
        }
        nextOffset += response.data.length;
        if (response.done) {
          yield ChatChunk(done: true);
          break;
        }
      }
    }
  }

  Uint8List _buildRequestJson({
    required String apiKey,
    required String model,
    required String message,
    String? previousResponseId,
  }) {
    final payload = <String, dynamic>{
      'api_key': apiKey,
      'model': model,
      'message': message,
      'previous_response_id': previousResponseId,
    };
    final jsonStr = jsonEncode(payload);
    return Uint8List.fromList(utf8.encode(jsonStr));
  }

  Future<void> _sendChunked(Uint8List msgId, Uint8List data) async {
    final maxChunk = maxRequestBytes;
    if (maxChunk <= 0) {
      throw StateError('DNS channel too small for request header');
    }
    var offset = 0;
    while (offset < data.length) {
      final end = (offset + maxChunk < data.length) ? offset + maxChunk : data.length;
      final chunk = data.sublist(offset, end);
      await _sendChunkWithRetry(msgId, offset, data.length, chunk);
      offset = end;
    }
  }

  Future<void> _sendChunkWithRetry(
      Uint8List msgId, int offset, int total, Uint8List chunk) async {
    const retries = 3;
    for (var attempt = 0; attempt < retries; attempt++) {
      final payload = _buildChunk(msgId, offset, total, chunk);
      final resp = await _channel.send(payload);
      if (resp.isEmpty) {
        continue;
      }
      final parsed = _parseResponse(resp);
      if (parsed is _Ack && parsed.offset == offset) {
        return;
      }
      if (parsed is _ErrorResp) {
        throw StateError(parsed.message);
      }
    }
    throw StateError('Failed to send chunk at offset $offset');
  }

  Uint8List _buildChunk(Uint8List msgId, int offset, int total, Uint8List data) {
    final buffer = BytesBuilder();
    buffer.addByte(_typeChunk);
    buffer.add(msgId);
    buffer.add(_u32(offset));
    buffer.add(_u32(total));
    buffer.add(data);
    return buffer.takeBytes();
  }

  Future<_PollResult> _poll(Uint8List msgId, int nextOffset) async {
    final buffer = BytesBuilder();
    buffer.addByte(_typePoll);
    buffer.add(msgId);
    buffer.add(_u32(nextOffset));
    final resp = await _channel.send(buffer.takeBytes());
    if (resp.isEmpty) {
      return _PollPending();
    }
    final parsed = _parseResponse(resp);
    if (parsed is _ErrorResp) {
      return _PollError(parsed.message);
    }
    if (parsed is _MetaResp) {
      return _PollMeta(parsed.responseId);
    }
    if (parsed is _ChunkResp) {
      if (parsed.pending) {
        return _PollPending();
      }
      return _PollChunk(parsed.data, parsed.done);
    }
    return _PollPending();
  }

  _ParsedResp _parseResponse(Uint8List resp) {
    final type = resp[0];
    if (type == _typeAck) {
      if (resp.length < 1 + _msgIdSize + _offsetSize) {
        return _ErrorResp('Malformed ack');
      }
      final offset = _readU32(resp, 1 + _msgIdSize);
      return _Ack(offset);
    }
    if (type == _typeError) {
      if (resp.length < 1 + _msgIdSize + 1) {
        return _ErrorResp('Unknown error');
      }
      final msg = utf8.decode(resp.sublist(1 + _msgIdSize + 1), allowMalformed: true);
      return _ErrorResp(msg);
    }
    if (type == _typeMeta) {
      if (resp.length < 1 + _msgIdSize + 2) {
        return _ErrorResp('Malformed meta');
      }
      final len = _readU16(resp, 1 + _msgIdSize);
      final start = 1 + _msgIdSize + 2;
      final end = start + len;
      if (end > resp.length) {
        return _ErrorResp('Malformed meta');
      }
      final responseId = utf8.decode(resp.sublist(start, end));
      return _MetaResp(responseId);
    }
    if (type == _typeRespChunk) {
      if (resp.length < 1 + _msgIdSize + _offsetSize + 1) {
        return _ErrorResp('Malformed response chunk');
      }
      final flags = resp[1 + _msgIdSize + _offsetSize];
      final data = resp.sublist(1 + _msgIdSize + _offsetSize + 1);
      final done = (flags & _flagDone) != 0;
      final pending = (flags & _flagPending) != 0;
      return _ChunkResp(data, done: done, pending: pending);
    }
    return _ErrorResp('Unknown response type');
  }
}

class _ParsedResp {}

class _Ack extends _ParsedResp {
  _Ack(this.offset);

  final int offset;
}

class _ErrorResp extends _ParsedResp {
  _ErrorResp(this.message);

  final String message;
}

class _MetaResp extends _ParsedResp {
  _MetaResp(this.responseId);

  final String responseId;
}

class _ChunkResp extends _ParsedResp {
  _ChunkResp(this.data, {required this.done, required this.pending});

  final Uint8List data;
  final bool done;
  final bool pending;
}

class _PollResult {}

class _PollChunk extends _PollResult {
  _PollChunk(this.data, this.done);

  final Uint8List data;
  final bool done;
}

class _PollPending extends _PollResult {}

class _PollError extends _PollResult {
  _PollError(this.message);

  final String message;
}

class _PollMeta extends _PollResult {
  _PollMeta(this.responseId);

  final String responseId;
}

Uint8List _u32(int value) {
  final b = ByteData(4);
  b.setUint32(0, value, Endian.big);
  return b.buffer.asUint8List();
}

int _readU32(Uint8List data, int offset) {
  final b = ByteData.sublistView(data, offset, offset + 4);
  return b.getUint32(0, Endian.big);
}

int _readU16(Uint8List data, int offset) {
  final b = ByteData.sublistView(data, offset, offset + 2);
  return b.getUint16(0, Endian.big);
}

Uint8List _randomBytes(int length) {
  final rand = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = rand.nextInt(256);
  }
  return bytes;
}

int _clampMax(int value) {
  if (value < 0) {
    return 0;
  }
  return value;
}
