import 'dart:io';

import 'package:args/args.dart';
import 'package:noteplus_server/relay_server.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: '8787')
    ..addOption(
      'data',
      abbr: 'd',
      defaultsTo: 'data',
      help: 'The directory to store the accounts and their notes in.',
    )
    ..addFlag(
      'registration',
      defaultsTo: true,
      help:
          'Whether new accounts can be created. '
          'Turn it off once everyone has their account.',
    )
    ..addOption(
      'web',
      help:
          'The directory of the web editor. '
          'Defaults to the `web` directory next to this program.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exit(64);
  }
  if (args.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }

  // the web editor is next to this script, in `server/web`
  final webDirectory = args.option('web') != null
      ? Directory(args.option('web')!)
      : Directory.fromUri(Platform.script.resolve('../web'));
  final server = RelayServer(
    dataDirectory: Directory(args.option('data')!),
    allowRegistration: args.flag('registration'),
    webDirectory: webDirectory.existsSync() ? webDirectory : null,
  );
  await server.start(port: int.parse(args.option('port')!));

  stdout.writeln('Note+ realtime server listening on port ${server.port}');
  if (server.webDirectory != null) {
    stdout.writeln(
      'The web editor is at http://<this machine>:${server.port}/',
    );
  }
  if (server.allowRegistration) {
    stdout.writeln(
      'Anyone who can reach this server can create an account. '
      'Use --no-registration to prevent that.',
    );
  }
}
