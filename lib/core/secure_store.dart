import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// OS-backed secret storage for credentials that must not sit in
/// plaintext SharedPreferences: Keychain on iOS/macOS, Keystore-backed
/// storage on Android, libsecret on Linux.
///
/// All failures are swallowed — callers fall back to the legacy
/// plaintext copy rather than lose a credential, and availability is
/// reported via the bool return so plaintext is only stripped after a
/// confirmed write.
class SecureStore {
  SecureStore._();

  static const remoteToken = 'amy.ai.remoteToken';
  static const remoteTokens = 'amy.ai.remoteTokens';
  static const llmApiKey = 'amy.ai.llmApiKey';

  static const _s = FlutterSecureStorage();

  static Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null;
    }
  }

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
    } catch (_) {
      return false;
    }
  }
}
