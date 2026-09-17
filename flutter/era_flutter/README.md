# Era Flutter

`era_flutter` is the Flutter SDK for Era identity verification.

## Install

```yaml
dependencies:
  era_flutter: ^<version>
```

## Usage

Initialize one SDK instance with your Era publishable key, then request a
visitor ID or run the verification flow.

```dart
final era = EraFlutter(
  baseUrl: 'https://api.era.example',
  publishableKey: 'pk_era.<raw-lowercase-partner-uuid>.<raw-lowercase-key-uuid>.<43-character-url-safe-secret>',
);

final visitorId = await era.init();
final challenge = await era.startVerification(
  VerificationType.email,
  'person@example.com',
);

// Collect any challenge input in your app's UI, then submit it.
final confirmed = await era.confirmVerification(
  challenge.challengeId,
  userEnteredCode,
);

era.close();
```

The SDK exposes `init`, `getVisitorId`, `getVerification`,
`startVerification`, `confirmVerification`, `resendVerification`,
`resetVisitor`, and `close`. Verification operations return typed verification
models. Failures are reported as `EraFlutterException`, which includes a
machine-readable `code`, message, retryability, and HTTP status code when one
is available.

## Verification UI and data

Your app owns temporary verification UI state, including challenge IDs, OTPs,
and user-entered values. Do not rely on the SDK to retain them between screens
or app sessions.

The SDK persists only its visitor ID, using the key
`era:visitor_id:<partnerId>` in shared preferences. It does not persist
challenge IDs, one-time codes, Era end-user IDs, or verification details.
In-memory state is shared within the same isolate and resets prevent stale
requests from restoring a visitor ID after `resetVisitor`.

## Security

Use a publishable key in this canonical format:

```
pk_era.<raw-lowercase-partner-uuid>.<raw-lowercase-key-uuid>.<43-character-url-safe-secret>
```

Never embed an Era secret API key in a mobile app and do not call
`/v1/era/turn` from the app. The SDK uses the publishable-key API contract and
does not retry failed HTTP requests automatically.
