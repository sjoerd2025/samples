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

/// Shared Genkit instance + the A2UI-enabled dining reservation agent.
///
/// The server-side A2UI integration is a single model middleware: add `a2ui()`
/// to the agent's `use` list and register `A2uiPlugin()` on the [Genkit]
/// instance. The API key is read from the `GEMINI_API_KEY` environment variable
/// by the `googleAI()` plugin.
///
/// This sample also demonstrates a **custom catalog**: [bistroCatalog] extends
/// the bundled basic catalog with dining-specific components such as
/// `DateTimeInput` and `ChoicePicker`.
library;

import 'package:genkit/genkit.dart';
import 'package:genkit_a2ui/a2ui.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:schemantic/schemantic.dart';

import 'shared.dart';

part 'agent.g.dart';

// ---------------------------------------------------------------------------
// Tool Schemas
// ---------------------------------------------------------------------------

@Schema()
abstract class $CheckAvailabilityInput {
  @Field(description: 'The restaurant name, e.g. Cymbal Bistro.')
  String get restaurant;

  @Field(
    description:
        'The date for the reservation, e.g. tonight, tomorrow, or YYYY-MM-DD.',
  )
  String get date;

  @Field(description: 'Number of guests.')
  int get partySize;
}

@Schema()
abstract class $CheckAvailabilityOutput {
  String get restaurant;
  @Field(description: 'Resolved reservation date in YYYY-MM-DD format.')
  String get date;
  int get partySize;
  bool get available;
  List<String> get availableSlots;
  List<String> get seatingAreas;
}

@Schema()
abstract class $ConfirmReservationInput {
  @Field(description: 'The restaurant name, e.g. Cymbal Bistro.')
  String get restaurant;

  @Field(description: 'Reservation date in YYYY-MM-DD format.')
  String get date;

  @Field(description: 'Selected time slot, e.g. 7:00 PM.')
  String get time;

  @Field(description: 'Number of guests.')
  int get partySize;

  @Field(
    description:
        'Selected seating area, e.g. Indoor Dining, Heated Patio, or Chef\'s Counter.',
  )
  String? get seatingArea;

  @Field(description: 'Special requests or dietary notes.')
  String? get specialRequests;
}

@Schema()
abstract class $ConfirmReservationOutput {
  String get confirmationCode;
  String get restaurant;
  String get date;
  String get time;
  int get partySize;
  String get seatingArea;
  String get specialRequests;
  String get status;
}

// ---------------------------------------------------------------------------
// Genkit Instance & Custom Catalog
// ---------------------------------------------------------------------------

/// The shared Genkit instance. `A2uiPlugin()` registers the `a2ui()` middleware.
final Genkit ai = Genkit(plugins: [googleAI(), A2uiPlugin(), RetryPlugin()]);

/// The app's custom A2UI catalog for Cymbal Bistro.
///
/// A catalog lists the components the model is allowed to emit, along with a
/// concise description of each component's props. Here we start from the
/// bundled [basicCatalog] (Text, Card, Column, Row, Button, Slider, ...) and
/// add dining-specific components (`DateTimeInput`, `ChoicePicker`).
final A2uiCatalog bistroCatalog = A2uiCatalog(
  id: bistroCatalogId,
  components: [
    ...basicCatalog.components,
    const A2uiCatalogComponent(
      name: 'DateTimeInput',
      description:
          'An input field for selecting a date and/or time. Tapping it opens the '
          'native Material date or time picker dialog. Always bind value to a '
          '{ "path": "/date" } data-model path and initialize it via updateDataModel '
          'with a YYYY-MM-DD string.',
      props:
          'value: { path } binding or YYYY-MM-DD string (required); '
          'variant?: date|time|datetime; label?: string.',
    ),
    const A2uiCatalogComponent(
      name: 'ChoicePicker',
      description:
          'A component for selecting options from interactive chips or checkboxes. '
          'Ideal for reservation time slots and seating preferences. Always bind value '
          'to a { "path": "/..." } data-model path and initialize via updateDataModel.',
      props:
          'options: Array of { label: string, value: string } (required); '
          'value: { path } binding or string[] (required); '
          'label?: string; displayStyle?: chips|checkbox; '
          'variant?: mutuallyExclusive|multipleSelection.',
    ),
  ],
);

/// Registers [bistroCatalog] on the Genkit instance so `a2ui(catalog: ...)`
/// can resolve it by id. Call once at server startup before handling turns.
Future<void> registerCatalogs() =>
    loadCatalog(ai, id: bistroCatalogId, catalog: bistroCatalog);

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

/// Resolves relative date terms (like "tonight" or "tomorrow") into ISO
/// `YYYY-MM-DD` strings so client date pickers display a valid calendar date.
String _resolveIsoDate(String raw) {
  final lower = raw.trim().toLowerCase();
  final now = DateTime.now();
  DateTime target = now;
  if (lower.contains('tomorrow')) {
    target = now.add(const Duration(days: 1));
  } else if (lower.contains('friday')) {
    final daysUntilFriday = (DateTime.friday - now.weekday + 7) % 7;
    target = now.add(Duration(days: daysUntilFriday == 0 ? 7 : daysUntilFriday));
  } else if (lower.contains('saturday')) {
    final daysUntilSat = (DateTime.saturday - now.weekday + 7) % 7;
    target = now.add(Duration(days: daysUntilSat == 0 ? 7 : daysUntilSat));
  } else {
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed != null) target = parsed;
  }
  final y = target.year.toString().padLeft(4, '0');
  final m = target.month.toString().padLeft(2, '0');
  final d = target.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Checks table availability and seating time slots for a restaurant.
final checkAvailability = ai.defineTool(
  name: 'checkAvailability',
  description:
      'Checks table availability, open time slots, and seating areas for a restaurant.',
  inputSchema: CheckAvailabilityInput.$schema,
  outputSchema: CheckAvailabilityOutput.$schema,
  fn: (input, _) async {
    return .response(
      CheckAvailabilityOutput(
        restaurant: input.restaurant.isEmpty ? 'Cymbal Bistro' : input.restaurant,
        date: _resolveIsoDate(input.date),
        partySize: input.partySize,
        available: true,
        availableSlots: const [
          '6:00 PM',
          '6:30 PM',
          '7:00 PM',
          '7:30 PM',
          '8:00 PM',
        ],
        seatingAreas: const [
          'Indoor Dining',
          'Heated Patio',
          'Chef\'s Counter',
        ],
      ),
    );
  },
);

/// Books and confirms a dining reservation, returning a confirmation number.
final confirmReservation = ai.defineTool(
  name: 'confirmReservation',
  description:
      'Books and confirms a dining reservation with the selected date, time, '
      'party size, and seating preferences. Returns a confirmation code.',
  inputSchema: ConfirmReservationInput.$schema,
  outputSchema: ConfirmReservationOutput.$schema,
  fn: (input, _) async {
    final resolvedDate = _resolveIsoDate(input.date);
    final seed =
        (resolvedDate.hashCode ^ input.time.hashCode ^ input.partySize).abs();
    final code = 'CB-${1000 + (seed % 9000)}';
    return .response(
      ConfirmReservationOutput(
        confirmationCode: code,
        restaurant: input.restaurant.isEmpty ? 'Cymbal Bistro' : input.restaurant,
        date: resolvedDate,
        time: input.time,
        partySize: input.partySize,
        seatingArea: (input.seatingArea == null || input.seatingArea!.isEmpty)
            ? 'Indoor Dining'
            : input.seatingArea!,
        specialRequests:
            (input.specialRequests == null || input.specialRequests!.isEmpty)
                ? 'None'
                : input.specialRequests!,
        status: 'Confirmed',
      ),
    );
  },
);

// ---------------------------------------------------------------------------
// Agent Definition
// ---------------------------------------------------------------------------

/// The A2UI-enabled reservation agent.
///
/// Attaching `a2ui(catalog: bistroCatalogId, validate: 'strict')` injects the
/// catalog instructions into the prompt and streams validated UI envelopes to
/// the client. [InMemorySessionStore] persists conversation state across turns.
final uiAgent = ai.defineAgent(
  name: 'uiAgent',
  model: googleAI.gemini('gemini-flash-lite-latest'),
  system:
      'You are the interactive dining concierge for Cymbal Bistro. '
      'Prefer rendering an A2UI surface whenever a result is clearer shown than told '
      '(forms, availability pickers, reservation confirmations). '
      'Keep prose brief (1-2 sentences max); put the substance in the UI.\n\n'
      'Workflow:\n'
      '1. CHECKING AVAILABILITY / MODIFYING:\n'
      '   - Call `checkAvailability` first.\n'
      '   - Render an interactive reservation form Card containing:\n'
      '     * A title ("Reserve a Table at Cymbal Bistro", variant: "h3") and subtitle.\n'
      '     * `DateTimeInput` (variant: "date", label: "Date", value: {"path": "/date"}).\n'
      '     * `ChoicePicker` (displayStyle: "chips", variant: "mutuallyExclusive", '
      'label: "Time Slot", value: {"path": "/time"}) with options from availableSlots.\n'
      '     * `Slider` (label: "Party Size", min: 1, max: 12, step: 1, value: {"path": "/partySize"}).\n'
      '     * `ChoicePicker` (displayStyle: "chips", variant: "mutuallyExclusive", '
      'label: "Seating Area", value: {"path": "/seating"}) with options from seatingAreas.\n'
      '     * `TextField` (label: "Special Requests", value: {"path": "/notes"}).\n'
      '     * Primary `Button` (variant: "primary", label "Confirm Reservation") with action:\n'
      '       `{"event": {"name": "confirmReservation", "context": {'
      '"restaurant": "Cymbal Bistro", "date": {"path": "/date"}, '
      '"time": {"path": "/time"}, "partySize": {"path": "/partySize"}, '
      '"seatingArea": {"path": "/seating"}, "specialRequests": {"path": "/notes"}}}}`.\n'
      '   - Always emit `updateDataModel` envelopes to pre-populate `/date` (use the exact '
      'YYYY-MM-DD string from checkAvailability), `/time` (e.g. ["7:00 PM"]), `/partySize` '
      '(number), `/seating` (e.g. ["Indoor Dining"]), and `/notes` ("").\n\n'
      '2. CONFIRMING RESERVATION:\n'
      '   - When the user clicks Confirm (action "confirmReservation"), extract the values '
      'from the action context (if a value like time or seatingArea is a single-element list '
      'e.g. ["7:30 PM"], pass the string "7:30 PM") and call `confirmReservation`.\n'
      '   - Render a "Reservation Confirmed!" Card featuring:\n'
      '     * A header Row with a `check` Icon and title ("Reservation Confirmed!", variant: "h3").\n'
      '     * The confirmation code prominently (e.g. "**Confirmation Code:** #CB-xxxx").\n'
      '     * Summary lines for Restaurant, Date, Time, Party Size, Seating Area, and Special Requests.\n'
      '     * A secondary `Button` (variant: "borderless" or "default", label "Modify Reservation") '
      'with action `{"event": {"name": "modifyReservation", "context": {'
      '"date": {"path": "/date"}, "partySize": {"path": "/partySize"}}}}`.',
  tools: [checkAvailability, confirmReservation],
  use: [
    a2ui(catalog: bistroCatalogId, validate: 'strict'),
    retry(),
  ],
  store: InMemorySessionStore(),
);
