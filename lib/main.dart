import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/amy_app.dart';
import 'core/engine.dart';
import 'core/identity.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final identity = await loadIdentity();
  final engine = TransferEngine(identity: identity);
  await engine.init();
  runApp(
    ProviderScope(
      overrides: [
        identityProvider.overrideWith((_) => identity),
        engineProvider.overrideWith((_) => engine),
      ],
      child: const AmyApp(),
    ),
  );
}
