import 'dart:io';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/widgets/chat/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ninth-review follow-up, batch 3: UI items 21 and 22 — theme-aware
/// semantic colors instead of hardcoded pale tints and raw reds, and no
/// text smaller than 12px anywhere in the app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message textMessage() => Message(
    id: 'm1',
    conversationId: 'c1',
    senderId: 'peer',
    type: MessageType.text,
    content: 'hello there',
    status: MessageStatus.sent,
    transport: TransportMode.lan,
    timestamp: DateTime.utc(2026, 1, 1, 12, 30),
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('message footer text is legible in $brightness mode',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness, useMaterial3: true),
          home: Scaffold(
            body: MessageBubble(message: textMessage(), isMine: true),
          ),
        ),
      );
      await tester.pump();

      final timeFinder = find.text('12:30');
      expect(timeFinder, findsOneWidget);
      final style = tester.widget<Text>(timeFinder).style;
      expect(
        style!.fontSize,
        greaterThanOrEqualTo(12),
        reason: 'timestamps must not shrink below 12px ($brightness)',
      );
      // 0.6-alpha text failed contrast; the footer now stays near full
      // opacity of the bubble's text color.
      expect(style.color!.a, greaterThanOrEqualTo(0.8));
    });
  }

  test('no hardcoded pale tints or raw reds remain in the app', () {
    final offenders = <String>[];
    for (final entity in Directory('lib/Ahoy')
        .listSync(recursive: true)
        .whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      final lines = src.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // The recording indicator is a status color, not a semantic error:
        // red is conventional for "recording" in both themes.
        final isRecordingIndicator =
            entity.path.endsWith('message_input_bar.dart') &&
                line.contains('Colors.red');
        if (!isRecordingIndicator) {
          if (line.contains('Colors.red')) {
            offenders.add('${entity.path}:${i + 1} Colors.red');
          }
        }
        if (line.contains('shade50') || line.contains('shade100')) {
          offenders.add('${entity.path}:${i + 1} pale shade');
        }
        if (line.contains(RegExp(r'fontSize: (9|10|11)\b'))) {
          offenders.add('${entity.path}:${i + 1} tiny text');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('the peer profile uses semantic theme containers', () {
    final src = File(
      'lib/Ahoy/screens/profile/peer_profile_screen.dart',
    ).readAsStringSync();
    expect(src, contains('colorScheme.tertiaryContainer'),
        reason: 'safety-number panel');
    expect(src, contains('colorScheme.errorContainer'),
        reason: 'blocked panel');
    expect(src, isNot(contains('Colors.orange.shade')));
  });
}
