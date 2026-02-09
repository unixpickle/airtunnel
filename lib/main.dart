import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_protocol.dart';
import 'dns_server.dart';

void main() {
  runApp(const DnsApp());
}

class DnsApp extends StatelessWidget {
  const DnsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DNS Chat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const ChatHome(),
    );
  }
}

class ChatMessage {
  ChatMessage({required this.role, required this.text});

  final String role;
  String text;
}

class ChatHome extends StatefulWidget {
  const ChatHome({super.key});

  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> {
  final _rootController =
      TextEditingController(text: 'someserver.google.com');
  final _serverController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _inputController = TextEditingController();
  final _messages = <ChatMessage>[];

  List<String> _detectedServers = const [];
  String? _previousResponseId;
  bool _sending = false;
  String? _error;

  static const _prefsApiKey = 'openai_api_key';
  static const _prefsPrevResponse = 'previous_response_id';

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadDnsServers();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    setState(() {
      _apiKeyController.text = prefs.getString(_prefsApiKey) ?? '';
      _previousResponseId = prefs.getString(_prefsPrevResponse);
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsApiKey, _apiKeyController.text.trim());
    if (_previousResponseId == null) {
      await prefs.remove(_prefsPrevResponse);
    } else {
      await prefs.setString(_prefsPrevResponse, _previousResponseId!);
    }
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

  Future<void> _sendMessage() async {
    final apiKey = _apiKeyController.text.trim();
    final root = _rootController.text.trim();
    final server = _serverController.text.trim();
    final text = _inputController.text.trim();
    if (apiKey.isEmpty || root.isEmpty || text.isEmpty) {
      setState(() {
        _error = 'API key, root domain, and message are required.';
      });
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
      _messages.add(ChatMessage(role: 'user', text: text));
      _messages.add(ChatMessage(role: 'assistant', text: ''));
    });

    _inputController.clear();
    await _savePrefs();

    final chosenServer = server.isEmpty
        ? (_detectedServers.isNotEmpty ? '${_detectedServers.first}:53' : '1.1.1.1:53')
        : server;

    try {
      final client = DnsChatClient(rootDomain: root, server: chosenServer);
      final stream = client.sendMessage(
        apiKey: apiKey,
        model: 'gpt-4o-mini',
        message: text,
        previousResponseId: _previousResponseId,
      );

      await for (final chunk in stream) {
        if (chunk.responseId != null) {
          _previousResponseId = chunk.responseId;
          await _savePrefs();
        }
        if (chunk.delta != null && chunk.delta!.isNotEmpty) {
          setState(() {
            _messages.last.text += chunk.delta!;
          });
        }
        if (chunk.done) {
          break;
        }
      }
    } catch (e) {
      setState(() {
        _error = 'Send failed: $e';
      });
    } finally {
      setState(() {
        _sending = false;
      });
    }
  }

  Future<void> _newChat() async {
    setState(() {
      _messages.clear();
      _previousResponseId = null;
      _error = null;
    });
    await _savePrefs();
  }

  @override
  Widget build(BuildContext context) {
    final maxInfo = _maxInfo();
    return Scaffold(
      appBar: AppBar(
        title: const Text('DNS Chat'),
        actions: [
          TextButton(
            onPressed: _sending ? null : _newChat,
            child: const Text('New chat'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'OpenAI API key (stored locally)',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              onChanged: (_) => _savePrefs(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rootController,
              decoration: const InputDecoration(
                labelText: 'Root domain (delegated)',
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
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Detected DNS: ${_detectedServers.join(', ')}'),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(maxInfo),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final msg = _messages[index];
                    final isUser = msg.role == 'user';
                    return Align(
                      alignment:
                          isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isUser
                              ? Colors.indigo.shade50
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(msg.text),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      border: OutlineInputBorder(),
                    ),
                    minLines: 1,
                    maxLines: 4,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _sending ? null : _sendMessage,
                  child: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _maxInfo() {
    final root = _rootController.text.trim();
    final server = _serverController.text.trim();
    if (root.isEmpty) {
      return 'Max request: n/a | Max response: n/a';
    }
    final chosenServer =
        server.isEmpty ? '1.1.1.1:53' : server;
    final client = DnsChatClient(rootDomain: root, server: chosenServer);
    return 'Max request: ${client.maxRequestBytes} bytes | '
        'Max response: ${client.maxResponseBytes} bytes';
  }
}
