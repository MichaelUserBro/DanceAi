import 'dart:convert';

import '../ai_provider.dart';
import '../cancel_token.dart';
import '../video_preparer.dart';
import 'http_ai_provider.dart';
import 'http_transport.dart';
import 'provider_common.dart';

/// Загруженный в File API файл: удаляется после анализа в любом исходе.
class _UploadedFile {
  _UploadedFile(this.name, this.uri, this.bytes);
  final String name;
  final String uri;
  final int bytes;
}

/// Файл, загруженный один раз на анализ ([GoogleProvider.prepareShared]):
/// попытка его использует, но не удаляет.
class _SharedFile {
  _SharedFile(this.file);
  final _UploadedFile file;
}

/// Адаптер Google Gemini (`api_type: google`), REST `generateContent`.
///
/// Особенности API (ai.google.dev, ноябрь 2026):
/// - ключ — заголовок `x-goog-api-key`;
/// - весь inline-запрос — до 20 МБ (base64 раздувает на 4/3), больше —
///   File API: загрузка → ожидание ACTIVE → ссылка → DELETE после анализа;
/// - `videoMetadata.fps` — частота, с которой модель смотрит видео (по
///   умолчанию 1, до 24);
/// - ответ — потоком (`streamGenerateContent?alt=sse`): без потока сервер
///   закрывал соединение примерно через 240 с (живая проверка); поток даёт
///   и живой прогресс. Каждая строка `data:` — GenerateContentResponse;
/// - JSON-режим со строгой схемой (`responseJsonSchema` — наша схема без
///   `$schema`/`$id`); не принята (400 про схему) — повтор без неё;
/// - «размышление»: `thinkingConfig.thinkingLevel` (LOW/MEDIUM/HIGH; у
///   gemini-3.8-flash не отключается) входит в `maxOutputTokens`;
///   temperature/topP/topK для Gemini 3.6+ не передаём;
/// - видео загружается в File API один раз на анализ — URI используют все
///   попытки и модели цепочки (один ключ — один проект); загрузка упала, а
///   копия помещается inline, — каждая попытка шлёт видео сама;
/// - предварительная проверка — `countTokens` (квоту генерации не тратит):
///   неверный ключ (400 API_KEY_INVALID), неизвестная модель (404);
/// - 429: вид квоты — `details[QuotaFailure].violations[].quotaId`
///   (`…PerMinute…` / `…PerDay…`), пауза — `details[RetryInfo].retryDelay`.
class GoogleProvider extends HttpAiProvider
    implements AiPrecheck, AiSharedMaterial {
  GoogleProvider({
    required super.model,
    required super.apiKey,
    required super.baseUrl,
    required super.transport,
    super.displayName = 'Google',
    this.inlineVideoMaxBytes = 14 * 1024 * 1024,
    this.pollInterval = const Duration(seconds: 2),
    this.processingTimeout = const Duration(minutes: 5),
  });

  /// Видео больше — через File API.
  final int inlineVideoMaxBytes;
  final Duration pollInterval;
  final Duration processingTimeout;

  static const capabilitiesStatic = AiCapabilities(
    supportsVideo: true,
    // File API принимает файлы до 2 ГБ — облегчённая копия всегда меньше.
    maxVideoBytes: null,
    videoFpsConfigurable: true,
    thinkingConfigurable: true,
    streamsResponse: true,
  );

  @override
  AiCapabilities get capabilities => capabilitiesStatic;

  @override
  bool get usesSchema => true;

  String get _model => model.startsWith('models/') ? model.substring(7) : model;
  Map<String, String> get _auth => {'x-goog-api-key': key};

  @override
  Future<Object?> prepareMedia(AiRequest request,
      void Function(AiProgress) onProgress, CancelToken cancel,
      List<String> notes) async {
    final shared = request.shared;
    if (shared is _UploadedFile) return _SharedFile(shared);
    final video = request.material.video;
    if (request.mode != SubmissionMode.video || video == null) return null;
    if (video.sizeBytes <= inlineVideoMaxBytes) return null;
    final file = await _upload(video.path, video.sizeBytes, onProgress, cancel);
    notes.add('видео загружено через File API (${file.bytes} байт)');
    try {
      await _waitActive(file, onProgress, cancel);
    } catch (_) {
      await _delete(file, notes);
      rethrow;
    }
    return file;
  }

  Future<_UploadedFile> _upload(String path, int size,
      void Function(AiProgress) onProgress, CancelToken cancel) async {
    final start = await transport.send(
      HttpCall.json('POST', Uri.parse('$baseUrl/upload/v1beta/files'), {
        'file': {'display_name': 'danceai'},
      }, headers: {
        ..._auth,
        'x-goog-upload-protocol': 'resumable',
        'x-goog-upload-command': 'start',
        'x-goog-upload-header-content-length': '$size',
        'x-goog-upload-header-content-type': 'video/mp4',
      }),
      cancel: cancel,
    );
    final url = start.headers['x-goog-upload-url'];
    if (!start.ok || url == null) throw classifyError(start);
    final up = await transport.send(
      HttpCall(
        method: 'POST',
        uri: Uri.parse(url),
        headers: {
          ..._auth,
          'x-goog-upload-offset': '0',
          'x-goog-upload-command': 'upload, finalize',
        },
        bodyFile: path,
      ),
      cancel: cancel,
      onUpload: (f) => onProgress(AiProgress(AiPhase.sending, f)),
    );
    if (!up.ok) throw classifyError(up);
    final f = (bodyOf(up)['file'] as Map?) ?? const {};
    final name = f['name'] as String?;
    final uri = f['uri'] as String?;
    if (name == null || uri == null) throw malformed(up);
    return _UploadedFile(name, uri, size);
  }

  Future<void> _waitActive(_UploadedFile file,
      void Function(AiProgress) onProgress, CancelToken cancel) async {
    onProgress(const AiProgress(AiPhase.processing));
    final end = DateTime.now().add(processingTimeout);
    while (true) {
      final r = await transport.send(
        HttpCall(method: 'GET', uri: Uri.parse('$baseUrl/v1beta/${file.name}'),
            headers: _auth),
        cancel: cancel,
      );
      if (!r.ok) throw classifyError(r);
      final state = bodyOf(r)['state'];
      if (state == 'ACTIVE') return;
      if (state == 'FAILED') {
        throw const AiException(
            AiErrorKind.modelUnavailable, 'File API: обработка видео не удалась');
      }
      if (DateTime.now().isAfter(end)) {
        throw const AiException(AiErrorKind.server, 'File API: видео не обработано за 5 мин');
      }
      await cancel.delay(pollInterval);
    }
  }

  Future<void> _delete(_UploadedFile file, List<String> notes) async {
    // Своя отмена: файл удаляется и после отмены анализа пользователем.
    try {
      final r = await transport.send(
        HttpCall(
          method: 'DELETE',
          uri: Uri.parse('$baseUrl/v1beta/${file.name}'),
          headers: _auth,
          responseTimeout: const Duration(seconds: 30),
        ),
        cancel: CancelToken(),
      );
      notes.add(r.ok ? 'файл удалён с сервера' : 'удаление файла: HTTP ${r.status}');
    } catch (e) {
      notes.add('удаление файла не удалось: ${e.runtimeType}');
    }
  }

  @override
  Future<void> cleanup(Object? media, List<String> notes) async {
    if (media is _UploadedFile) await _delete(media, notes);
  }

  @override
  int uploadedBytes(Object? media) => media is _UploadedFile ? media.bytes : 0;

  /// Видео — один раз в File API на весь анализ. Загрузка упала (5xx,
  /// перегрузка, обрыв, таймаут), а копия помещается inline, — откат на
  /// inline в этом анализе; иначе ошибка.
  @override
  Future<SharedMaterial?> prepareShared(AiRequest request,
      {required void Function(AiProgress) onProgress,
      required CancelToken cancel}) async {
    final video = request.material.video;
    if (request.mode != SubmissionMode.video || video == null) return null;
    final sw = Stopwatch()..start();
    _UploadedFile? file;
    try {
      file = await _upload(video.path, video.sizeBytes, onProgress, cancel);
      final uploadTime = sw.elapsed;
      final active = Stopwatch()..start();
      await _waitActive(file, onProgress, cancel);
      return SharedMaterial(
        mode: UploadMode.fileApi,
        handle: file,
        bytes: file.bytes,
        uploadTime: uploadTime,
        activeWait: active.elapsed,
        notes: ['видео загружено через File API один раз на анализ '
            '(${file.bytes} байт)'],
      );
    } on AiException catch (e) {
      final notes = <String>[];
      if (file != null) await _delete(file, notes);
      final transient = const {
        AiErrorKind.overloaded,
        AiErrorKind.server,
        AiErrorKind.network,
        AiErrorKind.noResponse,
      }.contains(e.kind);
      if (!transient || video.sizeBytes > inlineVideoMaxBytes) {
        throw e.withInfo(
            notes: [...notes, for (final n in e.notes) redact(n, key)]);
      }
      return SharedMaterial(
        mode: UploadMode.inlineFallback,
        bytes: video.sizeBytes,
        uploadTime: sw.elapsed,
        notes: [
          redact('загрузка в File API не удалась (${e.kind.name}'
              '${e.detail == null ? '' : ': ${e.detail}'}) — видео inline в '
              'каждой попытке', key),
          ...notes,
        ],
      );
    }
  }

  @override
  Future<void> releaseShared(SharedMaterial material, List<String> notes) async {
    final file = material.handle;
    if (file is _UploadedFile) await _delete(file, notes);
  }

  /// `countTokens` с коротким текстом: ключ, модель, страна — без расхода
  /// квоты генерации.
  @override
  Future<PrecheckResult> precheck(CancelToken cancel) async {
    final request = 'POST models/$_model:countTokens';
    final sw = Stopwatch()..start();
    try {
      final r = await transport.send(
        HttpCall.json(
          'POST',
          Uri.parse('$baseUrl/v1beta/models/${Uri.encodeComponent(_model)}'
              ':countTokens'),
          {
            'contents': [
              {
                'parts': [
                  {'text': 'ping'}
                ]
              }
            ]
          },
          headers: _auth,
          responseTimeout: const Duration(seconds: 20),
        ),
        cancel: cancel,
      );
      return PrecheckResult(
        request: request,
        status: r.status,
        time: sw.elapsed,
        error: r.ok ? null : classifyError(r),
      );
    } on AiException catch (e) {
      return PrecheckResult(
          request: request,
          time: sw.elapsed,
          error: e.withInfo(
              detail: e.detail == null ? null : redact(e.detail!, key)));
    }
  }

  /// 429 Google: вид квоты и пауза из `details` (google.rpc.QuotaFailure,
  /// google.rpc.RetryInfo).
  @override
  AiException classifyError(HttpResult r) {
    final e = super.classifyError(r);
    if (e.kind != AiErrorKind.rateLimit) return e;
    final q = googleQuota(r.json);
    return e.withQuota(q.scope, quotaId: q.quotaId, retryAfter: q.retryDelay);
  }

  /// Разбор `error.details` ответа Google (для 429).
  static ({QuotaScope? scope, String? quotaId, Duration? retryDelay})
      googleQuota(Object? json) {
    final err = json is Map ? json['error'] : null;
    final details = err is Map ? err['details'] : null;
    String? quotaId;
    QuotaScope? scope;
    Duration? delay;
    if (details is List) {
      for (final d in details.whereType<Map>()) {
        final type = '${d['@type'] ?? ''}';
        if (type.endsWith('QuotaFailure') && d['violations'] is List) {
          for (final v in (d['violations'] as List).whereType<Map>()) {
            final id = v['quotaId'];
            if (id is! String) continue;
            final s = id.contains('PerDay')
                ? QuotaScope.day
                : id.contains('PerMinute')
                    ? QuotaScope.minute
                    : null;
            // Дневная важнее: при ней ждать бессмысленно.
            if (scope != QuotaScope.day) {
              scope = s ?? scope;
              quotaId = id;
            }
          }
        } else if (type.endsWith('RetryInfo')) {
          final m = RegExp(r'^(\d+(?:\.\d+)?)s$')
              .firstMatch('${d['retryDelay'] ?? ''}'.trim());
          if (m != null) {
            delay = Duration(
                milliseconds: (double.parse(m.group(1)!) * 1000).round());
          }
        }
      }
    }
    return (scope: scope, quotaId: quotaId, retryDelay: delay);
  }

  @override
  Future<HttpCall> buildCall(AiRequest request, Object? media, CallOptions o) async {
    final parts = <Map<String, dynamic>>[];
    final m = request.material;
    if (request.mode == SubmissionMode.video) {
      final meta = {'fps': request.videoFps};
      final file = media is _SharedFile
          ? media.file
          : media is _UploadedFile
              ? media
              : null;
      if (file != null) {
        parts.add({
          'fileData': {'mimeType': 'video/mp4', 'fileUri': file.uri},
          'videoMetadata': meta,
        });
      } else {
        parts.add({
          'inlineData': {'mimeType': 'video/mp4', 'data': await videoBase64(m)},
          'videoMetadata': meta,
        });
      }
    } else {
      for (final (label, b64, mime) in await loadFrames(m)) {
        parts
          ..add({'text': label})
          ..add({'inlineData': {'mimeType': mime, 'data': b64}});
      }
    }
    parts.add({'text': request.userPrompt});

    return HttpCall.json(
      'POST',
      Uri.parse('$baseUrl/v1beta/models/$_model:streamGenerateContent?alt=sse'),
      {
        'systemInstruction': {
          'parts': [
            {'text': request.systemPrompt}
          ]
        },
        'contents': [
          {'role': 'user', 'parts': parts},
          if (request.isRetry) ...[
            {
              'role': 'model',
              'parts': [
                {'text': request.previousResponse ?? ''}
              ]
            },
            {
              'role': 'user',
              'parts': [
                {'text': request.retryNote}
              ]
            },
          ],
        ],
        'generationConfig': {
          if (o.limitTokens) 'maxOutputTokens': maxOutputTokens,
          if (o.jsonMode) 'responseMimeType': 'application/json',
          if (o.jsonMode && o.useSchema)
            'responseJsonSchema': providerSchema(request.reportSchema),
          if (o.useThinking && request.thinkingLevel != null)
            'thinkingConfig': {
              'thinkingLevel': request.thinkingLevel!.toUpperCase(),
            },
        },
      },
      headers: _auth,
      stopOnSseError: true,
    );
  }

  static const _blockedReasons = {
    'SAFETY', 'PROHIBITED_CONTENT', 'BLOCKLIST', 'SPII', 'RECITATION',
    'IMAGE_SAFETY', 'IMAGE_PROHIBITED_CONTENT',
  };

  /// Ответ потока: строки `data: {GenerateContentResponse}`. Текст —
  /// склейка частей (без «мыслей»), причина завершения и токены — из
  /// последних фрагментов. Обычный JSON (не поток) тоже понимаем.
  @override
  AiResponse parse(HttpResult r,
      {required int sentBytes, required List<String> notes}) {
    final chunks = <Map>[];
    final raw = r.text.trimLeft();
    if (raw.startsWith('data:') || raw.contains('\ndata:')) {
      for (final line in const LineSplitter().convert(raw)) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') continue;
        try {
          final j = jsonDecode(payload);
          if (j is Map) chunks.add(j);
        } on FormatException {
          // Битый фрагмент потока — пропускаем; итог проверит валидатор.
        }
      }
    } else {
      final j = r.json;
      if (j is Map) chunks.add(j);
      if (j is List) chunks.addAll(j.whereType<Map>());
    }
    if (chunks.isEmpty) throw malformed(r);

    final text = StringBuffer();
    String? finish;
    Object? block;
    Map? usage;
    for (final c in chunks) {
      final err = c['error'];
      if (err is Map) {
        throw classifyError(HttpResult(
            asInt(err['code']) ?? 500, const {}, utf8.encode(jsonEncode(c))));
      }
      final feedback = c['promptFeedback'];
      if (feedback is Map && feedback['blockReason'] != null) {
        block = feedback['blockReason'];
      }
      if (c['usageMetadata'] is Map) usage = c['usageMetadata'] as Map;
      final candidates = c['candidates'];
      if (candidates is! List || candidates.isEmpty) continue;
      final cand = candidates.first as Map;
      finish = (cand['finishReason'] as String?) ?? finish;
      final content = cand['content'];
      if (content is Map && content['parts'] is List) {
        for (final p in content['parts'] as List) {
          if (p is Map && p['thought'] != true && p['text'] is String) {
            text.write(p['text']);
          }
        }
      }
    }
    if (text.isEmpty && block != null) {
      throw AiException(AiErrorKind.blocked, 'promptFeedback.blockReason: $block');
    }
    if (text.isEmpty && _blockedReasons.contains(finish)) {
      throw AiException(AiErrorKind.blocked, 'finishReason: $finish');
    }
    if (text.isEmpty && finish == null) throw malformed(r);
    final u = usage;
    return AiResponse(
      text: extractJson(text.toString()),
      finishReason: finish,
      sentBytes: sentBytes,
      notes: notes,
      usage: u == null
          ? null
          : AiUsage(
              inputTokens: asInt(u['promptTokenCount']),
              outputTokens: asInt(u['candidatesTokenCount']),
              thinkingTokens: asInt(u['thoughtsTokenCount']),
            ),
    );
  }

  /// Модель найдена или нет. Что модель принимает, API не сообщает.
  @override
  Future<ModelLookup?> lookupModel(CancelToken cancel) async {
    if (_model.trim().isEmpty) return null;
    try {
      final r = await transport.send(
        HttpCall(
          method: 'GET',
          uri: Uri.parse('$baseUrl/v1beta/models/${Uri.encodeComponent(_model)}'),
          headers: _auth,
          responseTimeout: const Duration(seconds: 20),
        ),
        cancel: cancel,
      );
      if (r.ok) return const ModelLookup(found: true);
      if (r.status == 404) return const ModelLookup(found: false);
      return null;
    } on AiException {
      return null;
    }
  }
}
