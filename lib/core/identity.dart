import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'protocol.dart';

/// Who this device is: a stable fingerprint plus a user-editable alias and the
/// model name reported by the OS.
class SelfIdentity {
  SelfIdentity({
    required this.fingerprint,
    required this.alias,
    required this.platform,
    required this.model,
  });

  final String fingerprint;
  String alias;
  final DevicePlatform platform;
  final String model;

  int port = kBasePort;

  /// Advertised when this device's remote agent API accepts leader calls.
  bool agentCapable = false;

  String get code => pairCode(fingerprint);

  Map<String, dynamic> infoJson() => {
        'protocol': kProtocolVersion,
        'fingerprint': fingerprint,
        'alias': alias,
        'platform': platformName(platform),
        'model': model,
        'port': port,
        'agentCapable': agentCapable,
      };
}

DevicePlatform _currentPlatform() {
  if (kIsWeb) return DevicePlatform.unknown;
  if (Platform.isIOS) return DevicePlatform.ios;
  if (Platform.isMacOS) return DevicePlatform.macos;
  if (Platform.isAndroid) return DevicePlatform.android;
  if (Platform.isWindows) return DevicePlatform.windows;
  if (Platform.isLinux) return DevicePlatform.linux;
  return DevicePlatform.unknown;
}

Future<SelfIdentity> loadIdentity() async {
  final prefs = await SharedPreferences.getInstance();
  var fingerprint = prefs.getString('fingerprint');
  if (fingerprint == null) {
    fingerprint = randomId(16);
    await prefs.setString('fingerprint', fingerprint);
  }

  var platform = _currentPlatform();
  var model = '';
  var defaultAlias = Platform.localHostname;
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isMacOS) {
      model = (await info.macOsInfo).model;
    } else if (Platform.isIOS) {
      final ios = await info.iosInfo;
      model = ios.utsname.machine;
      defaultAlias = ios.name.isNotEmpty ? ios.name : 'iPhone';
      if (ios.model.toLowerCase().contains('ipad')) {
        platform = DevicePlatform.ipados;
      }
    } else if (Platform.isAndroid) {
      model = (await info.androidInfo).model;
      if (model.isNotEmpty) defaultAlias = model;
    }
  } catch (_) {
    // Device info is cosmetic — keep defaults.
  }

  final savedAlias = prefs.getString('alias') ?? '';
  return SelfIdentity(
    fingerprint: fingerprint,
    alias: savedAlias.isNotEmpty ? savedAlias : defaultAlias,
    platform: platform,
    model: model,
  );
}

Future<void> saveAlias(String alias) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('alias', alias);
}

/// First-run gate: false until the user finishes (or dismisses) the
/// onboarding flow once.
Future<bool> isOnboarded() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('onboarded') ?? false;
}

Future<void> markOnboarded() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('onboarded', true);
}

/// AI/agent safety policy — persisted under 'ai.policy'.
Future<AiPolicy> loadAiPolicy() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('ai.policy');
  if (raw == null) return AiPolicy();
  try {
    return AiPolicy.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return AiPolicy();
  }
}

Future<void> saveAiPolicy(AiPolicy p) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('ai.policy', jsonEncode(p.toJson()));
}

/// Leader-side: remote tokens remembered per member fingerprint.
Future<Map<String, String>> loadRemoteTokens() async {
  final prefs = await SharedPreferences.getInstance();
  try {
    return (jsonDecode(prefs.getString('ai.remoteTokens') ?? '{}') as Map)
        .cast<String, String>();
  } catch (_) {
    return {};
  }
}

Future<void> saveRemoteTokens(Map<String, String> tokens) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('ai.remoteTokens', jsonEncode(tokens));
}

/// Filesystem isolation for agent sends — persisted under 'security.scope'.
Future<SecurityScope> loadSecurityScope() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('security.scope');
  if (raw == null) return SecurityScope();
  try {
    return SecurityScope.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    return SecurityScope();
  }
}

Future<void> saveSecurityScope(SecurityScope s) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('security.scope', jsonEncode(s.toJson()));
}

/// First-run default whitelist (~/Downloads + ~/Documents), applied once
/// — afterwards the stored scope is authoritative, including "empty".
Future<SecurityScope> loadSecurityScopeOrSeed() async {
  final s = await loadSecurityScope();
  final prefs = await SharedPreferences.getInstance();
  if ((prefs.getBool('security.seeded') ?? false) || s.dirs.isNotEmpty) {
    return s;
  }
  await prefs.setBool('security.seeded', true);
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null) {
    for (final d in ['$home/Downloads', '$home/Documents']) {
      if (Directory(d).existsSync()) s.dirs.add(d);
    }
    if (s.dirs.isNotEmpty) await saveSecurityScope(s);
  }
  return s;
}
