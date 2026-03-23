import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;

typedef AuthTokenProvider = Future<String?> Function();

class NepaliTtsFallbackService {
  NepaliTtsFallbackService({
    this.endpoint,
    this.authTokenProvider,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri? endpoint;
  final AuthTokenProvider? authTokenProvider;
  final http.Client _client;
  final AudioPlayer _player = AudioPlayer();

  final Map<String, Uint8List> _audioCache = <String, Uint8List>{};

  static const String defaultNepaliLocale = 'ne-NP';

  bool _isNepaliLocale(String locale) {
    return locale.toLowerCase().startsWith('ne');
  }

  Future<bool> isNepaliAvailableNatively(FlutterTts tts) async {
    final dynamic langs = await tts.getLanguages;
    if (langs is! List<dynamic>) {
      return false;
    }
    return langs
        .whereType<Object>()
        .map((Object language) => language.toString())
        .any(_isNepaliLocale);
  }

  Future<bool> shouldUseFallback({
    required FlutterTts tts,
    required bool isIOS,
    required String selectedLanguage,
  }) async {
    if (!isIOS || !_isNepaliLocale(selectedLanguage)) {
      return false;
    }
    final bool nativeNepaliAvailable = await isNepaliAvailableNatively(tts);
    return !nativeNepaliAvailable;
  }

  Future<void> speakViaFallback({
    required String text,
    required String locale,
  }) async {
    if (endpoint == null) {
      throw StateError(
        'Nepali fallback is not configured. Set a backend endpoint first.',
      );
    }

    final String cacheKey = '$locale|$text';
    Uint8List? audioBytes = _audioCache[cacheKey];

    if (audioBytes == null) {
      final Map<String, String> headers = <String, String>{
        'Content-Type': 'application/json',
      };

      if (authTokenProvider != null) {
        final String? token = await authTokenProvider!.call();
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
        }
      }

      final http.Response response = await _client
          .post(
            endpoint!,
            headers: headers,
            body: jsonEncode(<String, String>{
              'text': text,
              'locale': locale,
              'format': 'mp3',
            }),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Fallback TTS request failed with status ${response.statusCode}.',
        );
      }

      final String contentType = response.headers['content-type'] ?? '';
      if (contentType.contains('application/json')) {
        final dynamic decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final String? b64 = decoded is Map<String, dynamic>
            ? decoded['audioBase64'] as String?
            : null;
        if (b64 == null || b64.isEmpty) {
          throw StateError(
              'Fallback TTS JSON response is missing audioBase64.');
        }
        audioBytes = base64Decode(b64);
      } else {
        audioBytes = response.bodyBytes;
      }

      if (audioBytes.isEmpty) {
        throw StateError('Fallback TTS returned an empty audio payload.');
      }
      _audioCache[cacheKey] = audioBytes;
    }

    await _player.stop();
    await _player.play(BytesSource(audioBytes), mode: PlayerMode.mediaPlayer);
    await _player.onPlayerComplete.first.timeout(const Duration(minutes: 2));
  }

  Future<void> dispose() async {
    await _player.dispose();
    _client.close();
  }
}
