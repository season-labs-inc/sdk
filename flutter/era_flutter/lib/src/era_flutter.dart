import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _visitorIdPattern =
    r'^era_vid_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
const _publishableKeyPattern =
    r'^pk_era\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.([A-Za-z0-9_-]{43})$';

final _visitorIdExpression = RegExp(_visitorIdPattern);
final _publishableKeyExpression = RegExp(_publishableKeyPattern);

/// A testable storage boundary. By default, [EraFlutter] uses
/// [SharedPreferencesAsync] through this interface.
abstract interface class EraFlutterStorage {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

class _SharedPreferencesStorage implements EraFlutterStorage {
  _SharedPreferencesStorage() : _preferences = SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) => _preferences.setString(key, value);

  @override
  Future<void> remove(String key) => _preferences.remove(key);
}

enum VerificationType {
  email,
  phone;

  String get wireValue => name;
}

class VerificationChallenge {
  const VerificationChallenge({
    required this.challengeId,
    required this.maskedIdentifier,
    required this.expiresAt,
  });

  final String challengeId;
  final String maskedIdentifier;
  final String expiresAt;
}

class VerificationStatus {
  const VerificationStatus({required this.eraEndUserId});

  final String? eraEndUserId;
}

class VerificationConfirmation {
  const VerificationConfirmation({required this.eraEndUserId});

  final bool verified = true;
  final String eraEndUserId;
}

class EraFlutterException implements Exception {
  const EraFlutterException(
    this.code,
    this.message,
    this.retryable,
    this.statusCode,
  );

  final String code;
  final String message;
  final bool retryable;
  final int? statusCode;

  @override
  String toString() => 'EraFlutterException($code): $message';
}

class _ActiveRequest {
  _ActiveRequest(this.generation, this.owner);

  final int generation;
  final EraFlutter owner;
  final Completer<void> abortTrigger = Completer<void>();
}

class _PartnerState {
  _PartnerState(this.storageKey, this.storage);

  final String storageKey;
  final EraFlutterStorage storage;
  String? visitorId;
  Future<String>? initialization;
  int generation = 0;
  bool memoryOnly = false;
  final Set<_ActiveRequest> activeRequests = {};
}

final _partnerStates = <String, _PartnerState>{};

/// Flutter client for Era's public visitor and verification API.
class EraFlutter {
  EraFlutter({
    required String baseUrl,
    required String publishableKey,
    http.Client? httpClient,
    bool ownsHttpClient = false,
    EraFlutterStorage? storage,
  })  : _baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
        _publishableKey = publishableKey,
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null || ownsHttpClient,
        _state = _stateForPublishableKey(publishableKey, storage);

  final String _baseUrl;
  final String _publishableKey;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final _PartnerState _state;
  bool _closed = false;

  /// Initializes the partner-scoped visitor, optionally with an application ID.
  Future<String> init([String? visitorId]) {
    _assertOpen();
    final requestedVisitorId = visitorId == null ? null : _normalizeVisitorId(visitorId);
    if (requestedVisitorId != null) {
      _state.generation += 1;
      _abortOlderRequests(_state);
      _state.visitorId = null;
      _state.initialization = null;
      _state.memoryOnly = false;
      return _startInitialization(_state.generation, false, requestedVisitorId);
    }
    return _state.initialization ?? _startInitialization(_state.generation, false, null);
  }

  /// Returns the persisted or same-isolate visitor ID without creating one.
  Future<String?> getVisitorId() async {
    _assertOpen();
    return _readStoredVisitor();
  }

  Future<VerificationStatus> getVerification() {
    return _verificationOperation((generation) async {
      final visitorId = await init();
      _assertGeneration(generation);
      final response = await _get(
        '/v1/era/visitors/${Uri.encodeComponent(visitorId)}',
        generation,
      );
      if (!response.containsKey('era_end_user_id')) {
        throw const EraFlutterException(
          'invalid_response',
          'Era returned an invalid response.',
          false,
          null,
        );
      }
      final eraEndUserId = response['era_end_user_id'];
      if (eraEndUserId != null && (eraEndUserId is! String || eraEndUserId.isEmpty)) {
        throw const EraFlutterException(
          'invalid_response',
          'Era returned an invalid response.',
          false,
          null,
        );
      }
      return VerificationStatus(eraEndUserId: eraEndUserId as String?);
    });
  }

  Future<VerificationChallenge> startVerification(
    VerificationType type,
    String identifier,
  ) {
    return _verificationOperation((generation) async {
      final visitorId = await init();
      _assertGeneration(generation);
      final response = await _post('/v1/era/verifications/start', {
        'visitor_id': visitorId,
        'type': type.wireValue,
        'identifier': identifier,
      }, generation);
      return _verificationChallenge(response);
    });
  }

  Future<VerificationConfirmation> confirmVerification(
    String challengeId,
    String code,
  ) {
    return _verificationOperation((generation) async {
      final response = await _post('/v1/era/verifications/confirm', {
        'challenge_id': challengeId,
        'code': code,
      }, generation);
      if (response['verified'] != true) {
        throw const EraFlutterException(
          'invalid_response',
          'Era returned an invalid response.',
          false,
          null,
        );
      }
      final eraEndUserId = response['era_end_user_id'];
      if (eraEndUserId is! String || eraEndUserId.isEmpty) {
        throw const EraFlutterException(
          'invalid_response',
          'Era returned an invalid response.',
          false,
          null,
        );
      }
      return VerificationConfirmation(eraEndUserId: eraEndUserId);
    });
  }

  Future<VerificationChallenge> resendVerification(String challengeId) {
    return _verificationOperation((generation) async {
      final response = await _post('/v1/era/verifications/resend', {
        'challenge_id': challengeId,
      }, generation);
      return _verificationChallenge(response);
    });
  }

  /// Removes this partner's visitor association and creates a replacement.
  Future<String> resetVisitor() async {
    _assertOpen();
    _state.generation += 1;
    _abortOlderRequests(_state);
    _state.visitorId = null;
    _state.initialization = null;
    _state.memoryOnly = false;
    try {
      await _state.storage.remove(_state.storageKey);
    } catch (_) {
      // A replacement remains available in memory if preferences are unavailable.
    }
    return _startInitialization(_state.generation, true, null);
  }

  /// Aborts this client's in-flight requests and closes an owned HTTP client.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _state.activeRequests.where((request) => request.owner == this)) {
      if (!request.abortTrigger.isCompleted) request.abortTrigger.complete();
    }
    if (_ownsHttpClient) _httpClient.close();
  }

  Future<String> _startInitialization(
    int generation,
    bool forceFresh,
    String? requestedVisitorId,
  ) {
    late final Future<String> initialization;
    initialization = _initialize(generation, forceFresh, requestedVisitorId).catchError((Object error) {
      if (identical(_state.initialization, initialization)) _state.initialization = null;
      throw error;
    });
    _state.initialization = initialization;
    return initialization;
  }

  Future<String> _initialize(
    int generation,
    bool forceFresh,
    String? requestedVisitorId,
  ) async {
    final storedVisitorId = forceFresh || requestedVisitorId != null
        ? null
        : await _readStoredVisitor();
    _assertGeneration(generation);
    if (storedVisitorId != null) return storedVisitorId;

    final response = await _post(
      '/v1/era/visitors/init',
      requestedVisitorId == null ? {} : {'visitor_id': requestedVisitorId},
      generation,
    );
    _assertGeneration(generation);
    final returnedVisitorId = response['visitor_id'];
    if (returnedVisitorId is! String || !_visitorIdExpression.hasMatch(returnedVisitorId)) {
      throw const EraFlutterException(
        'invalid_response',
        'Era returned an invalid response.',
        false,
        null,
      );
    }

    final concurrentVisitorId = forceFresh || requestedVisitorId != null
        ? null
        : await _readStoredVisitor();
    _assertGeneration(generation);
    final chosenVisitorId = concurrentVisitorId ?? returnedVisitorId;
    _state.visitorId = chosenVisitorId;
    if (concurrentVisitorId == null) {
      try {
        await _state.storage.setString(_state.storageKey, chosenVisitorId);
        _state.memoryOnly = false;
      } catch (_) {
        _state.memoryOnly = true;
      }
    }
    return chosenVisitorId;
  }

  Future<String?> _readStoredVisitor() async {
    try {
      final value = await _state.storage.getString(_state.storageKey);
      final visitorId = value != null && _visitorIdExpression.hasMatch(value) ? value : null;
      if (visitorId != null) {
        if (visitorId != _state.visitorId) _replaceSharedVisitor(_state, visitorId);
        return visitorId;
      }
      if (!_state.memoryOnly && _state.visitorId != null) {
        _replaceSharedVisitor(_state, null);
      }
      return _state.visitorId;
    } catch (_) {
      return _state.visitorId;
    }
  }

  Future<T> _verificationOperation<T>(Future<T> Function(int generation) operation) async {
    _assertOpen();
    await _readStoredVisitor();
    final generation = _state.generation;
    try {
      final result = await operation(generation);
      _assertGeneration(generation);
      return result;
    } catch (_) {
      _assertGeneration(generation);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
    int generation,
  ) {
    return _request(path, generation, method: 'POST', body: body);
  }

  Future<Map<String, dynamic>> _get(String path, int generation) {
    return _request(path, generation, method: 'GET');
  }

  Future<Map<String, dynamic>> _request(
    String path,
    int generation, {
    required String method,
    Map<String, dynamic>? body,
  }) async {
    _assertOpen();
    final activeRequest = _ActiveRequest(generation, this);
    _state.activeRequests.add(activeRequest);
    try {
      final request = http.AbortableRequest(
        method,
        Uri.parse('$_baseUrl$path'),
        abortTrigger: activeRequest.abortTrigger.future,
      );
      request.headers['X-Era-Publishable-Key'] = _publishableKey;
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }

      http.Response response;
      try {
        response = await http.Response.fromStream(await _httpClient.send(request));
      } on http.RequestAbortedException {
        _assertGeneration(generation);
        throw const EraFlutterException('network_error', 'Era is unavailable.', true, null);
      } catch (_) {
        _assertGeneration(generation);
        throw const EraFlutterException('network_error', 'Era is unavailable.', true, null);
      }

      dynamic payload;
      try {
        payload = jsonDecode(response.body);
      } catch (_) {
        payload = null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = payload is Map<String, dynamic> ? payload['error'] : null;
        final code = error is Map<String, dynamic> && error['code'] is String
            ? error['code'] as String
            : 'request_failed';
        final message = error is Map<String, dynamic> && error['message'] is String
            ? error['message'] as String
            : 'The Era request failed.';
        final retryable = error is Map<String, dynamic> && error['retryable'] is bool
            ? error['retryable'] as bool
            : response.statusCode >= 500;
        throw EraFlutterException(code, message, retryable, response.statusCode);
      }
      if (payload is! Map<String, dynamic>) {
        throw const EraFlutterException(
          'invalid_response',
          'Era returned an invalid response.',
          false,
          null,
        );
      }
      return payload;
    } finally {
      _state.activeRequests.remove(activeRequest);
    }
  }

  VerificationChallenge _verificationChallenge(Map<String, dynamic> response) {
    final challengeId = response['challenge_id'];
    final maskedIdentifier = response['masked_identifier'];
    final expiresAt = response['expires_at'];
    if (challengeId is! String || maskedIdentifier is! String || expiresAt is! String) {
      throw const EraFlutterException(
        'invalid_response',
        'Era returned an invalid response.',
        false,
        null,
      );
    }
    return VerificationChallenge(
      challengeId: challengeId,
      maskedIdentifier: maskedIdentifier,
      expiresAt: expiresAt,
    );
  }

  void _assertOpen() {
    if (_closed) {
      throw const EraFlutterException('client_closed', 'This Era client is closed.', false, null);
    }
  }

  void _assertGeneration(int generation) {
    if (generation != _state.generation) {
      throw const EraFlutterException(
        'visitor_reset',
        'The visitor was reset while the operation was in progress.',
        false,
        null,
      );
    }
  }
}

_PartnerState _stateForPublishableKey(
  String publishableKey,
  EraFlutterStorage? storage,
) {
  final match = _publishableKeyExpression.firstMatch(publishableKey);
  if (match == null) {
    throw ArgumentError.value(publishableKey, 'publishableKey', 'Invalid Era publishable key format.');
  }
  final partnerId = match.group(1)!;
  return _partnerStates.putIfAbsent(
    partnerId,
    () => _PartnerState('era:visitor_id:$partnerId', storage ?? _SharedPreferencesStorage()),
  );
}

String _normalizeVisitorId(String visitorId) {
  final normalized = visitorId.startsWith('era_vid_') ? visitorId : 'era_vid_$visitorId';
  if (!_visitorIdExpression.hasMatch(normalized)) {
    throw ArgumentError.value(
      visitorId,
      'visitorId',
      'Invalid visitor ID. Expected a UUIDv4 with or without the era_vid_ prefix.',
    );
  }
  return normalized;
}

void _abortOlderRequests(_PartnerState state) {
  for (final request in state.activeRequests) {
    if (request.generation < state.generation && !request.abortTrigger.isCompleted) {
      request.abortTrigger.complete();
    }
  }
}

void _replaceSharedVisitor(_PartnerState state, String? visitorId) {
  if (state.visitorId != null && state.visitorId != visitorId) {
    state.generation += 1;
    _abortOlderRequests(state);
  }
  state.visitorId = visitorId;
  state.initialization = visitorId == null ? null : Future.value(visitorId);
  state.memoryOnly = false;
}
