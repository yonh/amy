import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm.dart';
import 'models.dart';
import 'protocol.dart';
import 'secure_store.dart';

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

/// AI/agent safety policy — persisted under 'ai.policy'. The remote
/// token lives in secure storage (Keychain/Keystore); older builds kept
/// it inside the prefs blob, so load migrates any plaintext copy.
Future<AiPolicy> loadAiPolicy() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('ai.policy');
  AiPolicy p;
  try {
    p = raw == null
        ? AiPolicy()
        : AiPolicy.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    p = AiPolicy();
  }
  final legacy = p.remoteToken;
  final secured = (await SecureStore.read(SecureStore.remoteToken)) ?? '';
  if (secured.isNotEmpty) {
    p.remoteToken = secured;
    if (legacy.isNotEmpty) await saveAiPolicy(p); // scrub plaintext copy
  } else if (legacy.isNotEmpty &&
      await SecureStore.write(SecureStore.remoteToken, legacy)) {
    await saveAiPolicy(p); // strip after the move succeeded
  }
  return p;
}

Future<void> saveAiPolicy(AiPolicy p) async {
  final prefs = await SharedPreferences.getInstance();
  final j = p.toJson();
  final token = (j.remove('remoteToken') as String?) ?? '';
  final secured = token.isNotEmpty &&
      await SecureStore.write(SecureStore.remoteToken, token);
  if (token.isEmpty) {
    await SecureStore.write(SecureStore.remoteToken, '');
  }
  // Secure storage unavailable → keep the token in prefs rather than
  // lose it (same exposure as before this change).
  if (!secured) j['remoteToken'] = token;
  await prefs.setString('ai.policy', jsonEncode(j));
}

/// Leader-side: remote tokens remembered per member fingerprint.
/// The map is a credential store — it lives in secure storage; a prefs
/// copy written by older builds is migrated on first load.
Future<Map<String, String>> loadRemoteTokens() async {
  final prefs = await SharedPreferences.getInstance();
  final secured = await SecureStore.read(SecureStore.remoteTokens);
  if (secured != null && secured.isNotEmpty) {
    try {
      final m = (jsonDecode(secured) as Map).cast<String, String>();
      if (prefs.getString('ai.remoteTokens') != null) {
        await prefs.remove('ai.remoteTokens'); // scrub plaintext copy
      }
      return m;
    } catch (_) {}
  }
  try {
    final m =
        (jsonDecode(prefs.getString('ai.remoteTokens') ?? '{}') as Map)
            .cast<String, String>();
    if (m.isNotEmpty &&
        await SecureStore.write(
            SecureStore.remoteTokens, jsonEncode(m))) {
      await prefs.remove('ai.remoteTokens');
    }
    return m;
  } catch (_) {
    return {};
  }
}

Future<void> saveRemoteTokens(Map<String, String> tokens) async {
  final prefs = await SharedPreferences.getInstance();
  final j = jsonEncode(tokens);
  if (tokens.isNotEmpty &&
      await SecureStore.write(SecureStore.remoteTokens, j)) {
    await prefs.remove('ai.remoteTokens');
  } else {
    if (tokens.isEmpty) {
      await SecureStore.write(SecureStore.remoteTokens, '');
    }
    await prefs.setString('ai.remoteTokens', j);
  }
}

/// In-app AI assistant endpoint — persisted under 'ai.llmConfig'. The
/// api_key lives in secure storage; older builds kept it inside the
/// prefs blob, so load migrates any plaintext copy.
Future<LlmConfig> loadLlmConfig() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('ai.llmConfig');
  LlmConfig c;
  try {
    c = raw == null
        ? LlmConfig()
        : LlmConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (_) {
    c = LlmConfig();
  }
  final legacy = c.apiKey;
  final secured = (await SecureStore.read(SecureStore.llmApiKey)) ?? '';
  if (secured.isNotEmpty) {
    c.apiKey = secured;
    if (legacy.isNotEmpty) await saveLlmConfig(c); // scrub plaintext copy
  } else if (legacy.isNotEmpty &&
      await SecureStore.write(SecureStore.llmApiKey, legacy)) {
    await saveLlmConfig(c); // strip after the move succeeded
  }
  return c;
}

Future<void> saveLlmConfig(LlmConfig c) async {
  final prefs = await SharedPreferences.getInstance();
  final j = c.toJson();
  final key = (j.remove('apiKey') as String?) ?? '';
  final secured = key.isNotEmpty &&
      await SecureStore.write(SecureStore.llmApiKey, key);
  if (key.isEmpty) {
    await SecureStore.write(SecureStore.llmApiKey, '');
  }
  if (!secured) j['apiKey'] = key; // fallback: keep as before
  await prefs.setString('ai.llmConfig', jsonEncode(j));
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
