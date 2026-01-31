# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

**expo-speech-recognition** is an Expo module that provides speech recognition capabilities for React Native apps. It wraps platform-native speech recognition APIs:
- **iOS**: `SFSpeechRecognizer` (iOS 13.4+), `SpeechAnalyzer` (iOS 26+)
- **Android**: `SpeechRecognizer` service

## Repository Structure

```
expo-speech-recognition/
├── src/                          # TypeScript source (compiled to build/)
│   ├── index.ts                  # Main exports
│   ├── constants.ts              # Enums and constants
│   ├── ExpoSpeechRecognitionModule.ts
│   ├── ExpoSpeechRecognitionModule.types.ts
│   └── ...
├── ios/                          # iOS native Swift code
│   ├── ExpoSpeechRecognitionModule.swift  # Main Expo module
│   ├── ExpoSpeechRecognizer.swift         # Core recognition engine
│   ├── SpeechRecognitionOptions.swift     # Options structs
│   ├── SpeechRecognitionEngine.swift      # Protocol (iOS 26+ abstraction)
│   └── ...
├── android/                      # Android native Kotlin code
│   └── src/main/java/expo/modules/speechrecognition/
├── example/                      # Example Expo app for testing
│   ├── App.tsx
│   ├── ios/                      # iOS Xcode project (generated)
│   └── android/                  # Android project (generated)
└── build/                        # Compiled TypeScript output
```

## Development Workflow

### Pre-commit Checklist

Run these commands before every commit:

```bash
# 1. Lint TypeScript/JavaScript
npm run lint

# 2. TypeScript type checking
npm run ts:check

# 3. Build the module
npm run build
```

### Full Verification (Before PR)

```bash
# All of the above, plus:

# 4. Install example dependencies
cd example && npm install && cd ..

# 5. iOS: Install pods and build
cd example/ios && pod install && cd ../..
# Then open in Xcode: npm run open:ios
# Build with Cmd+B to verify Swift compiles

# 6. Android: Build
cd example/android && ./gradlew assembleDebug && cd ../..

# 7. Run example app on simulator/device
cd example && npx expo run:ios  # or run:android
```

## Key Commands

| Command | Description |
|---------|-------------|
| `npm run lint` | Run ESLint on TypeScript/JavaScript |
| `npm run ts:check` | Run TypeScript compiler (no emit) |
| `npm run build` | Build the module (TypeScript → build/) |
| `npm run clean` | Clean build artifacts |
| `npm run open:ios` | Open iOS project in Xcode |
| `npm run open:android` | Open Android project in Android Studio |

### Example App Commands

```bash
cd example

# Install dependencies
npm install

# iOS
npx pod-install              # Install CocoaPods
npx expo run:ios             # Build and run on iOS simulator
npx expo run:ios --device    # Build and run on iOS device

# Android
npx expo run:android         # Build and run on Android emulator/device
```

## iOS Development Notes

### Swift Files Location
All iOS Swift files are in `/ios/`. The module is built using Expo Modules API.

### Key iOS Files
- `ExpoSpeechRecognitionModule.swift` - JavaScript interface, event emission
- `ExpoSpeechRecognizer.swift` - Main recognition actor (SFSpeechRecognizer)
- `SpeechRecognitionOptions.swift` - Configuration structs and enums
- `SpeechRecognitionEngine.swift` - Protocol for iOS 26+ abstraction

### Testing iOS Changes
1. Make Swift changes in `/ios/`
2. Run `npm run build` (rebuilds TypeScript if needed)
3. `cd example/ios && pod install` (if adding new files)
4. Open Xcode: `npm run open:ios`
5. Build (Cmd+B) to verify compilation
6. Run on simulator/device to test

### iOS Version Conditionals
Use `#available` for iOS version-specific code:
```swift
if #available(iOS 26, *) {
    // iOS 26+ code (SpeechAnalyzer)
} else {
    // Fallback code (SFSpeechRecognizer)
}
```

## Android Development Notes

### Kotlin Files Location
All Android Kotlin files are in `/android/src/main/java/expo/modules/speechrecognition/`.

### Testing Android Changes
1. Make Kotlin changes in `/android/`
2. Run `npm run build`
3. `cd example && npx expo run:android`

## TypeScript Development Notes

### Adding New Options
1. Add to `SpeechRecognitionOptions.swift` (iOS)
2. Add to `ExpoSpeechRecognitionOptions.kt` (Android)
3. Add to `ExpoSpeechRecognitionModule.types.ts` (TypeScript types)
4. Export from `index.ts` if needed

### Adding New Events
1. Add to native module's `Events()` declaration (iOS/Android)
2. Add to `ExpoSpeechRecognitionNativeEventMap` in types
3. Handle in native code

### Adding New Module Functions
1. Implement in `ExpoSpeechRecognitionModule.swift` (iOS)
2. Implement in `ExpoSpeechRecognitionModule.kt` (Android)
3. Add type declaration in `ExpoSpeechRecognitionModuleType` class

## Reference Materials

### iOS 26+ SpeechAnalyzer Integration
- **swift-scribe reference**: `/Users/barakxyz/personal/desktop-avatar/swift-scribe/`
  - Key file: `Scribe/Transcription/Transcription.swift`
- [Apple WWDC25 Video](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple SpeechAnalyzer Docs](https://developer.apple.com/documentation/speech/speechanalyzer)

### Expo Modules API
- [Expo Modules API Reference](https://docs.expo.dev/modules/module-api/)
- [Swift Module API](https://docs.expo.dev/modules/native-module/)

## Commit Conventions

Use conventional commits:
```
feat(ios): add SpeechAnalyzer support for iOS 26+
fix(android): handle null locale in recognition service
docs: update README with new options
refactor(ios): extract protocol for speech engines
```

**IMPORTANT**: Do NOT mention Claude or AI in commit messages. Keep commits professional and focused on what changed.

## Current Feature Branch

Working on: `feat/ios26-speech-analyzer`

Plan file: `/Users/barakxyz/.claude/plans/polished-jingling-sun.md`

### Phase Checklist Template

Before committing each phase:
- [ ] `npm run lint` passes
- [ ] `npm run ts:check` passes
- [ ] `npm run build` succeeds
- [ ] iOS builds in Xcode (if Swift changes)
- [ ] Android builds (if Kotlin changes)
- [ ] Example app runs (if testing needed)
