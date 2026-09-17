# Era Flutter SDK development

This directory contains the source for the `era_flutter` package. The package
README is published to pub.dev, so it intentionally contains integration
guidance only. Keep contributor, build, and release documentation here.

## Local development

The package lives in `era_flutter/`.

```sh
cd intent-scoring/sdk/flutter/era_flutter
flutter pub get
flutter test
flutter analyze
```

Run these checks before opening a release change. The package's tests cover the
HTTP contract, visitor-ID persistence, concurrent initialization, resets, and
error handling.

## Versioning

Update `era_flutter/pubspec.yaml` for every published release. Follow semantic
versioning:

- Patch releases fix backward-compatible bugs.
- Minor releases add backward-compatible API.
- Major releases make breaking API changes.

Update the package changelog in the same change, then tag the repository
release using the version that was published.

## Publishing

From the package directory, authenticate with the Dart publisher account and
inspect the archive before publishing:

```sh
cd intent-scoring/sdk/flutter/era_flutter
dart pub publish --dry-run
dart pub publish
```

Publishing is a manual, production operation. Confirm the package name,
version, README, changelog, and files included by the dry run before the final
publish command.

## Deployment and consumption

The Flutter SDK is a client package; it has no server deployment step. Publish
the version to pub.dev, create the matching repository tag/release, then have
integrators depend on that version:

```yaml
dependencies:
  era_flutter: ^<published-version>
```

For local application development before publishing, use a path dependency:

```yaml
dependencies:
  era_flutter:
    path: ../intent-scoring/sdk/flutter/era_flutter
```

Do not publish secret API keys or test credentials. The package accepts only a
publishable key; integrations must never call Era's `/v1/era/turn` endpoint
with a secret key from a mobile app.
