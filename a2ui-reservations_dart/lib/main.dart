// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// A2UI Dining Reservations Flutter client.
///
/// Connects to the Genkit A2UI agent (`bin/server.dart`) using `remoteAgent`
/// from `package:genkit/client.dart`, streams prose and A2UI surfaces into a
/// modern chat interface, and renders interactive surfaces with `genui`.
///
/// Key A2UI integration points demonstrated below:
/// 1. Matching client & server catalogs via [bistroCatalogId] (`_catalog`).
/// 2. Streaming agent chunks (`_runTurn`) and extracting A2UI envelopes with
///    [a2uiEnvelopesFromParts] into a [SurfaceController].
/// 3. Capturing user interactions from rendered surfaces (`_onSurfaceSubmit`)
///    and sending them back as structured turns with [actionToMessage].
library;

import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:flutter/material.dart';
import 'package:genkit/client.dart';
import 'package:genkit_a2ui/client.dart';
import 'package:genui/genui.dart' hide DataPart, TextPart, basicCatalogId;

import 'shared.dart';

/// Base URL of the Shelf agent server. Override with `--dart-define=AGENT_BASE_URL`.
const String _baseUrl = String.fromEnvironment(
  'AGENT_BASE_URL',
  defaultValue: 'http://localhost:8080',
);

// ---------------------------------------------------------------------------
// 1. Client A2UI Catalog Configuration
// ---------------------------------------------------------------------------

/// Custom `Card` catalog item with comfortable 20px padding for form layouts.
final CatalogItem _bistroCardItem = CatalogItem(
  name: 'Card',
  dataSchema: BasicCatalogItems.card.dataSchema,
  widgetBuilder: (itemContext) {
    final childId = (itemContext.data as Map)['child'] as String;
    return Card(
      color: Theme.of(itemContext.buildContext).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: itemContext.buildChild(childId),
      ),
    );
  },
);

/// The client catalog, tagged with the same [bistroCatalogId] advertised by
/// the server's `bistroCatalog` (`lib/agent.dart`).
final Catalog _catalog = BasicCatalogItems.asCatalog().copyWith(
  catalogId: bistroCatalogId,
  newItems: [_bistroCardItem],
);

void main() {
  runApp(const A2uiApp());
}

// ---------------------------------------------------------------------------
// 2. Core Chat & A2UI Streaming Logic
// ---------------------------------------------------------------------------

/// Models an entry in the conversation stream: prose text, an interactive
/// A2UI surface, or a user UI interaction badge.
sealed class _Entry {
  const _Entry();
}

class _TextEntry extends _Entry {
  _TextEntry(this.isUser, this.text);
  final bool isUser;
  String text;
}

class _SurfaceEntry extends _Entry {
  _SurfaceEntry(this.surfaceId);
  final String surfaceId;
}

class _ActionEntry extends _Entry {
  _ActionEntry(this.action);
  final A2uiClientAction action;
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final AgentApi _agent;
  late AgentChat _chat;
  late SurfaceController _surfaceController;

  final _entries = <_Entry>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _agent = remoteAgent(
      url: '$_baseUrl/api/uiAgent',
      getSnapshotUrl: '$_baseUrl/api/uiAgent/getSnapshot',
      abortUrl: '$_baseUrl/api/uiAgent/abort',
    );
    _initSession();
  }

  void _initSession() {
    _chat = _agent.chat();
    _surfaceController = SurfaceController(catalogs: [_catalog]);

    // Mount newly created A2UI surfaces into the conversation log.
    _surfaceController.surfaceUpdates.listen((update) {
      if (update is SurfaceAdded) {
        final exists = _entries.whereType<_SurfaceEntry>().any(
          (e) => e.surfaceId == update.surfaceId,
        );
        if (!exists && mounted) {
          setState(() => _entries.add(_SurfaceEntry(update.surfaceId)));
          _scrollToBottom();
        }
      }
    });

    // Forward interactive surface events (e.g. button clicks) to the agent.
    _surfaceController.onSubmit.listen(_onSurfaceSubmit);
  }

  void _resetSession() {
    if (_busy) return;
    _surfaceController.dispose();
    setState(() {
      _entries.clear();
      _initSession();
    });
  }

  @override
  void dispose() {
    _surfaceController.dispose();
    _agent.close();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Sends a user text prompt to the agent.
  Future<void> _send(String text) async {
    if (text.trim().isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _entries.add(_TextEntry(true, text));
      _busy = true;
    });
    _scrollToBottom();
    await _runTurn(_chat.sendStream(text: text));
  }

  /// Converts a rendered surface's submit interaction into an [A2uiClientAction]
  /// and sends it back to the agent as the next conversation turn.
  Future<void> _onSurfaceSubmit(ChatMessage message) async {
    if (_busy) return;
    final action = extractClientAction(message);
    if (action == null) return;

    setState(() {
      _entries.add(_ActionEntry(action));
      _busy = true;
    });
    _scrollToBottom();
    await _runTurn(_chat.sendStream(message: actionToMessage(action)));
  }

  /// Streams a single agent turn, incrementally rendering prose text and
  /// decoding A2UI envelopes into the [SurfaceController].
  Future<void> _runTurn(AgentTurn turn) async {
    _TextEntry? prose;
    try {
      await for (final chunk in turn.stream) {
        // 1. Append streamed prose text deltas
        if (chunk.text.isNotEmpty) {
          if (prose == null) {
            prose = _TextEntry(false, '');
            setState(() => _entries.add(prose!));
          }
          setState(() => prose!.text += chunk.text);
          _scrollToBottom();
        }

        // 2. Decode A2UI envelopes from data parts and update surfaces
        for (final envelope in a2uiEnvelopesFromParts(
          chunk.raw.modelChunk?.content,
        )) {
          _handleEnvelope(envelope);
        }
      }
      await turn.response;
    } catch (err) {
      setState(() => _entries.add(_TextEntry(false, 'Error: $err')));
    } finally {
      if (prose != null && prose.text.trim().isEmpty) {
        setState(() => _entries.remove(prose));
      }
      if (mounted) {
        setState(() => _busy = false);
        _scrollToBottom();
        Future.delayed(const Duration(milliseconds: 150), _scrollToBottom);
      }
    }
  }

  void _handleEnvelope(Map<String, dynamic> envelope) {
    try {
      _sanitizeEnvelope(envelope);
      _surfaceController.handleMessage(core.A2uiMessage.fromJson(envelope));
    } catch (err) {
      debugPrint('Failed to apply A2UI envelope: $err');
    }
  }

  /// Prevents infinite height layout exceptions when a `Row` uses `align: stretch`
  /// inside an unbounded vertical scroll view.
  void _sanitizeEnvelope(Map<String, dynamic> envelope) {
    final update = envelope['updateComponents'];
    if (update is! Map) return;
    final components = update['components'];
    if (components is! List) return;
    for (final c in components) {
      if (c is Map && c['component'] == 'Row' && c['align'] == 'stretch') {
        c.remove('align');
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            children: [
              if (_entries.isNotEmpty) ...[
                _SuggestionBar(onTap: _busy ? null : _send),
                const Divider(color: Color(0xFF1A2337), height: 1),
              ],
              Expanded(
                child: _entries.isEmpty
                    ? _WelcomeHero(onSelectPrompt: _busy ? null : _send)
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 20,
                        ),
                        itemCount: _entries.length,
                        itemBuilder: (context, i) => _buildEntry(_entries[i]),
                      ),
              ),
              if (_busy)
                const LinearProgressIndicator(
                  color: Color(0xFF6582CC),
                  backgroundColor: Color(0xFF0F1827),
                  minHeight: 2,
                ),
              _Composer(controller: _input, enabled: !_busy, onSend: _send),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(62),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF070B13),
          border: Border(
            bottom: BorderSide(color: Color(0xFF1A2337), width: 1),
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF141F32),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF222D47)),
                      ),
                      child: const Icon(
                        Icons.restaurant_rounded,
                        color: Color(0xFF7FA2FF),
                        size: 19,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cymbal Bistro',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                        ),
                        Text(
                          'Genkit Dart + A2UI Dining Concierge',
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    const _StatusBadge(label: 'A2UI v0.9'),
                    if (_entries.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'New reservation session',
                        onPressed: _busy ? null : _resetSession,
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFF141F32),
                          foregroundColor: const Color(0xFFCBD5E1),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: const BorderSide(color: Color(0xFF222D47)),
                          ),
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(_Entry entry) {
    switch (entry) {
      case _TextEntry(:final isUser, :final text):
        final trimmed = text.trim();
        if (trimmed.isEmpty) return const SizedBox.shrink();
        if (isUser) {
          return Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF6582CC),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  trimmed,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          );
        } else {
          return Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
                child: Text(
                  trimmed,
                  style: const TextStyle(
                    color: Color(0xFFE2E8F0),
                    fontSize: 14.5,
                    height: 1.5,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ),
          );
        }

      case _ActionEntry(:final action):
        return Align(
          alignment: Alignment.centerRight,
          child: _ActionBadge(action: action),
        );

      case _SurfaceEntry(:final surfaceId):
        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              child: IntrinsicHeight(
                child: Surface(
                  surfaceContext: _surfaceController.contextFor(surfaceId),
                ),
              ),
            ),
          ),
        );
    }
  }
}

/// Extracts an [A2uiClientAction] from a `genui` [ChatMessage] emitted by
/// `SurfaceController.onSubmit`.
A2uiClientAction? extractClientAction(ChatMessage message) {
  for (final part in message.parts) {
    final interaction = part.asUiInteractionPart?.interaction;
    if (interaction == null) continue;
    final decoded = jsonDecode(interaction);
    final action = (decoded is Map) ? decoded['action'] : null;
    if (action is Map) {
      final map = action.cast<String, dynamic>();
      return A2uiClientAction(
        name: (map['name'] as String?) ?? 'action',
        surfaceId: (map['surfaceId'] as String?) ?? '',
        sourceComponentId: (map['widgetId'] as String?) ?? '',
        timestamp: DateTime.now().toUtc().toIso8601String(),
        context: (map['context'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 3. UI Chrome & Theme Widgets
// ---------------------------------------------------------------------------

class A2uiApp extends StatelessWidget {
  const A2uiApp({super.key});

  @override
  Widget build(BuildContext context) {
    const bgDark = Color(0xFF070B13);
    const surfaceDark = Color(0xFF0F1827);
    const borderDark = Color(0xFF222D47);
    const primaryBlue = Color(0xFF6582CC);
    const lightText = Color(0xFFE2E8F0);

    return MaterialApp(
      title: 'Cymbal Bistro - A2UI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bgDark,
        colorScheme: const ColorScheme.dark(
          surface: surfaceDark,
          surfaceContainerHighest: Color(0xFF141F32),
          primary: primaryBlue,
          onPrimary: Colors.white,
          secondary: Color(0xFF7FA2FF),
          outline: borderDark,
        ),
        cardTheme: CardThemeData(
          color: surfaceDark,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: borderDark, width: 1),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryBlue,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            textStyle: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primaryBlue,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            textStyle: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: surfaceDark,
          selectedColor: const Color(0xFF1E325C),
          checkmarkColor: const Color(0xFF93B4FF),
          side: const BorderSide(color: borderDark),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          labelStyle: const TextStyle(color: lightText, fontSize: 13),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0A101C),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: borderDark),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: borderDark),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: primaryBlue, width: 1.5),
          ),
          labelStyle: const TextStyle(
            color: Color(0xFF94A3B8),
            fontSize: 13.5,
          ),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: primaryBlue,
          inactiveTrackColor: const Color(0xFF1A2946),
          thumbColor: const Color(0xFF7FA2FF),
          overlayColor: primaryBlue.withValues(alpha: 0.2),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return primaryBlue;
            }
            return Colors.transparent;
          }),
          side: const BorderSide(color: borderDark, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        useMaterial3: true,
      ),
      home: const ChatPage(),
    );
  }
}

/// Welcome screen shown before the first message is sent.
class _WelcomeHero extends StatelessWidget {
  const _WelcomeHero({required this.onSelectPrompt});
  final void Function(String prompt)? onSelectPrompt;

  static const _starterCards = [
    (
      icon: Icons.dinner_dining_rounded,
      title: 'Dinner Tonight for 4',
      prompt: 'Book a table for 4 at Cymbal Bistro tonight at 7:00 PM.',
    ),
    (
      icon: Icons.wine_bar_rounded,
      title: 'Date Night Tomorrow',
      prompt: 'Reserve a quiet table for 2 tomorrow at 6:30 PM.',
    ),
    (
      icon: Icons.deck_rounded,
      title: 'Friday Group Dining',
      prompt: 'Table for 6 on Friday at 8:00 PM with heated patio seating.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFF141F32),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF283756)),
              ),
              child: const Icon(
                Icons.restaurant_menu_rounded,
                color: Color(0xFF7FA2FF),
                size: 26,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Welcome to Cymbal Bistro',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: const Text(
                'An AI dining concierge that streams interactive A2UI surfaces. '
                'Ask for table availability, customize seating, and confirm your reservation.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                for (final card in _starterCards)
                  _StarterPromptCard(
                    icon: card.icon,
                    title: card.title,
                    prompt: card.prompt,
                    onTap: onSelectPrompt == null
                        ? null
                        : () => onSelectPrompt!(card.prompt),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StarterPromptCard extends StatelessWidget {
  const _StarterPromptCard({
    required this.icon,
    required this.title,
    required this.prompt,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String prompt;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Material(
        color: const Color(0xFF0F1827),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF222D47)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: const Color(0xFF7FA2FF), size: 20),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  prompt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Visualizes a user interaction sent back to the agent from an A2UI surface.
class _ActionBadge extends StatelessWidget {
  const _ActionBadge({required this.action});
  final A2uiClientAction action;

  String _formatTitle(String raw) {
    return switch (raw) {
      'confirmReservation' => 'Confirm Reservation',
      'modifyReservation' => 'Modify Reservation',
      _ => raw,
    };
  }

  List<String> _extractSummaryPills() {
    final pills = <String>[];
    final ctx = action.context;
    String? scalar(dynamic val) {
      if (val == null) return null;
      if (val is List && val.isNotEmpty) return val.first.toString();
      final str = val.toString().trim();
      return str.isEmpty ? null : str;
    }

    final date = scalar(ctx['date']);
    final time = scalar(ctx['time'] ?? ctx['timeSlot']);
    final party = scalar(ctx['partySize']);
    final seating = scalar(ctx['seatingArea'] ?? ctx['seating']);

    if (date != null) pills.add(date);
    if (time != null) pills.add(time);
    if (party != null) pills.add('$party guests');
    if (seating != null) pills.add(seating);
    return pills;
  }

  @override
  Widget build(BuildContext context) {
    final pills = _extractSummaryPills();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF141F32),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF6582CC).withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.touch_app_rounded,
                color: Color(0xFF7FA2FF),
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                _formatTitle(action.name),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (pills.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final pill in pills)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E2D4A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      pill,
                      style: const TextStyle(
                        color: Color(0xFFCBD5E1),
                        fontSize: 11.5,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF141F32),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF222D47)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: Color(0xFF34D399),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFCBD5E1),
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionBar extends StatelessWidget {
  const _SuggestionBar({required this.onTap});
  final void Function(String prompt)? onTap;

  static const _prompts = [
    'Book a table for 4 at Cymbal Bistro tonight at 7:00 PM.',
    'Reserve a table for 2 tomorrow at 6:30 PM.',
    'Table for 6 on Friday at 8:00 PM with patio seating.',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final p in _prompts)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: Text(p),
                    backgroundColor: const Color(0xFF0F1827),
                    side: const BorderSide(color: Color(0xFF222D47)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    labelStyle: const TextStyle(
                      color: Color(0xFFCBD5E1),
                      fontSize: 12.5,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    onPressed: onTap == null ? null : () => onTap!(p),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final void Function(String text) onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        decoration: BoxDecoration(
          color: const Color(0xFF0F1827),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFF222D47)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Ask for a table, or adjust dining preferences…',
                  hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 14),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
                onSubmitted: enabled ? onSend : null,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6582CC),
                foregroundColor: Colors.white,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
              ),
              onPressed: enabled ? () => onSend(controller.text) : null,
              child: const Text(
                'Send',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
