# test-evowit

`test-evowit` is now a fresh iPhone MVP focused on one job only: real-time single-question recognition from the camera.

## Current scope

- live camera preview with a centered single-question guide frame
- on-device Vision OCR for preview text
- question block segmentation to decide which exact question is currently in frame
- cropped single-question snapshot output
- lightweight intent extraction for question number, subject, and question type
- iOS TestFlight delivery via XcodeGen + fastlane + GitHub Actions

## Repo layout

```text
.github/workflows/   iOS CI/CD and TestFlight automation
ios/                 SwiftUI app, Fastlane, XcodeGen config
scripts/             XcodeGen install and App Store helper scripts
```

## Local iOS build on Mac

```bash
cd ios
bash ../scripts/install_xcodegen.sh
bundle _2.4.22_ config set path vendor/bundle
bundle _2.4.22_ install
xcodegen generate
open test-evowit.xcodeproj
```

## TestFlight flow

The release path is:

1. Push to `main`
2. GitHub Actions runs the iOS TestFlight workflow on the self-hosted Mac runner
3. fastlane generates the project, archives the app, and uploads the build

Required secrets:

- `APPLE_ID`
- `APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`
- `MAC_KEYCHAIN_PASSWORD`

Optional but recommended:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `TESTFLIGHT_GROUPS`

The app declares `ITSAppUsesNonExemptEncryption=false` to reduce export compliance friction for this OCR-only MVP.
