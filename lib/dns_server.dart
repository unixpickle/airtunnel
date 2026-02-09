import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class DnsServerResolver {
  static const _channel = MethodChannel('dns_server');

  Future<List<String>> getServers() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final result = await _channel.invokeMethod<List<dynamic>>('getDnsServers');
      if (result == null) {
        return const [];
      }
      return result.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }

    if (Platform.isLinux || Platform.isMacOS) {
      return _parseResolvConf();
    }

    return const [];
  }

  List<String> _parseResolvConf() {
    try {
      final file = File('/etc/resolv.conf');
      if (!file.existsSync()) {
        return const [];
      }
      final lines = file.readAsLinesSync();
      final servers = <String>[];
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('nameserver')) {
          final parts = trimmed.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            servers.add(parts[1]);
          }
        }
      }
      return servers;
    } catch (_) {
      return const [];
    }
  }
}
