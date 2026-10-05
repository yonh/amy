import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Result of a secure-storage read: [failed] distinguishes a store
/// error (transient keychain contention, entitlement issues) from a
/// legitimately absent key — callers degrade to the prefs copy only on
/// failure, never treating "error" as "empty".
class SecureRead {
  const SecureRead(this.value, {this.failed = false});

  final String? value;
  final bool failed;
}

/// OS-backed secret storage for credentials that must not sit in
/// plaintext SharedPreferences: Keychain on iOS/macOS, Keystore-backed
/// storage on Android, libsecret on Linux.
///
/// Failures never throw out of here — writes report success via bool
/// so plaintext is only stripped after a confirmed write, and reads
/// distinguish error from absence.
class SecureStore {
  SecureStore._();

  static const remoteToken = 'amy.ai.remoteToken';
  static const remoteTokens = 'amy.ai.remoteTokens';
  static const llmApiKey = 'amy.ai.llmApiKey';

  static const _s = FlutterSecureStorage(
    // The data-protection keychain requires a keychain-access-groups
    // entitlement the Runner doesn't ship — under the sandbox writes
    // fail with errSecMissingEntitlement. The file-based login
    // keychain needs no entitlement and is still encrypted at rest.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static Future<SecureRead> tryRead(String key) async {
    try {
      return SecureRead(await _s.read(key: key));
    } catch (e) {
      debugPrint('SecureStore.read($key) failed: $e');
      return const SecureRead(null, failed: true);
    }
  }

  static Future<String?> read(String key) async =>
      (await tryRead(key)).value;

  /// Writes [value]; an empty value deletes the entry. Returns whether
  /// the store accepted the write — on failure callers keep their
  /// existing plaintext fallback.
  static Future<bool> write(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _s.delete(key: key);
      } else {
        await _s.write(key: key, value: value);
      }
      return true;
    } catch (e) {
      debugPrint('SecureStore.write($key) failed: $e');
      return false;
    }
  }
}
