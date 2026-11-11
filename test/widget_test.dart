import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/widgets/auth/password_field.dart';
import 'package:ahoy/Ahoy/widgets/common/transport_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('TransportBadge renders label for LAN and nothing for none', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TransportBadge(mode: TransportMode.lan)),
      ),
    );
    expect(find.text('LAN'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TransportBadge(mode: TransportMode.none)),
      ),
    );
    expect(find.byType(Chip), findsNothing);
  });

  testWidgets('TransportBadges render in priority order', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TransportBadges(transports: {
            TransportMode.ble,
            TransportMode.lan,
            TransportMode.wifiDirect,
          }),
        ),
      ),
    );

    final wifiDx = tester.getTopLeft(find.text('WiFi Direct')).dx;
    final lanDx = tester.getTopLeft(find.text('LAN')).dx;
    final bleDx = tester.getTopLeft(find.text('BLE')).dx;
    expect(wifiDx < lanDx && lanDx < bleDx, isTrue);
  });

  testWidgets('PasswordField default validator requires 8+ characters', (
    tester,
  ) async {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Form(
            key: formKey,
            child: PasswordField(controller: controller),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), 'short');
    expect(formKey.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('At least 8 characters'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'longenough');
    expect(formKey.currentState!.validate(), isTrue);
  });

  testWidgets('PasswordField toggles visibility', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PasswordField(controller: controller)),
      ),
    );

    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(find.byIcon(Icons.visibility), findsOneWidget);
  });
}
