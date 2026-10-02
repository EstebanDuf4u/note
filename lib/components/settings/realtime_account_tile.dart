import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/routes.dart';
import 'package:saber/data/sync/realtime/account_syncer.dart';
import 'package:saber/i18n/strings.g.dart';

/// Shows which Note+ account this device is signed in to,
/// and opens the account page when tapped.
class const RealtimeAccountTile({super.key}) extends HookWidget {
  @override
  Widget build(BuildContext context) {
    final token = useValueListenable(stows.realtimeToken);
    final username = useValueListenable(stows.realtimeUsername);
    final syncState = useValueListenable(AccountSyncer.instance.state);
    final signedIn = token.isNotEmpty;
    final colorScheme = ColorScheme.of(context);

    return ListTile(
      visualDensity: VisualDensity.standard,
      onTap: () => context.push(RoutePaths.account),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.onPrimaryContainer,
        child: Icon(signedIn ? Icons.person : Icons.person_outline),
      ),
      title: Text(
        signedIn ? t.account.signedInAs(u: username) : t.account.signedOut,
      ),
      subtitle: Text(
        signedIn ? accountSyncStateLabel(syncState) : t.account.tapToSignIn,
      ),
      trailing: signedIn ? Icon(accountSyncStateIcon(syncState)) : null,
    );
  }
}

String accountSyncStateLabel(AccountSyncState state) => switch (state) {
  .signedOut => t.account.signedOut,
  .syncing => t.account.status.syncing,
  .upToDate => t.account.status.upToDate,
  .offline => t.account.status.offline,
};

IconData accountSyncStateIcon(AccountSyncState state) => switch (state) {
  .signedOut || .offline => Icons.cloud_off,
  .syncing => Icons.cloud_sync,
  .upToDate => Icons.cloud_done,
};
