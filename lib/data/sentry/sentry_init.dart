import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:saber/data/is_this_a_test.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/sentry/sentry_filter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sentry_logging/sentry_logging.dart';

export 'package:sentry_flutter/sentry_flutter.dart' show SentryWidget;

/// Whether Sentry can be enabled in this build.
///
/// Error reports would go to the Saber project, which this app is a fork of,
/// so this is only true in tests until Note+ has its own Sentry project.
bool get isSentryAvailable => isThisATest;

/// Whether Sentry was initialized when the app started.
///
/// This flag does not change after initialization. Changes to the user's consent
/// (mostly*) take place after restarting the app.
/// (*When revoked, [SentryFilter.beforeSend] discards all further events.)
bool get isSentryEnabled => _isSentryEnabled;
late bool _isSentryEnabled;

FutureOr<void> initSentry(FutureOr<void> Function() appRunner) async {
  SentryWidgetsFlutterBinding.ensureInitialized();
  Stows.markAsOnMainIsolate();
  await stows.sentryConsent.waitUntilRead();
  _isSentryEnabled = switch (stows.sentryConsent.value) {
    .unknown => false,
    .granted => true,
    .denied => false,
  };

  if (!isSentryAvailable || !isSentryEnabled) {
    return appRunner();
  }

  await SentryFlutter.init(populateSentryOptions, appRunner: appRunner);
}

@visibleForTesting
void populateSentryOptions(SentryFlutterOptions options) {
  options.dsn = 'https://66937061678418b37c7b29cbfa1a0105@o4509780708229120.ingest.de.sentry.io/4509780710654032';
  options.addIntegration(LoggingIntegration());
  options.environment = kDebugMode ? 'debug' : 'release';
  // Filter data before sending
  options.beforeSend = SentryFilter.beforeSend;
  // Reduce data collection
  options.sendDefaultPii = false;
  options.enableAutoPerformanceTracing = false;
  options.enableUserInteractionTracing = false;
  options.reportViewHierarchyIdentifiers = false;
  options.useFlutterBreadcrumbTracking(); // disable native breadcrumbs
  options.enableAppLifecycleBreadcrumbs = false;
  options.enableBrightnessChangeBreadcrumbs = false;
  options.enableUserInteractionBreadcrumbs = false;
}

/// Tests typically don't use [initSentry] so this just sets the flag
/// so we don't get late initialization errors.
@visibleForTesting
void disableSentryForTesting() {
  _isSentryEnabled = false;
}
