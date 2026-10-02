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

  final server = RelayServer(
    dataDirectory: Directory(args.option('data')!),
    allowRegistration: args.flag('registration'),
  );
  await server.start(port: int.parse(args.option('port')!));

  stdout.writeln('Note+ realtime server listening on port ${server.port}');
  if (server.allowRegistration) {
    stdout.writeln(
      'Anyone who can reach this server can create an account. '
      'Use --no-registration to prevent that.',
    );
  }
}
