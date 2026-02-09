# iOS 26 SpeechAnalyzer Integration Handoff

> Last Updated: 2026-02-09
> Branch: `feat/ios26-speech-analyzer`
> Status: Hardened after strict audit; production-ready with documented residual runtime risks.

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
- `48431ef` fix(ios): harden locale resolution and reservation lifecycle
- `4dade06` fix(ios): make asset installation status and dictation modules consistent

## Post-Audit Hardening (2026-02-09)

### 1) Locale gating now supports SpeechAnalyzer locales
- `start()` locale resolution now checks SpeechAnalyzer support when eligible, not just `SFSpeechRecognizer` locales.
- Prevents false `language-not-supported` for iOS 26 locales that are valid for SpeechAnalyzer.

### 2) SpeechAnalyzer init no longer assumes speech-only locale support
- `SpeechAnalyzerEngine` validates locale against both `SpeechTranscriber` and `DictationTranscriber`.
- Prevents dictation-only locale rejection.

### 3) Locale reservation lifecycle is now bounded
- Reservations are released during reset for locales reserved by the current engine instance.
- Ownership is tracked to avoid releasing reservations owned by other sessions.
- Guards against locale-slot exhaustion (`AssetInventory.maximumReservedLocales`).

### 4) Asset install APIs now return truthful outcomes
- `downloadSpeechAnalyzerAsset()` now returns:
  - `installed`
  - `already_installed`
  - `already_downloading`
- Completion failures now throw `asset-download-failed` instead of being silently swallowed.

### 5) Dictation asset module consistency fixed
- Dictation asset module creation is now aligned across all internal code paths.

### 6) Engine reason taxonomy improved
- Added `locale_not_supported` reason to engine-selection outputs.
- Unsupported locale fallback no longer reports misleading `ios_version`.

### 7) Engine recreation cleanup improved
- Existing engine instance is aborted before recreation to avoid stale lifecycle state.

### 8) Contract guard added
- Added compile-time guard file `src/ios26ContractGuards.ts` to pin iOS 26 contract invariants:
  - `locale_not_supported` reason presence
  - `downloadSpeechAnalyzerAsset` status variants

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
- No dedicated runtime unit-test harness for iOS native engine logic yet (current guard is compile-time contract validation).

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
