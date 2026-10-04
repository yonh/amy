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

  String get code => pairCode(fingerprint);

  Map<String, dynamic> infoJson() => {
        'protocol': kProtocolVersion,
        'fingerprint': fingerprint,
        'alias': alias,
        'platform': platformName(platform),
        'model': model,
        'port': port,
        'code': code,
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
