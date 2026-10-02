import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:saber/components/settings/realtime_account_tile.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/sync/realtime/account_syncer.dart';
import 'package:saber/data/sync/realtime/realtime_account.dart';
import 'package:saber/i18n/strings.g.dart';

const _width = 400.0;

/// Where the user signs in to (or out of) the Note+ account
/// that keeps their notes in sync between their devices.
class const RealtimeAccountPage({super.key}) extends HookWidget {
  @override
  Widget build(BuildContext context) {
    final token = useValueListenable(stows.realtimeToken);

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: kToolbarHeight,
        title: Text(t.account.title),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const .all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _width),
              child: token.isEmpty ? const _SignInForm() : const _SignedIn(),
            ),
          ),
        ),
      ),
    );
  }
}

String _errorMessage(String code) => switch (code) {
  'invalid_server' => t.account.errors.invalidServer,
  'unreachable' => t.account.errors.unreachable,
  'wrong_credentials' => t.account.errors.wrongCredentials,
  'username_taken' => t.account.errors.usernameTaken,
  'invalid_username' => t.account.errors.invalidUsername,
  'weak_password' => t.account.errors.weakPassword,
  'registration_closed' => t.account.errors.registrationClosed,
  'too_many_attempts' => t.account.errors.tooManyAttempts,
  _ => t.account.errors.unknown,
};

class const _SignInForm() extends HookWidget {
  @override
  Widget build(BuildContext context) {
    final server = useTextEditingController(text: stows.realtimeUrl.value);
    final username = useTextEditingController(
      text: stows.realtimeUsername.value,
    );
    final password = useTextEditingController();
    final busy = useState(false);
    final error = useState<String?>(null);
    final colorScheme = ColorScheme.of(context);

    Future<void> submit({required bool register}) async {
      if (busy.value) return;
      if (server.text.trim().isEmpty ||
          username.text.trim().isEmpty ||
          password.text.isEmpty) {
        error.value = t.account.errors.missingFields;
        return;
      }

      busy.value = true;
      error.value = null;
      try {
        await RealtimeAccount.signIn(
          server: server.text,
          username: username.text,
          password: password.text,
          register: register,
        );
        // the page shows the account now, so this form is gone
        return;
      } on RealtimeAccountException catch (e) {
        if (!context.mounted) return;
        error.value = _errorMessage(e.code);
      }
      busy.value = false;
    }

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: .stretch,
        mainAxisSize: .min,
        children: [
          Icon(Icons.sync, size: 48, color: colorScheme.primary),
          const SizedBox(height: 16),
          Text(t.account.intro, textAlign: .center),
          const SizedBox(height: 24),
          TextField(
            controller: server,
            enabled: !busy.value,
            autocorrect: false,
            keyboardType: .url,
            textInputAction: .next,
            decoration: InputDecoration(
              labelText: t.account.server,
              hintText: t.account.serverHint,
              prefixIcon: const Icon(Icons.dns),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: username,
            enabled: !busy.value,
            autocorrect: false,
            autofillHints: const [AutofillHints.username],
            textInputAction: .next,
            decoration: InputDecoration(
              labelText: t.account.username,
              prefixIcon: const Icon(Icons.person),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: password,
            enabled: !busy.value,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => submit(register: false),
            decoration: InputDecoration(
              labelText: t.account.password,
              prefixIcon: const Icon(Icons.lock),
              border: const OutlineInputBorder(),
            ),
          ),
          if (error.value case final message?) ...[
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: .center,
              style: TextStyle(color: colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy.value ? null : () => submit(register: false),
            child: Text(t.account.signIn),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: busy.value ? null : () => submit(register: true),
            child: Text(t.account.createAccount),
          ),
          const SizedBox(height: 24),
          Text(
            t.account.limitations,
            textAlign: .center,
            style: TextTheme.of(context).bodySmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class const _SignedIn() extends HookWidget {
  @override
  Widget build(BuildContext context) {
    final username = useValueListenable(stows.realtimeUsername);
    final server = useValueListenable(stows.realtimeUrl);
    final syncState = useValueListenable(AccountSyncer.instance.state);
    final colorScheme = ColorScheme.of(context);
    final textTheme = TextTheme.of(context);

    return Column(
      crossAxisAlignment: .stretch,
      mainAxisSize: .min,
      children: [
        CircleAvatar(
          radius: 36,
          backgroundColor: colorScheme.primaryContainer,
          foregroundColor: colorScheme.onPrimaryContainer,
          child: const Icon(Icons.person, size: 40),
        ),
        const SizedBox(height: 16),
        Text(
          t.account.signedInAs(u: username),
          textAlign: .center,
          style: textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          server,
          textAlign: .center,
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: .center,
          spacing: 8,
          children: [
            Icon(accountSyncStateIcon(syncState), size: 20),
            Flexible(child: Text(accountSyncStateLabel(syncState))),
          ],
        ),
        const SizedBox(height: 24),
        FilledButton.tonal(
          onPressed: () => unawaited(AccountSyncer.instance.syncNow()),
          child: Text(t.account.syncNow),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => unawaited(RealtimeAccount.signOut()),
          child: Text(t.account.signOut),
        ),
        const SizedBox(height: 8),
        Text(
          t.account.signOutNote,
          textAlign: .center,
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          t.account.limitations,
          textAlign: .center,
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
