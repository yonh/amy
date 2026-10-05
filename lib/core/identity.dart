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

/// Reads a secure key with one retry on transient errors. Keeps the
/// error/absent distinction: callers must never write into a store
/// whose state they couldn't verify — that could clobber a newer
/// credential the failed reads couldn't see.
Future<SecureRead> _readSecret(String key) async {
  final r = await SecureStore.tryRead(key);
  return r.failed ? SecureStore.tryRead(key) : r;
}

/// Writes a secure key and tracks the '<key>.broken' prefs flag: a
/// failed write makes the prefs copy authoritative on the next load,
/// so a stale secure value can't resurrect and overwrite newer state.
Future<bool> _writeSecret(
    SharedPreferences prefs, String key, String secret) async {
  final wrote = await SecureStore.write(key, secret);
  await prefs.setBool('$key.broken', !wrote);
  return wrote;
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
  final key = SecureStore.remoteToken;
  final broken = prefs.getBool('$key.broken') ?? false;
  final legacy = p.remoteToken;
  final r = broken
      ? const SecureRead(null, failed: true)
      : await _readSecret(key);
  final sec = r.failed ? null : r.value;
  if (sec != null && sec.isNotEmpty) {
    p.remoteToken = sec;
    if (legacy.isNotEmpty) await saveAiPolicy(p); // scrub plaintext copy
  } else if (legacy.isNotEmpty &&
      !r.failed && // unverifiable store → degrade, don't write back
      await SecureStore.write(key, legacy)) {
    await prefs.setBool('$key.broken', false);
    await saveAiPolicy(p); // strip after the move succeeded
  }
  return p;
}

Future<void> saveAiPolicy(AiPolicy p) async {
  final prefs = await SharedPreferences.getInstance();
  final j = p.toJson();
  final token = (j.remove('remoteToken') as String?) ?? '';
  // token=='' deletes the entry; when the write fails the broken flag
  // makes this prefs copy authoritative instead of a stale secure one.
  if (!await _writeSecret(prefs, SecureStore.remoteToken, token) ||
      token.isEmpty) {
    j['remoteToken'] = token;
  }
  await prefs.setString('ai.policy', jsonEncode(j));
}

/// Leader-side: remote tokens remembered per member fingerprint.
/// The map is a credential store — it lives in secure storage; a prefs
/// copy written by older builds is migrated on first load.
Future<Map<String, String>> loadRemoteTokens() async {
  final prefs = await SharedPreferences.getInstance();
  final key = SecureStore.remoteTokens;
  final broken = prefs.getBool('$key.broken') ?? false;
  final r = broken
      ? const SecureRead(null, failed: true)
      : await _readSecret(key);
  final sec = r.failed ? null : r.value;
  if (sec != null && sec.isNotEmpty) {
    try {
      final m =
          Map<String, String>.from(jsonDecode(sec) as Map);
      if (prefs.getString('ai.remoteTokens') != null) {
        await prefs.remove('ai.remoteTokens'); // scrub plaintext copy
      }
      return m;
    } catch (_) {}
  }
  Map<String, String> m;
  try {
    // Eager from() — a lazy cast<>() would throw later at encode time,
    // outside this try, and take down engine init.
    m = Map<String, String>.from(
        jsonDecode(prefs.getString('ai.remoteTokens') ?? '{}') as Map);
  } catch (_) {
    m = {};
  }
  if (m.isNotEmpty &&
      !r.failed && // unverifiable store → degrade, don't write back
      await SecureStore.write(key, jsonEncode(m))) {
    await prefs.setBool('$key.broken', false);
    await prefs.remove('ai.remoteTokens');
  }
  return m;
}

Future<void> saveRemoteTokens(Map<String, String> tokens) async {
  final prefs = await SharedPreferences.getInstance();
  final j = jsonEncode(tokens);
  // Empty map deletes the entry; a failed write keeps the prefs copy
  // authoritative (broken flag) instead of losing the update.
  if (await _writeSecret(
          prefs, SecureStore.remoteTokens, tokens.isEmpty ? '' : j) &&
      tokens.isNotEmpty) {
    await prefs.remove('ai.remoteTokens');
  } else {
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
  final key = SecureStore.llmApiKey;
  final broken = prefs.getBool('$key.broken') ?? false;
  final legacy = c.apiKey;
  final r = broken
      ? const SecureRead(null, failed: true)
      : await _readSecret(key);
  final sec = r.failed ? null : r.value;
  if (sec != null && sec.isNotEmpty) {
    c.apiKey = sec;
    if (legacy.isNotEmpty) await saveLlmConfig(c); // scrub plaintext copy
  } else if (legacy.isNotEmpty &&
      !r.failed && // unverifiable store → degrade, don't write back
      await SecureStore.write(key, legacy)) {
    await prefs.setBool('$key.broken', false);
    await saveLlmConfig(c); // strip after the move succeeded
  }
  return c;
}

Future<void> saveLlmConfig(LlmConfig c) async {
  final prefs = await SharedPreferences.getInstance();
  final j = c.toJson();
  final key = (j.remove('apiKey') as String?) ?? '';
  if (!await _writeSecret(prefs, SecureStore.llmApiKey, key) ||
      key.isEmpty) {
    j['apiKey'] = key;
  }
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
