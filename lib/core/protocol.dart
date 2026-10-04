/// Wire protocol constants. HTTP + JSON over LAN, modelled loosely on the
/// LocalSend protocol so the shape stays familiar.
///
/// Endpoints on every device:
///   GET  /api/v1/info            -> device info (alias, fingerprint, code)
///   POST /api/v1/prepare-upload  -> offer files; blocks until accepted/declined
///   POST /api/v1/upload?sessionId&fileId&token -> raw body bytes
///   POST /api/v1/cancel?sessionId -> abort an in-flight session
library;

const kProtocolVersion = 1;

/// First HTTP port tried; the server walks [kPortSpan] ports if it is busy.
/// Discovery always carries the real port, so any value works.
const kBasePort = 47777;
const kPortSpan = 10;

const kBonsoirType = '_amy._tcp';
const kServiceName = 'amy';

/// How long the receiver has to accept an incoming offer before it is
/// auto-declined. The sender-side timeout is slightly longer.
const kOfferTimeout = Duration(seconds: 60);
const kOfferClientTimeout = Duration(seconds: 75);

const kInfoPath = '/api/v1/info';
const kPreparePath = '/api/v1/prepare-upload';
const kUploadPath = '/api/v1/upload';
const kCancelPath = '/api/v1/cancel';

/// 6-digit pairing code, rotated every [kCodeWindow]. Derived from the device
/// fingerprint, announced via mDNS TXT and /info — entering the peer's code
/// connects to whichever discovered device currently advertises it.
const kCodeWindow = Duration(minutes: 10);

String pairCode(String fingerprint) {
  final window =
      DateTime.now().millisecondsSinceEpoch ~/ kCodeWindow.inMilliseconds;
  // FNV-1a over fingerprint + rotating window, reduced to 6 digits.
  var hash = 0xcbf29ce484222325;
  for (final unit in '$fingerprint:$window'.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return (hash % 1000000).toString().padLeft(6, '0');
}
