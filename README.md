# App Store release notes

Publish Google Play–format release notes to the **What's New** field of an existing iOS version in App Store Connect. Runs in any CI system that supports Linux containers, or locally with Ruby. No Fastlane, Node, Expo, Xcode, or macOS required.

Dry run is the default. `--apply` writes changes. The tool updates only existing version localizations, skips identical text, and never creates versions/localizations, uploads builds, submits reviews, or releases an app.

## Inputs

| Environment variable | Required | Meaning |
| --- | --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | Yes | Team API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Yes | Team API key issuer ID |
| `APP_STORE_CONNECT_KEY_FILE` | Yes | Path inside the container to the `.p8` private key |
| `APP_BUNDLE_ID` | Yes | App bundle ID, e.g. `com.aplicart.tipkick` |
| `APP_VERSION` | Yes | Exact marketing version, e.g. `1.2.3`, not the build number |
| `RELEASE_NOTES_FILE` | Yes* | UTF-8 notes file path inside the container |

*Or pass `--notes FILE`. `--validate` needs only the notes file and optional locale map; it performs no network calls and requires no credentials. Authentication supports team API keys; individual keys are not supported. Use a key with permission to update app metadata, such as App Manager.

Provide secrets at runtime. Never commit private keys or add them to image layers. The image runs as UID/GID `65532`; mounted files must be readable by that user. A GitLab file variable containing the key should be protected and available only to the intended release jobs.

## Notes format

Locale tags can be on their own lines or inline, so notes pasted into a single-line CI input are accepted. Blank lines between blocks and surrounding Markdown code fences (` ```text ` or ` ``` `) are accepted. Line breaks within notes are preserved when supplied; line breaks removed by a browser cannot be reconstructed. Text is preserved except for leading/trailing whitespace; XML escaping is unnecessary (`&` stays `&`). UTF-8 BOM and CRLF files are accepted.

```text
<en-US>
Bug fixes and performance improvements.
</en-US>
<it-IT>
Correzioni di bug e miglioramenti delle prestazioni.
</it-IT>
```

The parser rejects empty notes, duplicate locales, nested/mismatched tags, unknown locale codes, and text longer than 4,000 characters. All input is parsed and mapped before authentication or writes.

## Local use

Ruby 3.4 is used in the image. The application uses only standard-library dependencies.

```sh
ruby bin/appstore-release-notes --validate --notes examples/release-notes.txt
ruby -Itest test/release_notes_test.rb
docker build -t appstore-release-notes:local .
```

Set the ID, issuer, bundle ID, and version in your shell, then run:

```sh
docker run --rm \
  -e APP_STORE_CONNECT_KEY_ID \
  -e APP_STORE_CONNECT_ISSUER_ID \
  -e APP_BUNDLE_ID \
  -e APP_VERSION \
  -e APP_STORE_CONNECT_KEY_FILE=/run/secrets/auth.p8 \
  -e RELEASE_NOTES_FILE=/data/release-notes.txt \
  -v "$PWD/release-notes.txt:/data/release-notes.txt:ro" \
  -v "$PWD/AuthKey.p8:/run/secrets/auth.p8:ro" \
  appstore-release-notes:local appstore-release-notes
```

Append `--apply` to write. The image deliberately has no custom entrypoint, so CI runners can execute their normal shell scripts.

## GitLab CI

After publishing the image, create these GitLab CI/CD variables:

- `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_ISSUER_ID`.
- `APP_STORE_CONNECT_KEY_FILE`: **File** variable containing the entire `.p8` private key.
- `APP_BUNDLE_ID` and `APP_VERSION` (or provide them in the job).

Keep `release-notes.txt` in your project or produce it as an earlier job artifact.

```yaml
appstore-release-notes:
  image: ghcr.io/aplicart-ad/appstore-release-notes:1.0.0
  stage: deploy
  variables:
    RELEASE_NOTES_FILE: "$CI_PROJECT_DIR/release-notes.txt"
    APP_BUNDLE_ID: "com.aplicart.tipkick"
    APP_VERSION: "1.2.3"
  script:
    - appstore-release-notes --apply
  when: manual
```

Remove `--apply` for an authenticated dry run. Pipeline credentials need no access to this source repository once the public image is available.

## Version and failure behavior

The exact iOS version must already exist and be editable in App Store Connect. Automatic version selection is intentionally excluded. Apple's first app version has no What's New field. See [Apple's version fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) and [editable localization information](https://developer.apple.com/documentation/appstoreconnectapi/app-store-version-localizations).

API list requests follow pagination. Authentication uses short-lived ES256 JWTs. HTTP 429 and server errors are retried up to three times with capped delays; other HTTP errors fail immediately. Logs omit private keys, JWTs, submitted text, and API error response bodies.

Updates are separate requests per locale and cannot be atomic. If an update fails, the tool attempts the remaining locales and exits with status 1; earlier successful changes remain. Rerun after correcting the problem; identical notes are skipped. A network timeout may occur after Apple has accepted a request, so rerun to reconcile the result. No matching existing localizations is an error, rather than a successful no-op. Dry runs fetch current metadata but cannot guarantee Apple will accept a later write.

## Locale matching

The table below covers every locale in [Google Play's store listing language list](https://support.google.com/googleplay/android-developer/answer/9844778?hl=en), checked on 2026-10-18. Apple supports a smaller set; unsupported languages are explicitly skipped, never translated or relabeled as another language. See [Apple's localization reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations/).

Regional policies: `en-IN`, `en-SG`, and `en-ZA` use `en-GB`; `es-419` and `es-US` use `es-MX`; `zh-HK` and `zh-TW` use `zh-Hant`. These are deliberate fallbacks, not exact dialect equivalences. Renamed language codes (such as `iw-IL` → `he`) are normalized.

When both `zh-TW` and `zh-HK` are supplied, `zh-TW` takes precedence for `zh-Hant`, independent of file order, and `zh-HK` is logged as skipped. If `zh-TW` is absent or skipped with an override, `zh-HK` is used. Explicit overrides for `zh-HK` take precedence over this default policy.

For other collisions, identical text is deduplicated. Different text causes an error **before any writes**, independent of file order. Resolve it with a JSON override file:

```json
{
  "es-US": null,
  "en-IN": null,
  "en-SG": null,
  "en-ZA": null
}
```

```sh
appstore-release-notes --locale-map locale-map.json --apply
```

`null` skips that source. Non-null targets must be valid Apple locales. Overrides may also introduce an additional source alias. Mapping does not add a localization to the App Store listing: the target must already exist on the selected version. Prepared targets missing from that version are logged and skipped; existing languages without input remain unchanged.

| Google Play | App Store Connect |
| --- | --- |
| `af` | Unsupported — skipped |
| `sq` | Unsupported — skipped |
| `am` | Unsupported — skipped |
| `ar` | `ar-SA` |
| `hy-AM` | Unsupported — skipped |
| `az-AZ` | Unsupported — skipped |
| `bn-BD` | Unsupported — skipped |
| `eu-ES` | Unsupported — skipped |
| `be` | Unsupported — skipped |
| `bg` | Unsupported — skipped |
| `my-MM` | Unsupported — skipped |
| `ca` | `ca` |
| `zh-HK` | `zh-Hant` |
| `zh-CN` | `zh-Hans` |
| `zh-TW` | `zh-Hant` |
| `hr` | `hr` |
| `cs-CZ` | `cs` |
| `da-DK` | `da` |
| `nl-NL` | `nl-NL` |
| `en-AU` | `en-AU` |
| `en-CA` | `en-CA` |
| `en-US` | `en-US` |
| `en-GB` | `en-GB` |
| `en-IN` | `en-GB` |
| `en-SG` | `en-GB` |
| `en-ZA` | `en-GB` |
| `et` | Unsupported — skipped |
| `fil` | Unsupported — skipped |
| `fi-FI` | `fi` |
| `fr-CA` | `fr-CA` |
| `fr-FR` | `fr-FR` |
| `gl-ES` | Unsupported — skipped |
| `ka-GE` | Unsupported — skipped |
| `de-DE` | `de-DE` |
| `el-GR` | `el` |
| `gu` | Unsupported — skipped |
| `iw-IL` | `he` |
| `hi-IN` | `hi` |
| `hu-HU` | `hu` |
| `is-IS` | Unsupported — skipped |
| `id` | `id` |
| `it-IT` | `it` |
| `ja-JP` | `ja` |
| `kn-IN` | Unsupported — skipped |
| `kk` | Unsupported — skipped |
| `km-KH` | Unsupported — skipped |
| `ko-KR` | `ko` |
| `ky-KG` | Unsupported — skipped |
| `lo-LA` | Unsupported — skipped |
| `lv` | Unsupported — skipped |
| `lt` | Unsupported — skipped |
| `mk-MK` | Unsupported — skipped |
| `ms-MY` | `ms` |
| `ms` | `ms` |
| `ml-IN` | Unsupported — skipped |
| `mr-IN` | Unsupported — skipped |
| `mn-MN` | Unsupported — skipped |
| `ne-NP` | Unsupported — skipped |
| `no-NO` | `no` |
| `fa` | Unsupported — skipped |
| `fa-AE` | Unsupported — skipped |
| `fa-AF` | Unsupported — skipped |
| `fa-IR` | Unsupported — skipped |
| `pl-PL` | `pl` |
| `pt-BR` | `pt-BR` |
| `pt-PT` | `pt-PT` |
| `pa` | Unsupported — skipped |
| `ro` | `ro` |
| `rm` | Unsupported — skipped |
| `ru-RU` | `ru` |
| `sr` | Unsupported — skipped |
| `si-LK` | Unsupported — skipped |
| `sk` | `sk` |
| `sl` | Unsupported — skipped |
| `es-419` | `es-MX` |
| `es-ES` | `es-ES` |
| `es-US` | `es-MX` |
| `sw` | Unsupported — skipped |
| `sv-SE` | `sv` |
| `ta-IN` | Unsupported — skipped |
| `te-IN` | Unsupported — skipped |
| `th` | `th` |
| `tr-TR` | `tr` |
| `uk` | `uk` |
| `ur` | Unsupported — skipped |
| `vi` | `vi` |

## Image publishing

Connect this repository to `git@github.com:Aplicart-ad/appstore-release-notes.git`. The included GitHub Actions workflow runs tests and builds Linux amd64/arm64 images on main and pull requests. Pushing a version tag such as `v1.0.0` publishes `ghcr.io/aplicart-ad/appstore-release-notes:1.0.0` and the corresponding major tag `:1` using `GITHUB_TOKEN`.

The example image reference becomes usable after the first successful tag build. Set the GHCR package visibility to **Public** in the package settings to allow unauthenticated pulls. Consumers should pin a version or digest for reproducible pipelines. No image has been published by creating these files.
