# Example app for expo-speech-recognition

This example app showcases most of the features of the `expo-speech-recognition` library. To get started:

```sh
# Install dependencies
npm install

# Also install dependencies of the root folder
cd ../
npm install

# Build the expo-speech-recognition library
npm run prepare

# Go back to the example folder and build the app
cd example

# Build the iOS app
npm run ios
# Build the Android app
npm run android

# Run the Metro JS bundling server
npm start
```

## Troubleshooting

### Microphone not working on Android emulator

Run either of the following commands to make sure that the host operating system is linked to the Android emulator:

```sh
adb emu avd hostmicon

npm run android:fix-emulator-mic
```

## iOS Automation Harness + Maestro

The example app now includes an iOS-only fixture-driven automation harness that validates:

- Legacy engine (`SFSpeechRecognizer`) force path
- iOS 26 `SpeechAnalyzer` path with contextual strings
- `maxAlternatives` / confidence / punctuation-stripping invariants
- `iosSpeechAnalyzerAssetPolicy: "require"` error flow
- File-source behavior without requiring microphone access

### Fixture source

Fixtures are located at:

- `example/assets/test-fixtures/audio/*`

### Run the iOS automation suite manually in app

1. Open the example app on iOS.
2. Scroll to the `iOS Automation Harness (Fixture Driven)` card.
3. Tap `Request iOS Permissions` once.
4. Tap `Run iOS Automation Suite`.
5. Wait for:
   - `IOS_AUTOMATION_STATUS:PASS`
   - `IOS_AUTOMATION_SUMMARY:PASS` or `PASS_WITH_SKIPS`

### Run with Maestro (default)

```sh
# From example/
npm run maestro:ios
```

### Run with Maestro (microphone denied precondition)

```sh
# From example/
npm run maestro:ios:mic-denied
```

### Notes

- The wrapper script `example/scripts/run-maestro-ios-suite.sh` boots a simulator (if needed) and sets microphone permission via `simctl privacy`.
- Apple does not expose speech-recognition permission control via `simctl privacy`; on a fresh simulator run, Maestro may need to tap iOS permission dialogs.
