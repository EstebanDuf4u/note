import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/routes.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/main.dart';
import 'package:saber/pages/user/account.dart';

void main() {
  group('The app requires an account', () {
    test('when signed out, every page leads to the sign in page', () {
      for (final location in [
        App.initialLocation,
        RoutePaths.edit,
        RoutePaths.account,
        RoutePaths.login,
        RoutePaths.logs,
      ]) {
        expect(
          App.accountRedirect(location, isSignedIn: false),
          RoutePaths.signIn,
          reason: location,
        );
      }
      expect(
        App.accountRedirect(RoutePaths.signIn, isSignedIn: false),
        isNull,
        reason: 'Already on the sign in page',
      );
    });

    test('when signed in, the sign in page leads to the app', () {
      expect(
        App.accountRedirect(RoutePaths.signIn, isSignedIn: true),
        App.initialLocation,
      );
      for (final location in [App.initialLocation, RoutePaths.edit]) {
        expect(App.accountRedirect(location, isSignedIn: true), isNull);
      }
    });
  });

  testWidgets('The sign in page can only be left by signing in', (
    tester,
  ) async {
    FlavorConfig.setup();
    stows.realtimeToken.value = '';
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(home: RealtimeAccountPage(mustSignIn: true)),
      ),
    );
    expect(find.text(t.account.signInRequired), findsOneWidget);
    expect(find.text(t.account.signIn), findsOneWidget);
    expect(find.text(t.account.createAccount), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
  });
}
