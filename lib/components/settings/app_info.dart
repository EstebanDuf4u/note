import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/is_this_a_test.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/version.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:url_launcher/url_launcher.dart';

class const AppInfo({super.key}) extends StatelessWidget {
  static final Uri licenseUrl = Uri.parse(
    'https://www.gnu.org/licenses/gpl-3.0.html',
  );

  // Used by Saber features that Note+ doesn't show (Nextcloud, Sentry,
  // update checks), so they still point to Saber's.
  static final Uri privacyPolicyUrl = Uri.parse(
    'https://saber.adil.hanney.org/privacy-policy/',
  );
  static final Uri releasesUrl = Uri.parse(
    'https://github.com/saber-notes/saber/releases',
  );

  /// Note+ is a fork of Saber, whose source code is here.
  static final Uri saberUrl = Uri.parse('https://github.com/saber-notes/saber');

  static String get info => [
    // Tests use static values to improve reducibility
    if (isThisATest) 'v1.35.1' else 'v$buildName',
    if (FlavorConfig.flavor.isNotEmpty) FlavorConfig.flavor,
    if (kDebugMode && !isThisATest) t.appInfo.debug,
    if (isThisATest) '(135010)' else '($buildNumber)',
  ].join(' ');

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => _showAboutDialog(context),
      child: ValueListenableBuilder(
        valueListenable: stows.locale,
        builder: (context, _, _) => Text(info),
      ),
    );
  }

  void _showAboutDialog(BuildContext context) => showAboutDialog(
    context: context,
    applicationVersion: info,
    applicationIcon: SvgPicture.asset(
      'assets/icon/icon.svg',
      width: 50,
      height: 50,
    ),
    applicationLegalese: t.appInfo.licenseNotice(buildYear: buildYear),
    children: [
      const SizedBox(height: 10),
      TextButton(
        onPressed: () => launchUrl(licenseUrl),
        child: SizedBox(
          width: double.infinity,
          child: Text(t.appInfo.licenseButton),
        ),
      ),
      TextButton(
        onPressed: () => launchUrl(saberUrl),
        child: SizedBox(
          width: double.infinity,
          child: Text(t.appInfo.basedOnSaber),
        ),
      ),
    ],
  );
}
