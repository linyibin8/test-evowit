# test-evowit

`test-evowit` is a student-facing iPhone app for photo-based homework solving.

It is optimized for a fast MVP path:

- iPhone app for camera capture and gallery import
- Node.js backend that sends homework photos to `gpt-5.4`
- structured answer output: problem text, answer, steps, explanations, and follow-up practice
- GitHub Actions pipeline for backend CI and Mac-based TestFlight delivery

## Why this approach

I reviewed current GitHub directions before locking the architecture:

- [Pix2Text](https://github.com/breezedeus/Pix2Text) is strong for OCR and formula extraction, but is heavier than needed for a first TestFlight build.
- [Texify](https://github.com/VikParuchuri/texify) is promising for formula-to-LaTeX, but it adds a separate model-serving path.
- Shipping fastest with the highest chance of success is a hosted multimodal solver path: photo upload -> structured `gpt-5.4` analysis -> simple, polished iOS client.

This repo keeps the server modular so local OCR or math-specific engines can be added later.

## Project layout

```text
.github/workflows/   CI/CD
backend/             Express + OpenAI solver API
ios/                 SwiftUI app + Fastlane + XcodeGen config
scripts/             helper scripts for Mac build tooling and Windows backend deploy
```

## Backend setup

```bash
cd backend
cp .env.example .env
npm install
npm run dev
```

Default server:

```text
http://0.0.0.0:21080
```

## iOS setup on Mac

```bash
cd ios
bash ../scripts/install_xcodegen.sh
bundle install
xcodegen generate
open test-evowit.xcodeproj
```

## TestFlight workflow

The intended release path is:

1. Push to GitHub `main`
2. GitHub Actions runs backend checks
3. GitHub Actions on the self-hosted Mac runner generates the Xcode project
4. Fastlane archives and uploads the build to TestFlight

Required GitHub secrets:

- `APPLE_ID`
- `APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_KEY_ID` optional but recommended
- `APP_STORE_CONNECT_ISSUER_ID` optional but recommended
- `APP_STORE_CONNECT_PRIVATE_KEY` optional but recommended
- `TESTFLIGHT_GROUPS` optional, comma-separated group names

Recommended GitHub variable:

- `BACKEND_BASE_URL`

