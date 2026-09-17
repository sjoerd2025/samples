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

import 'dart:io';

import 'package:a2ui_core/a2ui_core.dart' as core;
import 'package:a2ui_reservations_dart/agent.dart';
import 'package:a2ui_reservations_dart/main.dart';
import 'package:a2ui_reservations_dart/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart' show ToolResponseResult;
import 'package:genkit_a2ui/client.dart';
import 'package:genui/genui.dart' hide DataPart, TextPart, basicCatalogId;

void main() {
  group('Server Agent & Catalog', () {
    test('registers bistroCatalog and exposes tools', () async {
      await registerCatalogs();
      expect(bistroCatalog.id, equals(bistroCatalogId));
      expect(
        bistroCatalog.components.map((c) => c.name),
        containsAll(['Card', 'DateTimeInput', 'ChoicePicker', 'Button']),
      );
      expect(checkAvailability.name, equals('checkAvailability'));
      expect(confirmReservation.name, equals('confirmReservation'));
    });

    test('checkAvailability returns ISO date and slots', () async {
      final res = await checkAvailability.call(
        CheckAvailabilityInput(
          restaurant: 'Cymbal Bistro',
          date: 'tonight',
          partySize: 4,
        ),
      );
      final output = (res as ToolResponseResult<CheckAvailabilityOutput>).output;
      expect(output.available, isTrue);
      expect(output.date, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(output.availableSlots, contains('7:00 PM'));
      expect(output.seatingAreas, contains('Heated Patio'));
    });

    test('confirmReservation generates confirmation code', () async {
      final res = await confirmReservation.call(
        ConfirmReservationInput(
          restaurant: 'Cymbal Bistro',
          date: '2026-09-16',
          time: '7:30 PM',
          partySize: 4,
          seatingArea: 'Heated Patio',
          specialRequests: 'Quiet corner',
        ),
      );
      final output =
          (res as ToolResponseResult<ConfirmReservationOutput>).output;
      expect(output.confirmationCode, startsWith('CB-'));
      expect(output.status, equals('Confirmed'));
      expect(output.seatingArea, equals('Heated Patio'));
    });
  });

  group('Flutter Client UI & A2UI Rendering', () {
    testWidgets('displays welcome hero screen on launch', (tester) async {
      await tester.pumpWidget(const A2uiApp());
      expect(find.text('Welcome to Cymbal Bistro'), findsOneWidget);
      expect(find.text('Dinner Tonight for 4'), findsOneWidget);
      expect(find.text('Date Night Tomorrow'), findsOneWidget);
    });

    testWidgets(
      'renders A2UI reservation surface and dispatches confirmReservation action',
      (tester) async {
        final catalog = BasicCatalogItems.asCatalog().copyWith(
          catalogId: bistroCatalogId,
        );
        final controller = SurfaceController(catalogs: [catalog]);

        final envelopes = [
          {
            'version': 'v0.9',
            'createSurface': {
              'surfaceId': 'reservation-surface',
              'catalogId': bistroCatalogId,
            },
          },
          {
            'version': 'v0.9',
            'updateComponents': {
              'surfaceId': 'reservation-surface',
              'components': [
                {'id': 'root', 'component': 'Card', 'child': 'formCol'},
                {
                  'id': 'formCol',
                  'component': 'Column',
                  'children': [
                    'title',
                    'timePicker',
                    'seatingPicker',
                    'confirmBtn',
                  ],
                },
                {
                  'id': 'title',
                  'component': 'Text',
                  'text': 'Reserve a Table at Cymbal Bistro',
                  'variant': 'h3',
                },
                {
                  'id': 'timePicker',
                  'component': 'ChoicePicker',
                  'label': 'Time Slot',
                  'displayStyle': 'chips',
                  'variant': 'mutuallyExclusive',
                  'value': {'path': '/time'},
                  'options': [
                    {'label': '6:00 PM', 'value': '6:00 PM'},
                    {'label': '7:30 PM', 'value': '7:30 PM'},
                  ],
                },
                {
                  'id': 'seatingPicker',
                  'component': 'ChoicePicker',
                  'label': 'Seating Area',
                  'displayStyle': 'chips',
                  'variant': 'mutuallyExclusive',
                  'value': {'path': '/seating'},
                  'options': [
                    {'label': 'Indoor Dining', 'value': 'Indoor Dining'},
                    {'label': 'Heated Patio', 'value': 'Heated Patio'},
                  ],
                },
                {
                  'id': 'confirmBtn',
                  'component': 'Button',
                  'variant': 'primary',
                  'child': 'confirmBtnText',
                  'action': {
                    'event': {
                      'name': 'confirmReservation',
                      'context': {
                        'restaurant': 'Cymbal Bistro',
                        'time': {'path': '/time'},
                        'seatingArea': {'path': '/seating'},
                      },
                    },
                  },
                },
                {
                  'id': 'confirmBtnText',
                  'component': 'Text',
                  'text': 'Confirm Reservation',
                },
              ],
            },
          },
          {
            'version': 'v0.9',
            'updateDataModel': {
              'surfaceId': 'reservation-surface',
              'path': '/time',
              'value': ['6:00 PM'],
            },
          },
          {
            'version': 'v0.9',
            'updateDataModel': {
              'surfaceId': 'reservation-surface',
              'path': '/seating',
              'value': ['Indoor Dining'],
            },
          },
        ];

        for (final e in envelopes) {
          controller.handleMessage(core.A2uiMessage.fromJson(e));
        }

        ChatMessage? submittedMessage;
        controller.onSubmit.listen((msg) => submittedMessage = msg);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: IntrinsicHeight(
                  child: Surface(
                    surfaceContext: controller.contextFor(
                      'reservation-surface',
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Select '7:30 PM' and 'Heated Patio'
        await tester.tap(find.text('7:30 PM'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Heated Patio'));
        await tester.pumpAndSettle();

        // Click 'Confirm Reservation'
        await tester.tap(find.text('Confirm Reservation'));
        await tester.pumpAndSettle();

        expect(submittedMessage, isNotNull);
        final action = extractClientAction(submittedMessage!);
        expect(action, isNotNull);
        expect(action!.name, equals('confirmReservation'));
        expect(action.context['time'], equals(['7:30 PM']));
        expect(action.context['seatingArea'], equals(['Heated Patio']));

        final msg = actionToMessage(action);
        expect(msg.content.first.toJson()['text'], contains('confirmReservation'));
      },
    );
  });

  // Live E2E test runs only when GEMINI_API_KEY is present in environment
  final apiKey = Platform.environment['GEMINI_API_KEY'];
  if (apiKey != null && apiKey.isNotEmpty) {
    test('Live E2E: Two-turn booking flow with Gemini', () async {
      // Restore real HTTP client after testWidgets mock HttpOverrides
      HttpOverrides.global = null;
      await registerCatalogs();
      final chat = uiAgent.chat();
      final turn1 = chat.sendStream(
        text: 'Book a table for 4 at Cymbal Bistro tonight at 7:00 PM.',
      );

      String? surfaceId;
      final envelopes1 = <Map<String, dynamic>>[];
      await for (final chunk in turn1.stream) {
        for (final env in a2uiEnvelopesFromParts(
          chunk.raw.modelChunk?.content,
        )) {
          envelopes1.add(env);
          if (env['createSurface'] != null) {
            surfaceId = env['createSurface']['surfaceId'] as String?;
          }
        }
      }
      await turn1.response;
      expect(surfaceId, isNotNull);
      expect(envelopes1, isNotEmpty);

      final action = A2uiClientAction(
        name: 'confirmReservation',
        surfaceId: surfaceId!,
        sourceComponentId: 'confirmBtn',
        timestamp: DateTime.now().toUtc().toIso8601String(),
        context: {
          'restaurant': 'Cymbal Bistro',
          'date': '2026-09-16',
          'time': ['7:30 PM'],
          'partySize': 4,
          'seatingArea': ['Heated Patio'],
          'specialRequests': 'Anniversary dinner',
        },
      );

      final turn2 = chat.sendStream(message: actionToMessage(action));
      final envelopes2 = <Map<String, dynamic>>[];
      await for (final chunk in turn2.stream) {
        for (final env in a2uiEnvelopesFromParts(
          chunk.raw.modelChunk?.content,
        )) {
          envelopes2.add(env);
        }
      }
      await turn2.response;
      expect(envelopes2, isNotEmpty);
    });
  }
}
