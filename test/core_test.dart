import 'dart:io';

import 'package:amy/core/files.dart';
import 'package:amy/core/models.dart';
import 'package:amy/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pairCode', () {
    test('is 6 digits and deterministic per fingerprint', () {
      final a = pairCode('fp-abc');
      expect(a, matches(RegExp(r'^\d{6}$')));
      expect(pairCode('fp-abc'), a);
    });
  });

  group('TransferMessage json round-trip', () {
    test('preserves fields and statuses', () {
      final msg = TransferMessage(
        id: 'm1',
        peerId: 'fp-1',
        outgoing: true,
        files: [
          TransferFile(id: 'f0', name: 'a.pdf', size: 10, path: '/tmp/a.pdf'),
          TransferFile(id: 'f1', name: 'b.zip', size: 20),
        ],
        status: MessageStatus.active,
      );
      final back = TransferMessage.fromJson(msg.toJson());
      expect(back.id, 'm1');
      expect(back.files.length, 2);
      expect(back.files.first.kind, FileKind.doc);
      expect(back.files.last.kind, FileKind.archive);
      expect(back.status, MessageStatus.active);
      expect(back.totalBytes, 30);
    });
  });

  group('file naming', () {
    test('sanitizeFileName strips path separators', () {
      expect(sanitizeFileName('../a/b.txt'), '.._a_b.txt');
      expect(sanitizeFileName(''), 'file');
      expect(sanitizeFileName('..'), 'file');
    });

    test('dedupePath avoids collisions', () async {
      final dir = await Directory.systemTemp.createTemp('amytest');
      try {
        expect(dedupePath(dir.path, 'a.txt'), endsWith('/a.txt'));
        File('${dir.path}/a.txt').writeAsStringSync('x');
        expect(dedupePath(dir.path, 'a.txt'), endsWith('/a (1).txt'));
        File('${dir.path}/a (1).txt').writeAsStringSync('x');
        expect(dedupePath(dir.path, 'a.txt'), endsWith('/a (2).txt'));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('SendPlan json round-trip', () {
    test('preserves trigger, status and paths', () {
      final plan = SendPlan(
        id: 'p1',
        peerFingerprint: 'fp-x',
        peerAlias: 'iPhone 17',
        filePaths: ['/tmp/a.txt', '/tmp/b.zip'],
        runAt: DateTime(2026, 10, 5, 9),
        status: PlanStatus.pending,
        messageId: 'm9',
      );
      final back = SendPlan.fromJson(plan.toJson());
      expect(back.id, 'p1');
      expect(back.timed, isTrue);
      expect(back.filePaths, hasLength(2));
      expect(back.status, PlanStatus.pending);
      expect(back.messageId, 'm9');
      final online = SendPlan.fromJson(
          SendPlan(id: 'p2', peerFingerprint: 'f', peerAlias: 'a', filePaths: const [])
              .toJson());
      expect(online.timed, isFalse);
      expect(online.runAt, isNull);
    });
  });

  group('Peer', () {
    test('online reflects lastSeen', () {
      final p = Peer(
        fingerprint: 'x',
        alias: 'dev',
        platform: DevicePlatform.macos,
        model: 'Mac mini',
        host: '1.2.3.4',
        port: 47777,
      );
      expect(p.online, isTrue);
      p.lastSeen = DateTime.now().subtract(const Duration(minutes: 30));
      expect(p.online, isFalse);
      expect(p.baseUri.toString(), 'http://1.2.3.4:47777');
    });
  });
}
