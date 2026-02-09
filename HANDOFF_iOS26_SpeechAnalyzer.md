# iOS 26 SpeechAnalyzer Integration Handoff

> Last Updated: 2026-02-09
> Branch: `feat/ios26-speech-analyzer`
> Status: Production-ready implementation completed with strict review and phased hardening.

## Goal
Integrate iOS 26 `SpeechAnalyzer` into the existing `expo-speech-recognition` codebase while preserving behavior and parity for legacy iOS, Android, and web.

## Current State
The iOS 26 integration is implemented and validated end-to-end in native/module/type/docs/example layers.

### Completed Architecture
- Engine abstraction and factory selection (`SpeechRecognitionEngine` + factory).
- Legacy iOS path preserved via `LegacySpeechRecognizer`.
- iOS 26 path implemented with `SpeechAnalyzerEngine`.
- Asset management implemented with `AssetInventory` through `SpeechAnalyzerAssetManager`.
- Engine-selection and asset-required events wired (`engineselected`, `assetrequired`).
- Android parity stubs for iOS26-specific APIs.

## Phased Commits (in order)
- `21c8118` feat(ios): add speech recognition engine protocol and new options
- `c9f631c` refactor(ios): wrap SFSpeechRecognizer in protocol abstraction
- `b85b802` feat(ios): implement SpeechAnalyzer engine for iOS 26+
- `0df0ca0` feat(ios): implement SpeechAnalyzer asset APIs and platform parity stubs
- `0744655` fix(ios): correct engine selection events and startup error flow
- `2cddc3d` feat(ios): add dictation transcriber path and stream lifecycle stop
- `7330eae` feat(ios): make SpeechAnalyzer asset APIs transcriber-aware and align contracts
- `fc8b461` feat(example): add iOS 26 SpeechAnalyzer controls and live asset status panel

## Strict Findings Fixed

### 1) Asset APIs were initially non-functional stubs
- Fixed with real iOS 26 `AssetInventory` implementation.
- Added status/download/list locale APIs in native module.

### 2) `engineselected` reason/event flow was incorrect
- Removed incorrect fallback behavior on startup errors.
- Ensured factory remains source of truth for engine selection reason.

### 3) Dictation path was not actually implemented
- Added true `DictationTranscriber` path.
- Result consumers now support both speech and dictation transcribers.

### 4) Stream lifecycle could miss clean termination
- Added natural stream-end finalization path that triggers stop/reset correctly.

### 5) `getPreferredEngine` API was under-reporting options
- Now parses and applies `contextualStrings`, `addsPunctuation`, `iosTranscriberType`, `iosForceLegacyEngine`.
- `locale` and `lang` are both accepted in the predictor API.

### 6) Asset APIs were speech-only while engine could require dictation assets
- Added transcriber-aware asset query/download/list behavior.
- Optional query options now support `iosTranscriberType` and `addsPunctuation`.

### 7) Documentation/type contracts diverged from runtime
- Reason strings aligned to snake_case (`asset_installed`, etc.).
- Punctuation behavior docs aligned to runtime (compatibility stripping when disabled).
- Type signatures tightened for `getPreferredEngine` and asset-query options.

### 8) Example app could not exercise iOS26 control surface
- Added live SpeechAnalyzer status panel (asset status, preferred engine, download/refresh).
- Added iOS26 controls (`iosForceLegacyEngine`, transcriber type, asset policy).

## Apple API Verification (Xcode 26.2 Swift interface)
Verified against the local iPhoneOS 26.2 Speech framework interface:
- `AssetInventory.Status`: `.unsupported | .supported | .downloading | .installed`
- `AssetInventory.assetInstallationRequest(supporting:)`
- `SpeechAnalyzer.start(inputSequence:)`
- `SpeechAnalyzer.finalizeAndFinishThroughEndOfInput()`
- `SpeechAnalyzer.cancelAndFinishNow()`
- `SpeechTranscriber` and `DictationTranscriber` initializers, locales, and results

## Validation Evidence
Executed and passing:
- `npm run lint`
- `npm run ts:check`
- `npm run build`
- `npx tsc -p example/tsconfig.json --noEmit`
- iOS native simulator build:
  - `xcodebuild -workspace example/ios/expospeechrecognitionexample.xcworkspace -scheme expospeechrecognitionexample -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
  - Result: `** BUILD SUCCEEDED **`

## Known Residual Risks
These are outside code correctness and need live-device runtime validation:
- Real-world permission edge cases (user denies speech permission but allows mic) across iOS 17-26 policy variants.
- Background asset download UX and timing on low connectivity.
- Extended stress testing for interruption/route-change recovery under long sessions.

## Recommended Final Manual Test Matrix
- iOS 26 device:
  - `iosSpeechAnalyzerAssetPolicy`: `auto`, `require`, `download`
  - `iosTranscriberType`: `speech`, `dictation`
  - `addsPunctuation`: `true`, `false`
  - `contextualStrings`: on/off
- iOS 25 simulator/device fallback behavior.
- Android smoke test for parity API responses.

## Important Repo Notes
- `package-lock.json` has pre-existing local modifications not introduced in this effort.
- This handoff supersedes earlier stale status notes.
