import 'package:ahoy/Ahoy/core/enums.dart';
import 'package:ahoy/Ahoy/models/local_user.dart';
import 'package:ahoy/Ahoy/models/nearby_peer.dart';
import 'package:ahoy/Ahoy/services/crypto/peer_trust_store.dart';
import 'package:ahoy/Ahoy/widgets/common/peer_avatar.dart';
import 'package:ahoy/Ahoy/widgets/discover/peer_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ninth-review follow-up, batch 5: items 17 (tappable trust explanations),
/// 20 (gender field dropped) and 23 (initials on a shortId-derived color)
/// of the external UI/UX review.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the trust marker opens an explanation sheet (UI review #17)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerCard(
            peer: NearbyPeer(
              uuid: '22222222-2222-4222-8222-222222222222',
              shortId: 'PEER12',
              displayName: 'Sam Peer',
              transport: TransportMode.lan,
              lastSeen: DateTime.now(),
            ),
            onConnect: () {},
            trustState: PeerTrustState.unverified,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.help_outline));
    await tester.pumpAndSettle();

    expect(find.text('Identity not verified yet'), findsOneWidget);
    expect(find.textContaining('announced this key itself'), findsOneWidget);
    expect(
      find.textContaining('safety number on the peer profile'),
      findsOneWidget,
    );
  });

  testWidgets('verified peers get their own explanation', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerCard(
            peer: NearbyPeer(
              uuid: '22222222-2222-4222-8222-222222222222',
              shortId: 'PEER12',
              displayName: 'Sam Peer',
              transport: TransportMode.lan,
              lastSeen: DateTime.now(),
            ),
            onConnect: () {},
            trustState: PeerTrustState.verifiedBySafetyNumber,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.verified_user));
    await tester.pumpAndSettle();

    expect(find.text('Identity verified'), findsOneWidget);
  });

  testWidgets('avatars show initials with a shortId-derived color (#23)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PeerAvatar(name: 'John Doe', shortId: 'AAAAAA', radius: 24),
              PeerAvatar(name: 'John Doe', shortId: 'AAAAAA', radius: 24),
              PeerAvatar(name: 'John Doe', shortId: 'BBBBBB', radius: 24),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('JD'), findsNWidgets(3));
    final avatars =
        tester.widgetList<CircleAvatar>(find.byType(CircleAvatar)).toList();
    expect(
      avatars[0].backgroundColor,
      avatars[1].backgroundColor,
      reason: 'the same shortId always maps to the same color',
    );
    expect(
      avatars[0].backgroundColor,
      isNot(avatars[2].backgroundColor),
      reason: 'a different shortId maps to a different palette color',
    );
  });

  test('LocalUser no longer carries gender; legacy keys are ignored (#20)',
      () {
    final user = LocalUser(
      id: 'id-1',
      username: 'Sam',
      interests: const [],
      publicKeyPEM: 'key',
      shortId: 'SAM123',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    expect(user.toJson().containsKey('gender'), isFalse);

    // A profile stored by an older build may still carry the key: it is
    // ignored rather than breaking the load.
    final legacy = LocalUser.fromJson({
      ...user.toJson(),
      'gender': 'female',
    });
    expect(legacy.username, 'Sam');
  });
}
