# NativeLooktokEngine — platform channel contract

Channel: `MethodChannel('com.looktok.app/engine')`
Dart side: `lib/services/native_looktok_engine.dart` (fail-soft: any error /
`MissingPluginException` → `null` → the caller falls back, so a platform may
simply not implement the channel and nothing breaks).

Payloads across the channel are **file paths, never bytes** — multi-MB images
must not be copied through the platform codec. Both sides write to their temp
dir; the *reader* deletes the file after use.

## Methods

### `isSegmentationSupported() -> bool`
Cheap capability probe, called once and cached by Dart.
- iOS: always `true` (iOS 17+ → Vision subject mask; 15.5–16 → person
  segmentation fallback).
- Android: `true` on API 24+ (model auto-downloads via Play Services; until it
  lands, extraction fails soft and Dart cascades).

### `extractSilhouette(imagePath: String) -> String?`
Dart callers: `NativeLooktokEngine.extractSilhouette(bytes)` or
`extractSilhouetteFromFile(path)` (no temp re-write for on-disk images);
`BackgroundRemovalService` in `background_removal.dart` is a thin façade over
the same engine for background-removal-flavored call sites.
Input: path to a JPEG/PNG. Output: path to a **transparent PNG, tight-cropped
to the subject** (person OR garment — subject segmentation, not selfie
segmentation), or `null` when no confident subject exists. Run inference OFF
the main/platform thread. On any error return `null`, not an exception — Dart
treats `null` as "use the next fallback" (selfie-segmentation plugin → remote
rembg → original bytes).

### `captureHighResPhoto() -> String?`
Present the native camera, return a path to the captured **JPEG, long side
≤ 1600 px, quality ~0.85** (sharp enough for segmentation + Gemini; small
enough that the raw-bytes fallback never blows the base64 payload budget).
`null` on cancel or when no camera is available. One capture at a time.

## iOS — IMPLEMENTED
`ios/Runner/NativeLooktokEngine.swift`, registered in `AppDelegate`.
Segmentation: Vision foreground-instance mask (iOS 17+, subjects = people AND
garments) with a `VNGeneratePersonSegmentationRequest` + `CIBlendWithMask`
fallback on iOS 15.5–16 (persons only). PNG via `CIContext`.
Capture: `UIImagePickerController(.camera)` from the root view controller.
No extra Podfile/Info.plist config: Vision is a system framework and
`NSCameraUsageDescription` is already present.

## Android — IMPLEMENTED (segmentation) / STUB (capture)
`android/app/src/main/kotlin/com/fitgestion/fitgestion/MainActivity.kt`.
Segmentation: ML Kit subject segmentation (`enableForegroundBitmap`), alpha
tight-crop + PNG off the main thread. Config already applied:
- `build.gradle.kts`: `minSdk = maxOf(flutter.minSdkVersion, 24)` +
  `implementation("com.google.android.gms:play-services-mlkit-subject-segmentation:16.0.0-beta1")`
- `AndroidManifest.xml`: `com.google.mlkit.vision.DEPENDENCIES = subject_segment`
  (Play Services fetches the model at install time).
`captureHighResPhoto` is a TODO stub (CameraX) — returns null, Flutter falls
back to image_picker.
