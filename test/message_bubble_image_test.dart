import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/message.dart';
import 'package:ahoy/Ahoy/services/crypto/local_data_crypto.dart';
import 'package:ahoy/Ahoy/widgets/chat/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
final _pngBytes = base64.decode(_pngB64);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('encrypted images decode asynchronously off the build path',
      (tester) async {
    final crypto = LocalDataCrypto.withKeyForTesting(
      Uint8List.fromList(List.filled(32, 7)),
    );
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('ahoy_bubble_test'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => dir.delete(recursive: true)),
    );
    final file = File('${dir.path}/ahoy_media_test.jpg.ahoyenc');
    await tester.runAsync(
      () => crypto.writeEncryptedFile(file, Uint8List.fromList(_pngBytes)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: Message(
              id: 'm1',
              conversationId: 'c1',
              senderId: 'peer',
              type: MessageType.image,
              content: file.path,
              status: MessageStatus.sent,
              transport: TransportMode.lan,
              timestamp: DateTime.now(),
            ),
            isMine: false,
            localDataCrypto: crypto,
          ),
        ),
      ),
    );

    // First frame: the decode is still in flight, no sync file I/O happened.
    await tester.pump();
    expect(find.byType(Image), findsNothing);

    // Real file I/O needs runAsync inside widget tests; give the decode a
    // real-time window, then flush the frame it schedules.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    // A few real-time windows so the decode future can complete, with a
    // frame pump after each.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a quarantined media file renders the unavailable placeholder',
      (tester) async {
    final crypto = LocalDataCrypto.withKeyForTesting(
      Uint8List.fromList(List.filled(32, 7)),
    );
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('ahoy_bubble_test2'),
    ))!;
    addTearDown(
      () => tester.runAsync(() => dir.delete(recursive: true)),
    );
    final file = File('${dir.path}/ahoy_media_gone.jpg.ahoyenc');
    await tester.runAsync(
      () => file.writeAsString('not an ahoy envelope'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: Message(
              id: 'm2',
              conversationId: 'c1',
              senderId: 'peer',
              type: MessageType.image,
              content: file.path,
              status: MessageStatus.sent,
              transport: TransportMode.lan,
              timestamp: DateTime.now(),
            ),
            isMine: false,
            localDataCrypto: crypto,
          ),
        ),
      ),
    );

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    // A few real-time windows so the decode future can complete, with a
    // frame pump after each.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('[Image unavailable]'), findsOneWidget);
  });
}
