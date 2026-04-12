# PhotoRename

Simple Flutter app that renames photos by EXIF date. Supports manual scan and auto‑monitoring of a selected folder.

## Quick Start

- Requirements: Flutter SDK (stable), Dart >= 3.11
- Install packages: `flutter pub get`
- Run: `flutter run`

## Troubleshooting

If you see many errors like “Target of URI doesn't exist: 'package:flutter/material.dart'” in VS Code:

- Ensure Flutter SDK is installed and added to PATH (`flutter --version`).
- In VS Code, set `Flutter: SDK Path` to your Flutter installation and reload the window.
- Open the project at the folder containing `pubspec.yaml` (this folder), not a parent folder.
- Fetch dependencies: `flutter pub get`.
- Restart the Dart analysis server: “Dart: Restart Analysis Server”.
- If issues persist, clean caches: `flutter clean && rm -rf .dart_tool build && flutter pub get`.

## Android permissions

- Android 13+: requests `READ_MEDIA_IMAGES` at runtime for listing/reading images. Renaming in shared storage (e.g., `DCIM/Camera`) uses MediaStore with a user consent dialog.
- Android 12L and below: requests legacy storage permission via `permission_handler`.

Notes:
- On Android 13+, direct `File.rename()` on `DCIM/Camera` is restricted. This app uses a native MediaStore flow to update `DISPLAY_NAME` after the user grants write consent.
- Auto‑monitoring in `DCIM/Camera` may require MediaStore‑based polling for some devices; current build uses filesystem polling which might not detect changes on all OEMs. If you need stronger detection, consider enabling a MediaStore query‑based scanner.

## iOS notes

- Directory selection uses the iOS document picker. If you intend to access the Photos library directly, add the appropriate usage descriptions to `ios/Runner/Info.plist` (e.g., `NSPhotoLibraryUsageDescription`).

## Tests

Run widget tests with: `flutter test`
