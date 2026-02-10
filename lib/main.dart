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
      home: const RootScreen(),
    );
  }
}

class ChatMessage {
  ChatMessage({required this.role, required this.text});

  final String role;
  String text;

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
      };

  static ChatMessage fromJson(Map<String, dynamic> json) {
    return ChatMessage(role: json['role'] as String, text: json['text'] as String);
  }
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    this.previousResponseId,
  });

  final String id;
  String title;
  final List<ChatMessage> messages;
  String? previousResponseId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'previous_response_id': previousResponseId,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  static ChatSession fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      title: json['title'] as String,
      previousResponseId: json['previous_response_id'] as String?,
      messages: (json['messages'] as List<dynamic>)
          .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}

class AppSettings {
  AppSettings({
    required this.apiKey,
    required this.rootDomain,
    required this.server,
  });

  final String apiKey;
  final String rootDomain;
  final String server;

  bool get isComplete => apiKey.isNotEmpty && rootDomain.isNotEmpty;
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  AppSettings? _settings;
  List<ChatSession> _chats = [];
  List<String> _detectedServers = const [];
  bool _loading = true;

  static const _prefsApiKey = 'openai_api_key';
  static const _prefsRoot = 'root_domain';
  static const _prefsServer = 'dns_server';
  static const _prefsChats = 'chat_sessions';

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final resolver = DnsServerResolver();
    final servers = await resolver.getServers();
    final apiKey = prefs.getString(_prefsApiKey) ?? '';
    final root = prefs.getString(_prefsRoot) ?? '';
    final server = prefs.getString(_prefsServer) ?? '';
    final rawChats = prefs.getString(_prefsChats);
    List<ChatSession> chats = [];
    if (rawChats != null && rawChats.isNotEmpty) {
      final decoded = jsonDecode(rawChats) as List<dynamic>;
      chats = decoded
          .map((c) => ChatSession.fromJson(c as Map<String, dynamic>))
          .toList();
    }

    if (!mounted) return;
    setState(() {
      _settings = AppSettings(apiKey: apiKey, rootDomain: root, server: server);
      _chats = chats;
      _detectedServers = servers;
      _loading = false;
    });
  }

  Future<void> _saveSettings(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsApiKey, settings.apiKey);
    await prefs.setString(_prefsRoot, settings.rootDomain);
    await prefs.setString(_prefsServer, settings.server);
    final prev = _settings;
    final resetConversation = prev != null &&
        (prev.apiKey != settings.apiKey ||
            prev.rootDomain != settings.rootDomain);
    if (resetConversation) {
      for (final chat in _chats) {
        chat.previousResponseId = null;
      }
      await _saveChats();
    }
    setState(() {
      _settings = settings;
    });
  }

  Future<void> _saveChats() async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(_chats.map((c) => c.toJson()).toList());
    await prefs.setString(_prefsChats, data);
  }

  void _openSettings() async {
    final result = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          initial: _settings!,
          detectedServers: _detectedServers,
        ),
      ),
    );
    if (result != null) {
      await _saveSettings(result);
    }
  }

  void _openChat(ChatSession chat) async {
    final updated = await Navigator.of(context).push<ChatSession>(
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          chat: chat,
          settings: _settings!,
          detectedServers: _detectedServers,
        ),
      ),
    );
    if (updated != null) {
      final idx = _chats.indexWhere((c) => c.id == updated.id);
      if (idx >= 0) {
        setState(() {
          _chats[idx] = updated;
        });
        await _saveChats();
      }
    }
  }

  void _createChat() {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final chat = ChatSession(id: id, title: 'New chat', messages: []);
    setState(() {
      _chats.insert(0, chat);
    });
    _saveChats();
    _openChat(chat);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_settings == null || !_settings!.isComplete) {
      return SetupScreen(
        detectedServers: _detectedServers,
        onSave: (settings) async {
          await _saveSettings(settings);
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('DNS Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _chats.isEmpty
          ? Center(
              child: Text(
                'No chats yet. Tap + to start one.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            )
          : ListView.builder(
              itemCount: _chats.length,
              itemBuilder: (context, index) {
                final chat = _chats[index];
                return ListTile(
                  title: Text(chat.title),
                  subtitle: Text('${chat.messages.length} messages'),
                  onTap: () => _openChat(chat),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createChat,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.detectedServers, required this.onSave});

  final List<String> detectedServers;
  final Future<void> Function(AppSettings settings) onSave;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _apiKeyController = TextEditingController();
  final _rootController = TextEditingController();
  final _serverController = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.detectedServers.isNotEmpty) {
      _serverController.text = '${widget.detectedServers.first}:53';
    }
  }

  Future<void> _save() async {
    final apiKey = _apiKeyController.text.trim();
    final root = _rootController.text.trim();
    final server = _serverController.text.trim();
    if (apiKey.isEmpty || root.isEmpty) {
      setState(() {
        _error = 'API key and root domain are required.';
      });
      return;
    }
    await widget.onSave(
      AppSettings(apiKey: apiKey, rootDomain: root, server: server),
    );
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const RootScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'OpenAI API key',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rootController,
              decoration: const InputDecoration(
                labelText: 'Root domain',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(
                labelText: 'DNS server (host:port, optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            if (widget.detectedServers.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Detected DNS: ${widget.detectedServers.join(', ')}'),
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
            const Spacer(),
            ElevatedButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.initial, required this.detectedServers});

  final AppSettings initial;
  final List<String> detectedServers;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _rootController;
  late final TextEditingController _serverController;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: widget.initial.apiKey);
    _rootController = TextEditingController(text: widget.initial.rootDomain);
    _serverController = TextEditingController(text: widget.initial.server);
  }

  void _save() {
    final settings = AppSettings(
      apiKey: _apiKeyController.text.trim(),
      rootDomain: _rootController.text.trim(),
      server: _serverController.text.trim(),
    );
    Navigator.of(context).pop(settings);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'OpenAI API key',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rootController,
              decoration: const InputDecoration(
                labelText: 'Root domain',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(
                labelText: 'DNS server (host:port, optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            if (widget.detectedServers.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Detected DNS: ${widget.detectedServers.join(', ')}'),
              ),
            const Spacer(),
            ElevatedButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.chat,
    required this.settings,
    required this.detectedServers,
  });

  final ChatSession chat;
  final AppSettings settings;
  final List<String> detectedServers;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  String? _error;

  ChatSession get chat => widget.chat;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() {
      _sending = true;
      _error = null;
      chat.messages.add(ChatMessage(role: 'user', text: text));
      chat.messages.add(ChatMessage(role: 'assistant', text: ''));
    });

    _inputController.clear();
    _scrollToBottom();

    final chosenServer = widget.settings.server.isEmpty
        ? (widget.detectedServers.isNotEmpty
            ? '${widget.detectedServers.first}:53'
            : '1.1.1.1:53')
        : widget.settings.server;

    try {
      final client = DnsChatClient(
        rootDomain: widget.settings.rootDomain,
        server: chosenServer,
      );
      final stream = client.sendMessage(
        apiKey: widget.settings.apiKey,
        model: 'gpt-4o-mini',
        message: text,
        previousResponseId: chat.previousResponseId,
      );

      String? pendingResponseId;
      await for (final chunk in stream) {
        if (chunk.responseId != null) {
          pendingResponseId = chunk.responseId;
        }
        if (chunk.delta != null && chunk.delta!.isNotEmpty) {
          setState(() {
            chat.messages.last.text += chunk.delta!;
            if (chat.title == 'New chat') {
              chat.title = _titleFrom(chat.messages.first.text);
            }
          });
          _scrollToBottom();
        }
        if (chunk.done) {
          break;
        }
      }
      if (pendingResponseId != null && pendingResponseId!.isNotEmpty) {
        chat.previousResponseId = pendingResponseId;
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('previous response with id')) {
        setState(() {
          chat.previousResponseId = null;
          _error = 'Conversation expired. Start a new chat or resend.';
        });
      } else {
      setState(() {
        _error = 'Send failed: $e';
      });
      }
    } finally {
      setState(() {
        _sending = false;
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 200,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).pop(chat);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(chat.title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(chat),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: chat.messages.length,
                itemBuilder: (context, index) {
                  final msg = chat.messages[index];
                  final isUser = msg.role == 'user';
                  return Align(
                    alignment:
                        isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin:
                          const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
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
                    onPressed: _sending ? null : _send,
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
            ),
          ],
        ),
      ),
    );
  }
}

String _titleFrom(String message) {
  final words = message.trim().split(RegExp(r'\s+'));
  if (words.isEmpty) return 'Chat';
  final take = words.length > 6 ? 6 : words.length;
  return words.take(take).join(' ');
}
