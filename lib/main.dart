import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'dns_ffi.dart';
import 'dns_server.dart';

void main() {
  runApp(const DnsApp());
}

class DnsApp extends StatelessWidget {
  const DnsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Raw DNS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const DnsHome(),
    );
  }
}

class DnsHome extends StatefulWidget {
  const DnsHome({super.key});

  @override
  State<DnsHome> createState() => _DnsHomeState();
}

class _DnsHomeState extends State<DnsHome> {
  final _rootController = TextEditingController(text: 'ns.aqnichol.com');
  final _serverController = TextEditingController();
  final _sendController = TextEditingController(text: 'hello');
  Uint8List? _response;
  String? _responseText;
  String? _error;
  bool _loading = false;
  List<String> _detectedServers = const [];

  @override
  void initState() {
    super.initState();
    _loadDnsServers();
  }

  Future<void> _loadDnsServers() async {
    final resolver = DnsServerResolver();
    final servers = await resolver.getServers();
    if (!mounted) {
      return;
    }
    setState(() {
      _detectedServers = servers;
      if (_serverController.text.trim().isEmpty && servers.isNotEmpty) {
        _serverController.text = '${servers.first}:53';
      }
    });
  }

  Future<void> _runQuery() async {
    final root = _rootController.text.trim();
    final server = _serverController.text.trim();
    final text = _sendController.text;
    if (root.isEmpty) {
      setState(() {
        _error = 'Enter a root domain.';
        _response = null;
        _responseText = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _response = null;
      _responseText = null;
    });

    try {
      final chosenServer = server.isEmpty
          ? (_detectedServers.isNotEmpty ? '${_detectedServers.first}:53' : '1.1.1.1:53')
          : server;
      final client = DnsByteClient(rootDomain: root, server: chosenServer);
      final payload = Uint8List.fromList(utf8.encode(text));
      final bytes = await client.send(payload);
      setState(() {
        _response = bytes;
        if (bytes.isEmpty) {
          _error = 'No response (or timeout).';
        } else {
          _responseText = utf8.decode(bytes, allowMalformed: true);
        }
      });
    } catch (e) {
      setState(() {
        _error = 'Query failed: $e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final responseText = _response == null
        ? 'No response yet.'
        : _response!.isEmpty
            ? 'Empty response.'
            : _hexDump(_response!);
    final root = _rootController.text.trim();
    final server = _serverController.text.trim();
    final maxInfo = root.isEmpty
        ? 'Max request: n/a | Max response: n/a'
        : _maxInfo(root, server);

    return Scaffold(
      appBar: AppBar(
        title: const Text('DNS Byte Echo'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _rootController,
              decoration: const InputDecoration(
                labelText: 'Root domain (e.g. ns.aqnichol.com)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(
                labelText: 'DNS server (host:port, empty = auto)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            if (_detectedServers.isNotEmpty)
              Text('Detected DNS: ${_detectedServers.join(', ')}'),
            const SizedBox(height: 12),
            TextField(
              controller: _sendController,
              decoration: const InputDecoration(
                labelText: 'Text to send',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            Text(maxInfo),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loading ? null : _runQuery,
              child: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Get'),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            if (_responseText != null)
              TextField(
                controller: TextEditingController(text: _responseText!),
                readOnly: true,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Received text',
                  border: OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey.shade50,
                ),
                child: SingleChildScrollView(
                  child: Text(
                    responseText,
                    style: const TextStyle(fontFamily: 'Menlo'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _maxInfo(String root, String server) {
  final client = DnsByteClient(
      rootDomain: root, server: server.isEmpty ? '1.1.1.1:53' : server);
  return 'Max request: ${client.maxRequestSize} bytes | '
      'Max response: ${client.maxResponseSize} bytes';
}

String _hexDump(Uint8List data) {
  final buffer = StringBuffer();
  for (var i = 0; i < data.length; i++) {
    final byte = data[i];
    final hex = byte.toRadixString(16).padLeft(2, '0');
    buffer.write(hex);
    if (i != data.length - 1) {
      buffer.write(' ');
    }
  }
  return buffer.toString();
}
