import 'dart:convert';

import 'package:era_flutter/era_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const visitorId = 'era_vid_11111111-1111-4111-8111-111111111111';

class MemoryStorage implements EraFlutterStorage {
  final values = <String, String>{};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> remove(String key) async => values.remove(key);

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

class RecordingClient extends http.BaseClient {
  RecordingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;
  final requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() => closed = true;
}

http.StreamedResponse jsonResponse(int statusCode, Object body) {
  return http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(body))),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  test('rejects encoded or noncanonical partner IDs before any request', () {
    expect(
      () => EraFlutter(
        baseUrl: 'https://era.test',
        publishableKey: 'pk_era.cGFydG5lcl8xMjM.primary.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      ),
      throwsArgumentError,
    );
  });

  test('uses snake_case JSON and maps verification models', () async {
    const partnerId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const publishableKey =
        'pk_era.$partnerId.bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final storage = MemoryStorage();
    storage.values['era:visitor_id:$partnerId'] = visitorId;
    final client = RecordingClient((request) async {
      expect(request.url.path, '/v1/era/verifications/start');
      expect(request.headers['X-Era-Publishable-Key'], publishableKey);
      expect(request, isA<http.AbortableRequest>());
      expect(jsonDecode((request as http.Request).body), {
        'visitor_id': visitorId,
        'type': 'email',
        'identifier': 'person@example.com',
      });
      return jsonResponse(200, {
        'challenge_id': 'opaque-challenge',
        'masked_identifier': 'p***@example.com',
        'expires_at': '2026-07-23T12:00:00Z',
      });
    });
    final era = EraFlutter(
      baseUrl: 'https://era.test',
      publishableKey: publishableKey,
      httpClient: client,
      storage: storage,
    );

    final challenge = await era.startVerification(
      VerificationType.email,
      'person@example.com',
    );

    expect(challenge.challengeId, 'opaque-challenge');
    expect(challenge.maskedIdentifier, 'p***@example.com');
    expect(storage.values.values.join(), isNot(contains('opaque-challenge')));
  });

  test('shares the same-isolate visitor and resets it for the partner', () async {
    const partnerId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    const publishableKey =
        'pk_era.$partnerId.dddddddd-dddd-4ddd-8ddd-dddddddddddd.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final storage = MemoryStorage();
    var calls = 0;
    final client = RecordingClient((request) async {
      calls += 1;
      return jsonResponse(200, {
        'visitor_id': calls == 1
            ? visitorId
            : 'era_vid_22222222-2222-4222-8222-222222222222',
      });
    });
    final first = EraFlutter(
      baseUrl: 'https://era.test',
      publishableKey: publishableKey,
      httpClient: client,
      storage: storage,
    );
    final second = EraFlutter(
      baseUrl: 'https://era.test',
      publishableKey: publishableKey,
      httpClient: client,
      storage: storage,
    );

    expect(await first.init(), visitorId);
    expect(await second.getVisitorId(), visitorId);
    expect(await second.resetVisitor(), 'era_vid_22222222-2222-4222-8222-222222222222');
    expect(await first.getVisitorId(), 'era_vid_22222222-2222-4222-8222-222222222222');
  });

  test('maps structured API errors without retrying', () async {
    const partnerId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    const publishableKey =
        'pk_era.$partnerId.ffffffff-ffff-4fff-8fff-ffffffffffff.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final storage = MemoryStorage();
    storage.values['era:visitor_id:$partnerId'] = visitorId;
    final client = RecordingClient((request) async {
      return jsonResponse(429, {
        'error': {
          'code': 'rate_limited',
          'message': 'Try again later.',
          'retryable': true,
        },
      });
    });
    final era = EraFlutter(
      baseUrl: 'https://era.test',
      publishableKey: publishableKey,
      httpClient: client,
      storage: storage,
    );

    await expectLater(
      era.getVerification(),
      throwsA(isA<EraFlutterException>()
          .having((error) => error.code, 'code', 'rate_limited')
          .having((error) => error.statusCode, 'statusCode', 429)
          .having((error) => error.retryable, 'retryable', true)),
    );
    expect(client.requests, hasLength(1));
  });

  test('close keeps caller-owned clients open', () {
    const partnerId = '99999999-9999-4999-8999-999999999999';
    const publishableKey =
        'pk_era.$partnerId.88888888-8888-4888-8888-888888888888.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final client = RecordingClient((request) async => jsonResponse(200, {}));
    final era = EraFlutter(
      baseUrl: 'https://era.test',
      publishableKey: publishableKey,
      httpClient: client,
      storage: MemoryStorage(),
    );

    era.close();

    expect(client.closed, isFalse);
  });
}
