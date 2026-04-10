# TestFlight Release Runbook

This runbook captures the release path that actually worked for `test-evowit` on `2026-04-09`.

Use it when:

- the self-hosted Mac runner is flaky
- a build uploads but does not appear in TestFlight
- signing, provisioning, or export compliance blocks the release

## App-specific constants

These values are specific to this app and are safe to keep in the repo:

- App name: `test-evowit`
- Bundle ID: `com.we555.test-evowit`
- App Store Connect Apple ID: `6761759350`
- Apple team ID: `76PHSCHPCK`
- Internal beta group: the existing internal tester group configured for this app

Do not store passwords, app-specific passwords, private keys, or GitHub tokens in the repo.

## Required secrets and files

Expected environment variables:

- `APPLE_ID`
- `APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_PATH`

Expected local file on the Mac:

- `~/.appstoreconnect/private_keys/AuthKey_<APP_STORE_CONNECT_KEY_ID>.p8`

## Network baseline on the Mac

Before blaming GitHub or Apple, verify that the Mac is not forcing traffic through a stale local proxy.

Commands:

```bash
networksetup -getwebproxy Wi-Fi
networksetup -getsecurewebproxy Wi-Fi
networksetup -getsocksfirewallproxy Wi-Fi
scutil --proxy
```

Known-good baseline:

- Wi-Fi `HTTPEnable = 0`
- Wi-Fi `HTTPSEnable = 0`
- Wi-Fi `SOCKSEnable = 0`
- `127.0.0.1:7897` may still exist as a local Clash listener, but the system proxy must stay disabled

In this project, direct access to GitHub and Apple endpoints was faster and more stable than the local proxy path.

## Source-of-truth project settings

The project should keep these release-related settings:

- `ios/project.yml`
  - `CURRENT_PROJECT_VERSION` must be incremented before every upload
  - `ITSAppUsesNonExemptEncryption: false`
- `ios/fastlane/Fastfile`
  - upload must include `apple_id`
  - upload must include `uses_non_exempt_encryption: false`
- `.github/workflows/ios-testflight.yml`
  - should prepare the App Store Connect key
  - should create or refresh App Store resources before archiving

## Provisioning profile bootstrap

Use the API helper to ensure the bundle ID, App Store Connect app record, and App Store provisioning profile exist:

```bash
python3 scripts/ensure_appstore_resources.py \
  --bundle-id com.we555.test-evowit \
  --app-name test-evowit \
  --sku test-evowit \
  --profile-name "test-evowit App Store" \
  --output-profile "$HOME/Library/MobileDevice/Provisioning Profiles/test-evowit-appstore.mobileprovision"
```

Notes:

- The script expects `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, and `APP_STORE_CONNECT_KEY_PATH`.
- If the app record already exists, the helper should reuse it.
- If the profile already exists, the helper should download it again rather than failing.

## Manual release fallback on the Mac

When CI is blocked, the reliable fallback is:

1. Unlock the login keychain.
2. Generate the Xcode project from `ios/project.yml`.
3. Archive with the `Apple Distribution` certificate and the `test-evowit App Store` provisioning profile.
4. Export an `.ipa`.
5. Upload with `altool`, passing the numeric Apple app ID.

Minimal sequence:

```bash
security unlock-keychain -p "<login-keychain-password>" ~/Library/Keychains/login.keychain-db
security set-key-partition-list -S apple-tool:,apple: -s -k "<login-keychain-password>" \
  ~/Library/Keychains/login.keychain-db >/dev/null

cd ios
bash ../scripts/install_xcodegen.sh
xcodegen generate
```

Important archive behavior:

- Automatic signing was not enough by itself for the successful fallback path.
- The working manual archive used:
  - signing identity: `Apple Distribution`
  - provisioning profile name: `test-evowit App Store`

Important upload behavior:

- `xcrun altool --upload-package ...` must include `--apple-id 6761759350`
- Without `--apple-id`, Apple may reject the upload with:
  - `Cannot determine the Apple ID from Bundle ID`

## Export compliance gotcha

This was the main reason builds `2`, `3`, and early `4` did not become testable.

Symptoms:

- Build upload succeeds
- App Store Connect shows the build under TestFlight
- `buildBetaDetails.internalBuildState` is `MISSING_EXPORT_COMPLIANCE`
- The TestFlight UI shows an export-compliance warning for the build

Permanent prevention:

- Keep `ITSAppUsesNonExemptEncryption: false` in `ios/project.yml`
- Keep `uses_non_exempt_encryption: false` in the upload lane

Manual recovery in App Store Connect:

1. Open `TestFlight -> iOS`.
2. Find the blocked build.
3. Click the `Manage` action next to the export-compliance warning.
4. Choose the option that means the app does not use non-exempt encryption.
5. Save.

Expected result:

- the build state changes from export-compliance blocked to ready for beta testing
- the build can be associated with the internal beta group

## Final success criteria

Do not consider the release done until all of these are true:

- `altool` reports upload success
- the build appears in App Store Connect under TestFlight
- `buildBetaDetails.internalBuildState == IN_BETA_TESTING`
- the build detail page shows one internal tester group attached
- the group lists `4` internal testers

## Fast checks

Programmatic check:

```bash
python3 scripts/check_testflight_status.py \
  --bundle-id com.we555.test-evowit \
  --build-version 4
```

Manual UI check:

1. Open `App Store Connect -> TestFlight -> iOS`.
2. Open the target build.
3. Confirm `Groups (1)` shows the internal tester group.

## Known-good result

Known-good build from `2026-04-09`:

- Marketing version: `1.0.0`
- Build version: `4`
- Delivery UUID: `b4046f66-4f40-4d56-b667-c30f42dd6d6a`
- Final beta state: `IN_BETA_TESTING`

If a future build regresses, compare it against this runbook before changing signing or network settings.
