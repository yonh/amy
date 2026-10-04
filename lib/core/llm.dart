import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// OpenAI-compatible LLM endpoint powering the in-app AI assistant.
/// Tested against https://apihub.agnes-ai.com (Agnes hub, 2026-10).
class LlmConfig {
  LlmConfig({
    this.baseUrl = 'https://apihub.agnes-ai.com',
    this.apiKey = '',
    this.model = 'agnes-3.0-flash',
  });

  /// Origin of the OpenAI-compatible API (no trailing slash, no /v1).
  String baseUrl;

  /// Bearer credential. Stored locally in SharedPreferences — the same
  /// sensitivity level as the remote-control token.
  String apiKey;

  /// Model id. Text models verified live: agnes-3.0-flash (direct
  /// answers), agnes-2.5-pro / 2.5-flash / 2.0-flash (reasoning models —
  /// slower but deeper). The retired 1.5 series returns 404.
  String model;

  bool get configured => apiKey.trim().isNotEmpty;

  Map<String, dynamic> toJson() =>
      {'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model};

  factory LlmConfig.fromJson(Map<String, dynamic>? j) => LlmConfig(
        baseUrl: (j?['baseUrl'] as String?)?.trim().isNotEmpty == true
            ? (j!['baseUrl'] as String).trim()
            : 'https://apihub.agnes-ai.com',
        apiKey: (j?['apiKey'] as String?) ?? '',
        model: (j?['model'] as String?)?.trim().isNotEmpty == true
            ? (j!['model'] as String).trim()
            : 'agnes-3.0-flash',
      );
}

/// Text models confirmed against GET /v1/models on 2026-10-04. Shown as
/// suggestions in settings; the field stays free-form for new ids.
const kLlmModelSuggestions = [
  'agnes-3.0-flash',
  'agnes-2.5-pro',
  'agnes-2.5-flash',
  'agnes-2.0-flash',
];

class LlmException implements Exception {
  LlmException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Minimal OpenAI-compatible chat client (POST {base}/v1/chat/completions).
class LlmClient {
  LlmClient(this.config);

  final LlmConfig config;

  HttpClient _newHttp() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 10);

  Uri get _base => Uri.parse(config.baseUrl.trim().replaceAll(RegExp(r'/+$'), ''));

  /// Returns the assistant message content. Reasoning models may also
  /// emit `reasoning_content` — callers only need [content].
  Future<String> chat(List<Map<String, String>> messages,
      {int maxTokens = 1024}) async {
    final http = _newHttp();
    try {
      final req = await http.postUrl(Uri.parse('$_base/v1/chat/completions'));
      req.headers
        ..contentType = ContentType.json
        ..set('authorization', 'Bearer ${config.apiKey.trim()}');
      req.write(jsonEncode({
        'model': config.model,
        'messages': messages,
        'temperature': 0,
        'max_tokens': maxTokens,
      }));
      final resp =
          await req.close().timeout(const Duration(seconds: 60));
      final body = jsonDecode(await utf8.decodeStream(resp));
      if (resp.statusCode != 200) {
        final msg = body is Map ? body['error'] ?? body['message'] : body;
        throw LlmException('模型接口 ${resp.statusCode}: $msg');
      }
      final choices = (body as Map)['choices'] as List? ?? const [];
      if (choices.isEmpty) throw LlmException('模型未返回内容');
      final msg = (choices.first as Map)['message'] as Map? ?? const {};
      final content = (msg['content'] as String?) ?? '';
      if (content.trim().isEmpty) {
        throw LlmException('模型返回空内容（推理模型请调大 max_tokens）');
      }
      return content.trim();
    } on TimeoutException {
      throw LlmException('模型接口超时');
    } on SocketException catch (e) {
      throw LlmException('无法连接 ${config.baseUrl}: ${e.message}');
    } finally {
      http.close();
    }
  }

  /// Cheap connectivity probe used by the settings 测试连接 button:
  /// GET /v1/models and report whether the configured model exists.
  Future<String> probe() async {
    final http = _newHttp();
    try {
      final req = await http.getUrl(Uri.parse('$_base/v1/models'));
      req.headers.set('authorization', 'Bearer ${config.apiKey.trim()}');
      final resp =
          await req.close().timeout(const Duration(seconds: 15));
      final body = jsonDecode(await utf8.decodeStream(resp));
      if (resp.statusCode != 200) {
        final msg = body is Map ? body['error'] ?? body['message'] : body;
        return '连接失败 ${resp.statusCode}: $msg';
      }
      final ids = [
        for (final m in (body as Map)['data'] as List? ?? const [])
          (m as Map)['id'],
      ];
      return ids.contains(config.model)
          ? '连接成功 · ${config.model} 在线'
          : '连接成功，但模型列表里没有 ${config.model}（可用：${ids.whereType<String>().take(4).join(', ')}…）';
    } catch (e) {
      return '连接失败: $e';
    } finally {
      http.close();
    }
  }
}
