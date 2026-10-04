import 'dart:io';

import 'package:amy/core/ai_brain.dart';
import 'package:amy/core/files.dart';
import 'package:amy/core/llm.dart';
import 'package:amy/core/models.dart';
import 'package:path/path.dart' as p;
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

  group('AiPolicy', () {
    test('json round-trip preserves mode, threshold and remote flag', () {
      final p = AiPolicy(
        mode: AiMode.auto,
        autoApproveBytes: 128 * 1024 * 1024,
        allowRemoteControl: true,
        remoteToken: 'tok123',
      );
      final r = AiPolicy.fromJson(p.toJson());
      expect(r.mode, AiMode.auto);
      expect(r.autoApproveBytes, 128 * 1024 * 1024);
      expect(r.allowRemoteControl, isTrue);
      expect(r.remoteToken, 'tok123');
      // Public view never leaks the token value.
      expect(p.toPublicJson().containsKey('remoteToken'), isFalse);
      expect(p.toPublicJson()['remoteTokenSet'], isTrue);
    });
  });

  group('SecurityScope', () {
    test('json round-trip preserves dirs and strict flag', () {
      final s = SecurityScope(dirs: ['/a', '/b/c'], strict: true);
      final r = SecurityScope.fromJson(s.toJson());
      expect(r.dirs, ['/a', '/b/c']);
      expect(r.strict, isTrue);
    });

    test('pathWithinRoots matches inside dirs, not siblings or parents', () {
      const roots = ['/home/u/Downloads', '/data/staged'];
      expect(pathWithinRoots('/home/u/Downloads/x.txt', roots), isTrue);
      expect(pathWithinRoots('/data/staged', roots), isTrue);
      expect(pathWithinRoots('/home/u/Downloads2/x', roots), isFalse);
      expect(pathWithinRoots('/home/u/x', roots), isFalse);
      expect(pathWithinRoots('/etc/passwd', roots), isFalse);
      // Callers normalize first — `..` collapsing escapes the root.
      expect(pathWithinRoots(
          p.normalize('/home/u/Downloads/../secret'), roots), isFalse);
    });
  });

  group('LlmConfig', () {
    test('json round-trip and defaults', () {
      final c = LlmConfig(
          baseUrl: 'https://x.test', apiKey: 'k', model: 'm-1');
      final r = LlmConfig.fromJson(c.toJson());
      expect(r.baseUrl, 'https://x.test');
      expect(r.apiKey, 'k');
      expect(r.model, 'm-1');
      expect(r.configured, isTrue);
      expect(LlmConfig.fromJson(null).configured, isFalse);
      expect(LlmConfig.fromJson({'apiKey': ' ', 'model': ' '}).configured,
          isFalse);
    });
  });

  group('parseBrainAction', () {
    test('extracts the action object from prose and code fences', () {
      const fenced = '好的，我来安排。\n```json\n'
          '{"action":"send","peer":"iPhone","files":["/tmp/a.txt"]}\n```';
      final a = parseBrainAction(fenced);
      expect(a?['action'], 'send');
      expect(a?['peer'], 'iPhone');
      expect((a?['files'] as List).single, '/tmp/a.txt');
    });

    test('rejects non-action JSON and plain prose', () {
      expect(parseBrainAction('{"foo":1}'), isNull);
      expect(parseBrainAction('没有文件可以发'), isNull);
      expect(parseBrainAction('{broken'), isNull);
    });
  });
}
