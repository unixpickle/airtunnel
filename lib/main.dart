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
    return ChatMessage(
        role: json['role'] as String, text: json['text'] as String);
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
    required this.useDiscovery,
    required this.model,
  });

  final String apiKey;
  final String rootDomain;
  final String server;
  final bool useDiscovery;
  final String model;

  bool get isComplete => apiKey.isNotEmpty && rootDomain.isNotEmpty;
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> with WidgetsBindingObserver {
  AppSettings? _settings;
  List<ChatSession> _chats = [];
  List<String> _detectedServers = const [];
  bool _loading = true;

  static const _prefsApiKey = 'openai_api_key';
  static const _prefsRoot = 'root_domain';
  static const _prefsServer = 'dns_server';
  static const _prefsServerMode = 'dns_server_mode';
  static const _prefsModel = 'chat_model';
  static const _prefsChats = 'chat_sessions';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshServers();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _saveChats();
    }
  }

  Future<void> _refreshServers() async {
    final resolver = DnsServerResolver();
    final servers = await resolver.getServers();
    if (!mounted) return;
    setState(() {
      _detectedServers = servers;
    });
  }

  Future<void> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final resolver = DnsServerResolver();
    final servers = await resolver.getServers();
    final apiKey = prefs.getString(_prefsApiKey) ?? '';
    final root = prefs.getString(_prefsRoot) ?? '';
    final server = prefs.getString(_prefsServer) ?? '';
    final model = prefs.getString(_prefsModel) ?? 'gpt-5.2';
    final mode = prefs.getString(_prefsServerMode) ?? '';
    final useDiscovery = mode.isEmpty ? server.isEmpty : mode == 'discover';
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
      _settings = AppSettings(
        apiKey: apiKey,
        rootDomain: root,
        server: server,
        useDiscovery: useDiscovery,
        model: model,
      );
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
    await prefs.setString(
        _prefsServerMode, settings.useDiscovery ? 'discover' : 'manual');
    await prefs.setString(_prefsModel, settings.model);
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
          onPersist: _saveChats,
        ),
      ),
    );
    if (updated != null) {
      final idx = _chats.indexWhere((c) => c.id == updated.id);
      if (idx >= 0) {
        if (updated.messages.isEmpty) {
          setState(() {
            _chats.removeAt(idx);
          });
          await _saveChats();
          return;
        }
        setState(() {
          _chats[idx] = updated;
        });
        await _saveChats();
      }
    }
  }

  Future<void> _deleteChat(ChatSession chat) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: const Text('This will permanently delete the conversation.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _chats.removeWhere((c) => c.id == chat.id);
    });
    await _saveChats();
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
        title: const Text('AirTunnel'),
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
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    onPressed: () => _deleteChat(chat),
                  ),
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
  const SetupScreen(
      {super.key, required this.detectedServers, required this.onSave});

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
  bool _useDiscovery = true;
  String _model = 'gpt-5.2';

  @override
  void initState() {
    super.initState();
    if (widget.detectedServers.isNotEmpty) {
      _serverController.text = _formatServer(widget.detectedServers.first);
    } else {
      _useDiscovery = false;
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
    if (_useDiscovery && widget.detectedServers.isEmpty) {
      setState(() {
        _error = 'No DNS servers detected. Choose manual mode.';
      });
      return;
    }
    await widget.onSave(
      AppSettings(
        apiKey: apiKey,
        rootDomain: root,
        server: _useDiscovery ? '' : server,
        useDiscovery: _useDiscovery,
        model: _model,
      ),
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
            DropdownButtonFormField<String>(
              value: _model,
              items: const [
                DropdownMenuItem(value: 'gpt-5.2', child: Text('GPT-5.2')),
                DropdownMenuItem(
                    value: 'gpt-5-mini', child: Text('GPT-5 Mini')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _model = value;
                });
              },
              decoration: const InputDecoration(
                labelText: 'Model',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'DNS Server Mode',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 6),
            RadioListTile<bool>(
              title: const Text('Discover automatically'),
              value: true,
              groupValue: _useDiscovery,
              onChanged: widget.detectedServers.isEmpty
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _useDiscovery = value;
                        if (_useDiscovery &&
                            widget.detectedServers.isNotEmpty) {
                          _serverController.text =
                              _formatServer(widget.detectedServers.first);
                        }
                      });
                    },
            ),
            RadioListTile<bool>(
              title: const Text('Set manually'),
              value: false,
              groupValue: _useDiscovery,
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _useDiscovery = value;
                });
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _serverController,
              enabled: !_useDiscovery,
              decoration: const InputDecoration(
                labelText: 'DNS server (host:port)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            if (widget.detectedServers.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Auto-discovery is unavailable. This can happen with Private DNS, VPNs, or when the device has no active network yet.',
                ),
              ),
            if (widget.detectedServers.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child:
                    Text('Detected DNS: ${widget.detectedServers.join(', ')}'),
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
  const SettingsScreen(
      {super.key, required this.initial, required this.detectedServers});

  final AppSettings initial;
  final List<String> detectedServers;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _rootController;
  late final TextEditingController _serverController;
  late bool _useDiscovery;
  late String _model;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: widget.initial.apiKey);
    _rootController = TextEditingController(text: widget.initial.rootDomain);
    _serverController = TextEditingController(text: widget.initial.server);
    _useDiscovery = widget.initial.useDiscovery;
    _model = widget.initial.model;
    if (_useDiscovery && widget.detectedServers.isNotEmpty) {
      _serverController.text = _formatServer(widget.detectedServers.first);
    }
  }

  AppSettings _currentSettings() {
    return AppSettings(
      apiKey: _apiKeyController.text.trim(),
      rootDomain: _rootController.text.trim(),
      server: _useDiscovery ? '' : _serverController.text.trim(),
      useDiscovery: _useDiscovery,
      model: _model,
    );
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).pop(_currentSettings());
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_currentSettings()),
          ),
        ),
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
              DropdownButtonFormField<String>(
                value: _model,
                items: const [
                  DropdownMenuItem(value: 'gpt-5.2', child: Text('GPT-5.2')),
                  DropdownMenuItem(
                      value: 'gpt-5-mini', child: Text('GPT-5 Mini')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _model = value;
                  });
                },
                decoration: const InputDecoration(
                  labelText: 'Model',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'DNS Server Mode',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 6),
              RadioListTile<bool>(
                title: const Text('Discover automatically'),
                value: true,
                groupValue: _useDiscovery,
                onChanged: widget.detectedServers.isEmpty
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() {
                          _useDiscovery = value;
                          if (_useDiscovery &&
                              widget.detectedServers.isNotEmpty) {
                            _serverController.text =
                                _formatServer(widget.detectedServers.first);
                          }
                        });
                      },
              ),
              RadioListTile<bool>(
                title: const Text('Set manually'),
                value: false,
                groupValue: _useDiscovery,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _useDiscovery = value;
                  });
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _serverController,
                enabled: !_useDiscovery,
                decoration: const InputDecoration(
                  labelText: 'DNS server (host:port)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              if (widget.detectedServers.isEmpty)
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Auto-discovery is unavailable. This can happen with Private DNS, VPNs, or when the device has no active network yet.',
                  ),
                ),
              if (widget.detectedServers.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      'Detected DNS: ${widget.detectedServers.join(', ')}'),
                ),
            ],
          ),
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
    required this.onPersist,
  });

  final ChatSession chat;
  final AppSettings settings;
  final List<String> detectedServers;
  final Future<void> Function() onPersist;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  String? _error;
  bool _autoScroll = true;
  DnsChatClient? _client;
  String? _clientRoot;
  String? _clientServer;

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
      if (chat.title == 'New chat') {
        chat.title = _titleFrom(text);
      }
    });
    await widget.onPersist();

    _inputController.clear();
    _scrollToBottom();

    if (!mounted) return;

    final chosenServer = widget.settings.useDiscovery
        ? (widget.detectedServers.isNotEmpty
            ? _formatServer(widget.detectedServers.first)
            : '1.1.1.1:53')
        : widget.settings.server;

    try {
      final client = _getClient(widget.settings.rootDomain, chosenServer);
      final stream = client.sendMessage(
        apiKey: widget.settings.apiKey,
        model: widget.settings.model,
        message: text,
        previousResponseId: chat.previousResponseId,
      );

      String? pendingResponseId;
      final buffer = BytesBuilder();
      await for (final chunk in stream) {
        if (!mounted) {
          break;
        }
        if (chunk.responseId != null) {
          pendingResponseId = chunk.responseId;
        }
        if (chunk.deltaBytes != null && chunk.deltaBytes!.isNotEmpty) {
          buffer.add(chunk.deltaBytes!);
          final text = utf8.decode(buffer.toBytes(), allowMalformed: true);
          setState(() {
            chat.messages.last.text = text;
            if (chat.title == 'New chat') {
              chat.title = _titleFrom(chat.messages.first.text);
            }
          });
          await widget.onPersist();
          _scrollToBottom();
        }
        if (chunk.done) {
          break;
        }
      }
      if (pendingResponseId != null && pendingResponseId!.isNotEmpty) {
        chat.previousResponseId = pendingResponseId;
      }
      await widget.onPersist();
    } catch (e) {
      if (!mounted) return;
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
      await widget.onPersist();
    } finally {
      if (!mounted) return;
      setState(() {
        _sending = false;
      });
      await widget.onPersist();
      _scrollToBottom();
    }
  }

  DnsChatClient _getClient(String rootDomain, String server) {
    if (_client == null ||
        _clientRoot != rootDomain ||
        _clientServer != server) {
      _client = DnsChatClient(rootDomain: rootDomain, server: server);
      _clientRoot = rootDomain;
      _clientServer = server;
    }
    return _client!;
  }

  void _scrollToBottom() {
    if (!_autoScroll) return;
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
          actions: [
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Rename',
              onPressed: () async {
                final controller = TextEditingController(text: chat.title);
                final name = await showDialog<String>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Rename chat'),
                    content: TextField(
                      controller: controller,
                      decoration: const InputDecoration(
                        labelText: 'Chat name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            Navigator.of(context).pop(controller.text.trim()),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
                if (!mounted) return;
                if (name == null || name.isEmpty) return;
                setState(() {
                  chat.title = name;
                });
                await widget.onPersist();
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (!_scrollController.hasClients) {
                    return false;
                  }
                  final position = _scrollController.position;
                  final atBottom =
                      position.pixels >= position.maxScrollExtent - 24;
                  _autoScroll = atBottom;
                  return false;
                },
                child: ListView.builder(
                  controller: _scrollController,
                  physics: const ClampingScrollPhysics(),
                  itemCount: chat.messages.length,
                  itemBuilder: (context, index) {
                    final msg = chat.messages[index];
                    final isUser = msg.role == 'user';
                    return Align(
                      alignment:
                          isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                            vertical: 6, horizontal: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isUser
                              ? Colors.indigo.shade50
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectionArea(
                          child: SelectableText(msg.text),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
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

String _formatServer(String host) {
  final trimmed = host.trim();
  if (trimmed.isEmpty) {
    return '1.1.1.1:53';
  }
  if (trimmed.contains(':')) {
    if (trimmed.startsWith('[')) {
      return trimmed.contains(']:') ? trimmed : '$trimmed:53';
    }
    return '[$trimmed]:53';
  }
  return '$trimmed:53';
}
