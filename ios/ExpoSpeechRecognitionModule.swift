import AVFoundation
import ExpoModulesCore
import Speech

struct Segment {
  let startTimeMillis: Double
  let endTimeMillis: Double
  let segment: String
  let confidence: Float

  func toDictionary() -> [String: Any] {
    return [
      "startTimeMillis": startTimeMillis,
      "endTimeMillis": endTimeMillis,
      "segment": segment,
      "confidence": confidence,
    ]
  }
}

struct TranscriptionResult {
  let transcript: String
  let confidence: Float
  let segments: [Segment]

  func toDictionary() -> [String: Any] {
    return [
      "transcript": transcript,
      "confidence": confidence,
      "segments": segments.map { $0.toDictionary() },
    ]
  }
}

public class ExpoSpeechRecognitionModule: Module, SpeechRecognitionEngineDelegate {

  var speechRecognizer: (any SpeechRecognitionEngine)?

  // Hack for iOS 18 to detect final results
  // See: https://forums.developer.apple.com/forums/thread/762952 for more info
  // This is a temporary workaround until the issue is fixed in a future iOS release
  var hasSeenFinalResult: Bool = false

  // Hack for iOS 18 to avoid sending a "nomatch" event after the final-final result
  // Example event order emitted in iOS 18:
  // [
  //   { isFinal: false, transcripts: ["actually", "final", "results"], metadata: { duration: 1500 } },
  //   { isFinal: true, transcripts: [] }
  // ]
  var previousResult: SFSpeechRecognitionResult?

  // Store options for result handling
  var currentMaxAlternatives: Int = 5

  public func definition() -> ModuleDefinition {
    // Sets the name of the module that JavaScript code will use to refer to the module. Takes a string as an argument.
    // Can be inferred from module's class name, but it's recommended to set it explicitly for clarity.
    // The module will be accessible from `requireNativeModule('ExpoSpeechRecognition')` in JavaScript.
    Name("ExpoSpeechRecognition")

    OnDestroy {
      // Cancel any running speech recognizers
      Task {
        await speechRecognizer?.abort()
      }
    }

    // Defines event names that the module can send to JavaScript.
    Events(
      // Fired when the user agent has started to capture audio.
      "audiostart",
      // Fired when the user agent has finished capturing audio.
      "audioend",
      // Fired when the speech recognition service has disconnected.
      "end",
      // Fired when a speech recognition error occurs.
      "error",
      // Fired when the speech recognition service returns a final result with no significant
      // recognition. This may involve some degree of recognition, which doesn't meet or
      // exceed the confidence threshold.
      "nomatch",
      // Fired when the speech recognition service returns a result — a word or phrase has been
      // positively recognized and this has been communicated back to the app.
      "result",
      // Fired when any sound — recognizable speech or not — has been detected.
      "soundstart",
      // Fired when any sound — recognizable speech or not — has stopped being detected.
      "soundend",
      // Fired when sound that is recognized by the speech recognition service as speech
      // has been detected.
      "speechstart",
      // Fired when speech recognized by the speech recognition service has stopped being
      // detected.
      "speechend",
      // Fired when the speech recognition service has begun listening to incoming audio with
      // intent to recognize grammars associated with the current SpeechRecognition
      "start",
      // Called when the language detection (and switching) results are available.
      "languagedetection",
      // Fired when the input volume changes
      "volumechange",
      // Fired when engine is selected (iOS 26+)
      "engineselected",
      // Fired when SpeechAnalyzer assets are required but not installed (iOS 26+)
      "assetrequired"
    )

    OnCreate {
      guard let permissionsManager = appContext?.permissions else {
        return
      }
      permissionsManager.register([
        EXSpeechRecognitionPermissionRequester(),
        MicrophoneRequester(),
        SpeechRecognizerRequester(),
      ])
    }

    AsyncFunction("requestPermissionsAsync") { (promise: Promise) in
      guard let permissions = appContext?.permissions else {
        throw Exceptions.PermissionsModuleNotFound()
      }
      permissions.askForPermission(
        usingRequesterClass: EXSpeechRecognitionPermissionRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("getPermissionsAsync") { (promise: Promise) in
      guard let permissions = self.appContext?.permissions else {
        throw Exceptions.PermissionsModuleNotFound()
      }
      permissions.getPermissionUsingRequesterClass(
        EXSpeechRecognitionPermissionRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("getMicrophonePermissionsAsync") { (promise: Promise) in
      appContext?.permissions?.getPermissionUsingRequesterClass(
        MicrophoneRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("requestMicrophonePermissionsAsync") { (promise: Promise) in
      appContext?.permissions?.askForPermission(
        usingRequesterClass: MicrophoneRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("getSpeechRecognizerPermissionsAsync") { (promise: Promise) in
      appContext?.permissions?.getPermissionUsingRequesterClass(
        SpeechRecognizerRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("requestSpeechRecognizerPermissionsAsync") { (promise: Promise) in
      appContext?.permissions?.askForPermission(
        usingRequesterClass: SpeechRecognizerRequester.self,
        resolve: promise.resolver,
        reject: promise.legacyRejecter
      )
    }

    AsyncFunction("getStateAsync") { (promise: Promise) in
      Task {
        let state = await speechRecognizer?.getState()
        promise.resolve(state ?? "inactive")
      }
    }

    /** Start recognition with args: lang, interimResults, maxAlternatives */
    Function("start") { (options: SpeechRecognitionOptions) in
      Task {
        do {
          let currentLocale = await speechRecognizer?.getLocale()

          // Reset the previous result
          self.previousResult = nil
          self.currentMaxAlternatives = max(1, options.maxAlternatives)

          // Resolve the locale first
          guard let locale = await resolveLocale(localeIdentifier: options.lang, options: options)
          else {
            let availableLocales = await getAvailableLocalesForErrorMessage(options: options)

            sendErrorAndStop(
              error: "language-not-supported",
              message:
                "Locale \(options.lang) is not supported by the selected speech engines. Available locales: \(availableLocales)"
            )
            return
          }

          // Check permissions before engine creation to avoid side effects
          // (e.g. triggering asset downloads) when authorization is missing.
          if await shouldRequireSpeechRecognizerPermission(locale: locale, options: options) {
            guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
              sendErrorAndStop(
                error: "not-allowed",
                message: RecognizerError.notAuthorizedToRecognize.message
              )
              return
            }
          }

          if shouldRequireMicrophonePermission(options: options) {
            guard await AVAudioSession.sharedInstance().hasPermissionToRecord() else {
              sendErrorAndStop(
                error: "not-allowed",
                message: RecognizerError.notPermittedToRecord.message
              )
              return
            }
          }

          // Determine whether to recreate the engine
          // iOS 26+: Always recreate - engine selection depends on options AND asset status
          // iOS < 26: Only recreate when locale changes - engine is always SFSpeechRecognizer
          let shouldRecreateEngine: Bool
          if #available(iOS 26, *) {
            // Options like iosForceLegacyEngine and asset status
            // affect engine selection on iOS 26+ - must evaluate fresh each time
            shouldRecreateEngine = true
          } else {
            // Engine is fixed on older iOS - only recreate for locale changes
            shouldRecreateEngine = self.speechRecognizer == nil || currentLocale != options.lang
          }

          if shouldRecreateEngine {
            if let existingEngine = self.speechRecognizer {
              await existingEngine.abort()
            }
            self.speechRecognizer = try await SpeechRecognitionEngineFactory.createEngine(
              locale: locale,
              options: options,
              delegate: self
            )
          }

          // Start recognition using the engine's delegate-based API
          try await speechRecognizer?.start(
            options: options,
            delegate: self
          )
        } catch {
          self.hasSeenFinalResult = false
          self.previousResult = nil
          self.handleRecognitionError(error)
          self.sendEvent("end")
        }
      }
    }

    Function("setCategoryIOS") { (options: SetCategoryOptions) in
      // Convert the array of category options to a bitmask
      let categoryOptions = options.categoryOptions.reduce(AVAudioSession.CategoryOptions()) {
        result, option in
        result.union(option.avCategoryOption)
      }

      try AVAudioSession.sharedInstance().setCategory(
        options.category.avCategory,
        mode: options.mode.avMode,
        options: categoryOptions
      )
    }

    Function("getAudioSessionCategoryAndOptionsIOS") { () -> [String: Any] in
      let instance = AVAudioSession.sharedInstance()

      let categoryOptions: AVAudioSession.CategoryOptions = instance.categoryOptions

      var allCategoryOptions: [(option: AVAudioSession.CategoryOptions, string: String)] = [
        (.mixWithOthers, "mixWithOthers"),
        (.duckOthers, "duckOthers"),
        (.allowBluetooth, "allowBluetooth"),
        (.defaultToSpeaker, "defaultToSpeaker"),
        (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudioAndMixWithOthers"),
        (.allowBluetoothA2DP, "allowBluetoothA2DP"),
        (.allowAirPlay, "allowAirPlay"),
      ]

      // Define a mapping from CategoryOptions to their string representations
      if #available(iOS 14.5, *) {
        allCategoryOptions.append(
          (.overrideMutedMicrophoneInterruption, "overrideMutedMicrophoneInterruption"))
      }

      // Filter and map the options that are set
      let categoryOptionsStrings =
        allCategoryOptions
        .filter { categoryOptions.contains($0.option) }
        .map { $0.string }

      let categoryMapping: [AVAudioSession.Category: String] = [
        .ambient: "ambient",
        .playback: "playback",
        .record: "record",
        .playAndRecord: "playAndRecord",
        .multiRoute: "multiRoute",
        .soloAmbient: "soloAmbient",
      ]

      let modeMapping: [AVAudioSession.Mode: String] = [
        .default: "default",
        .gameChat: "gameChat",
        .measurement: "measurement",
        .moviePlayback: "moviePlayback",
        .spokenAudio: "spokenAudio",
        .videoChat: "videoChat",
        .videoRecording: "videoRecording",
        .voiceChat: "voiceChat",
        .voicePrompt: "voicePrompt",
      ]

      return [
        "category": categoryMapping[instance.category] ?? instance.category.rawValue,
        "categoryOptions": categoryOptionsStrings,
        "mode": modeMapping[instance.mode] ?? instance.mode.rawValue,
      ]
    }

    Function("setAudioSessionActiveIOS") {
      (value: Bool, options: SetAudioSessionActiveOptions?) throws in
      let setActiveOptions: AVAudioSession.SetActiveOptions =
        options?.notifyOthersOnDeactivation == true ? .notifyOthersOnDeactivation : []

      try AVAudioSession.sharedInstance().setActive(value, options: setActiveOptions)
    }

    Function("supportsOnDeviceRecognition") { () -> Bool in
      let recognizer = SFSpeechRecognizer()
      return recognizer?.supportsOnDeviceRecognition ?? false
    }

    Function("supportsRecording") { () -> Bool in
      return true
    }

    Function("isRecognitionAvailable") { () -> Bool in
      let recognizer = SFSpeechRecognizer()
      return recognizer?.isAvailable ?? false
    }

    Function("stop") { () -> Void in
      Task {
        if let recognizer = speechRecognizer {
          await recognizer.stop()
        } else {
          sendEvent("end")
        }
      }
    }

    Function("abort") { () -> Void in
      Task {
        sendEvent("error", ["error": "aborted", "message": "Speech recognition aborted."])

        if let recognizer = speechRecognizer {
          await recognizer.abort()
        } else {
          sendEvent("end")
        }
      }
    }

    Function("getSpeechRecognitionServices") { () -> [String] in
      // Return an empty array on iOS
      return []
    }

    AsyncFunction("getSupportedLocales") { (options: GetSupportedLocaleOptions, promise: Promise) in
      let supportedLocales = SFSpeechRecognizer.supportedLocales().map { $0.identifier }.sorted()
      let installedLocales = supportedLocales

      // Return as an object
      promise.resolve([
        "locales": supportedLocales,
        // On iOS, the installed locales are the same as the supported locales
        "installedLocales": installedLocales,
      ])
    }

    Function("getDefaultRecognitionService") { () -> [String: Any] in
      return [
        "packageName": ""
      ]
    }

    Function("getAssistantService") { () -> [String: Any] in
      return [
        "packageName": ""
      ]
    }

    // MARK: - iOS 26+ SpeechAnalyzer Functions

    AsyncFunction("getSpeechAnalyzerAssetStatus") {
      (locale: String, options: [String: Any]?, promise: Promise) in
      let normalizedLocale = locale.replacingOccurrences(of: "_", with: "-")
      let useDictation = self.shouldUseDictationForAssetOptions(options)

      if #available(iOS 26, *) {
        Task {
          let locale = Locale(identifier: normalizedLocale)
          let info = await SpeechAnalyzerAssetManager.shared.getAssetStatus(
            for: locale,
            useDictation: useDictation
          )
          promise.resolve(self.assetInfoToDictionary(info))
        }
      } else {
        promise.resolve([
          "locale": normalizedLocale,
          "status": SpeechAnalyzerAssetStatus.notAvailable.rawValue,
          "progress": nil,
        ] as [String: Any?])
      }
    }

    AsyncFunction("downloadSpeechAnalyzerAsset") {
      (locale: String, options: [String: Any]?, promise: Promise) in
      let normalizedLocale = locale.replacingOccurrences(of: "_", with: "-")
      let useDictation = self.shouldUseDictationForAssetOptions(options)

      if #available(iOS 26, *) {
        Task {
          let locale = Locale(identifier: normalizedLocale)
          do {
            let result = try await SpeechAnalyzerAssetManager.shared.downloadAsset(
              for: locale,
              useDictation: useDictation
            )
            promise.resolve([
              "status": result.rawValue,
              "locale": normalizedLocale,
            ])
          } catch let error as SpeechRecognitionEngineError {
            promise.reject(error.code, error.message)
          } catch {
            promise.reject(
              SpeechRecognitionEngineError.assetDownloadFailed(locale: normalizedLocale).code,
              SpeechRecognitionEngineError.assetDownloadFailed(locale: normalizedLocale).message
            )
          }
        }
      } else {
        promise.reject(
          SpeechRecognitionEngineError.assetDownloadFailed(locale: normalizedLocale).code,
          "SpeechAnalyzer asset download requires iOS 26 or later."
        )
      }
    }

    AsyncFunction("getSpeechAnalyzerLocales") { (options: [String: Any]?, promise: Promise) in
      let useDictation = self.shouldUseDictationForAssetOptions(options)

      if #available(iOS 26, *) {
        Task {
          let locales = await SpeechAnalyzerAssetManager.shared.getAllLocalesStatus(
            useDictation: useDictation
          )
          promise.resolve(locales.map { self.assetInfoToDictionary($0) })
        }
      } else {
        promise.resolve([] as [[String: Any]])
      }
    }

    AsyncFunction("getPreferredEngine") {
      (options: [String: Any]?, promise: Promise) in
      let localeIdentifier =
        (
          (options?["locale"] as? String)
          ?? (options?["lang"] as? String)
        )?
        .replacingOccurrences(of: "_", with: "-")
      let iosForceLegacyEngine = options?["iosForceLegacyEngine"] as? Bool ?? false
      let contextualStrings = options?["contextualStrings"] as? [String]
      let addsPunctuation = options?["addsPunctuation"] as? Bool ?? false
      let iosTranscriberTypeRaw = options?["iosTranscriberType"] as? String
      let iosSpeechAnalyzerAssetPolicyRaw = options?["iosSpeechAnalyzerAssetPolicy"] as? String

      let recognitionOptions = SpeechRecognitionOptions()
      recognitionOptions.iosForceLegacyEngine = iosForceLegacyEngine
      recognitionOptions.contextualStrings = contextualStrings
      recognitionOptions.addsPunctuation = addsPunctuation

      if let iosTranscriberTypeRaw,
        let iosTranscriberType = IOSTranscriberType(rawValue: iosTranscriberTypeRaw)
      {
        recognitionOptions.iosTranscriberType = iosTranscriberType
      }

      if let iosSpeechAnalyzerAssetPolicyRaw,
        let iosSpeechAnalyzerAssetPolicy = IOSSpeechAnalyzerAssetPolicy(
          rawValue: iosSpeechAnalyzerAssetPolicyRaw)
      {
        recognitionOptions.iosSpeechAnalyzerAssetPolicy = iosSpeechAnalyzerAssetPolicy
      }

      Task {
        if #available(iOS 26, *) {
          let locale = Locale(identifier: localeIdentifier ?? "en-US")
          let info = await SpeechRecognitionEngineFactory.getPreferredEngineAsync(
            locale: locale,
            options: recognitionOptions
          )

          promise.resolve([
            "engine": info.engine.rawValue,
            "reason": info.reason.rawValue,
          ])
          return
        }

        let info = SpeechRecognitionEngineFactory.getPreferredEngine(
          locale: localeIdentifier,
          options: recognitionOptions
        )

        promise.resolve([
          "engine": info.engine.rawValue,
          "reason": info.reason.rawValue,
        ])
      }
    }
  }

  // MARK: - SpeechRecognitionEngineDelegate

  func onResult(_ result: SFSpeechRecognitionResult) {
    handleRecognitionResult(result, maxAlternatives: currentMaxAlternatives)
  }

  func onUnifiedResult(_ result: UnifiedTranscriptionResult) {
    handleUnifiedResult(result)
  }

  func onError(_ error: Error) {
    handleRecognitionError(error)
  }

  func onStart() {
    sendEvent("start")
  }

  func onSpeechStart() {
    sendEvent("speechstart")
  }

  func onSpeechEnd() {
    sendEvent("speechend")
  }

  func onSoundStart() {
    sendEvent("soundstart")
  }

  func onSoundEnd() {
    sendEvent("soundend")
  }

  func onAudioStart(filePath: String?) {
    if let filePath = filePath {
      let uri = filePath.hasPrefix("file://") ? filePath : "file://" + filePath
      sendEvent("audiostart", ["uri": uri])
    } else {
      sendEvent("audiostart", ["uri": nil])
    }
  }

  func onAudioEnd(filePath: String?) {
    if let filePath = filePath {
      let uri = filePath.hasPrefix("file://") ? filePath : "file://" + filePath
      sendEvent("audioend", ["uri": uri])
    } else {
      sendEvent("audioend", ["uri": nil])
    }
  }

  func onEnd() {
    hasSeenFinalResult = false
    previousResult = nil
    sendEvent("end")
  }

  func onVolumeChange(_ value: Float) {
    sendEvent("volumechange", ["value": value])
  }

  func onEngineSelected(_ info: EngineSelectionInfo) {
    sendEvent("engineselected", [
      "engine": info.engine.rawValue,
      "reason": info.reason.rawValue,
    ])
  }

  func onAssetRequired(locale: String, status: SpeechAnalyzerAssetStatus, progress: Double?) {
    sendEvent("assetrequired", [
      "locale": locale,
      "status": status.rawValue,
      "progress": progress as Any,
    ])
  }

  // MARK: - Helpers

  /** Normalizes the locale for compatibility between Android and iOS */
  func resolveLocale(localeIdentifier: String, options: SpeechRecognitionOptions) async -> Locale? {
    // The supportedLocales() method returns locales in BCP-47 format (e.g. "en-US"),
    // but callers may pass underscores (e.g. "en_US"), so normalize before checks.
    let normalizedIdentifier = normalizeLocaleIdentifier(localeIdentifier)
    let locale = Locale(identifier: normalizedIdentifier)

    let supportedLegacyLocales = SFSpeechRecognizer.supportedLocales()
    let isLegacySupported = supportedLegacyLocales.contains { supported in
      normalizeLocaleIdentifier(supported.identifier) == normalizedIdentifier
    }
    if isLegacySupported {
      return locale
    }

    guard shouldEvaluateSpeechAnalyzerSupport(options: options) else {
      return nil
    }

    if #available(iOS 26, *) {
      let useDictation =
        options.iosTranscriberType == .dictation
        || options.addsPunctuation
      let isAnalyzerSupported = await SpeechAnalyzerEngine.isLocaleSupported(
        locale,
        useDictation: useDictation
      )
      if isAnalyzerSupported {
        return locale
      }
    }

    return nil
  }

  private func shouldEvaluateSpeechAnalyzerSupport(options: SpeechRecognitionOptions) -> Bool {
    if options.iosForceLegacyEngine {
      return false
    }
    return true
  }

  private func shouldRequireSpeechRecognizerPermission(
    locale: Locale,
    options: SpeechRecognitionOptions
  ) async -> Bool {
    if #available(iOS 26, *) {
      let preferredEngine = await SpeechRecognitionEngineFactory.getPreferredEngineAsync(
        locale: locale,
        options: options
      )
      return preferredEngine.engine == .sfSpeechRecognizer
    }

    return true
  }

  private func shouldRequireMicrophonePermission(options: SpeechRecognitionOptions) -> Bool {
    guard let audioSourceURI = options.audioSource?.uri else {
      return true
    }
    return audioSourceURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func normalizeLocaleIdentifier(_ localeIdentifier: String) -> String {
    localeIdentifier.replacingOccurrences(of: "_", with: "-")
  }

  private func getAvailableLocalesForErrorMessage(options: SpeechRecognitionOptions) async -> String {
    var availableLocales = Set(
      SFSpeechRecognizer.supportedLocales().map { normalizeLocaleIdentifier($0.identifier) }
    )

    if shouldEvaluateSpeechAnalyzerSupport(options: options), #available(iOS 26, *) {
      let useDictation =
        options.iosTranscriberType == .dictation
        || options.addsPunctuation
      let analyzerLocales = await SpeechAnalyzerEngine.getSupportedLocales(useDictation: useDictation)
      for locale in analyzerLocales {
        availableLocales.insert(normalizeLocaleIdentifier(locale.identifier))
      }
    }

    return availableLocales.sorted().joined(separator: ", ")
  }

  func sendErrorAndStop(error: String, message: String) {
    hasSeenFinalResult = false
    previousResult = nil
    sendEvent("error", ["error": error, "message": message])
    sendEvent("end")
  }

  func assetInfoToDictionary(_ info: SpeechAnalyzerAssetInfo) -> [String: Any?] {
    return [
      "locale": info.locale,
      "status": info.status.rawValue,
      "progress": info.progress,
    ]
  }

  func shouldUseDictationForAssetOptions(_ options: [String: Any]?) -> Bool {
    let addsPunctuation = options?["addsPunctuation"] as? Bool ?? false
    let iosTranscriberType = options?["iosTranscriberType"] as? String
    return addsPunctuation || iosTranscriberType == IOSTranscriberType.dictation.rawValue
  }

  func handleRecognitionResult(_ result: SFSpeechRecognitionResult, maxAlternatives: Int) {
    var results: [TranscriptionResult] = []

    // Limit the number of transcriptions to the maxAlternatives
    let transcriptionSubsequence = result.transcriptions.prefix(maxAlternatives)

    var isFinal = result.isFinal

    // Hack for iOS 18 to detect final results
    // See: https://forums.developer.apple.com/forums/thread/762952 for more info
    // This is a temporary workaround until the issue is fixed in a future iOS release
    if #available(iOS 18.0, *), !isFinal {
      isFinal = result.speechRecognitionMetadata?.speechDuration ?? 0 > 0
    }

    for transcription in transcriptionSubsequence {
      var transcript = transcription.formattedString

      // Prepend an empty space if the hacky workaround is applied
      // So that the user can append the transcript to the previous result,
      // matching the behavior of Android & Web Speech API
      if hasSeenFinalResult {
        transcript = " " + transcription.formattedString
      }

      let segments = transcription.segments.map { segment in
        return Segment(
          startTimeMillis: segment.timestamp * 1000,
          endTimeMillis: (segment.timestamp * 1000) + segment.duration * 1000,
          segment: segment.substring,
          confidence: segment.confidence
        )
      }

      let confidence =
        transcription.segments.map { $0.confidence }.reduce(0, +)
        / Float(transcription.segments.count)

      let item = TranscriptionResult(
        transcript: transcript,
        confidence: confidence,
        segments: segments
      )

      if !transcription.formattedString.isEmpty {
        results.append(item)
      }
    }

    // Apply the "workaround"
    if #available(iOS 18.0, *), !result.isFinal, isFinal {
      hasSeenFinalResult = true
    }

    if isFinal && results.isEmpty {
      // Hack for iOS 18 to avoid sending a "nomatch" event after the final-final result
      var previousResultWasFinal = false
      var previousResultHadTranscriptions = false
      if #available(iOS 18.0, *), let previousResult = previousResult {
        previousResultWasFinal = previousResult.speechRecognitionMetadata?.speechDuration ?? 0 > 0
        previousResultHadTranscriptions = !previousResult.transcriptions.isEmpty
      }

      if !previousResultWasFinal || !previousResultHadTranscriptions {
        // https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition/nomatch_event
        // The nomatch event of the Web Speech API is fired
        // when the speech recognition service returns a final result with no significant recognition.
        sendEvent("nomatch")
        return
      }
    }

    sendEvent(
      "result",
      [
        "isFinal": isFinal,
        "results": results.map { $0.toDictionary() },
      ]
    )

    previousResult = result
  }

  /// Handles results from SpeechAnalyzer (iOS 26+)
  /// Uses the unified result format since SFSpeechRecognitionResult can't be created directly
  func handleUnifiedResult(_ result: UnifiedTranscriptionResult) {
    var results: [TranscriptionResult] = []
    let maxAlternatives = max(1, currentMaxAlternatives)
    var seenTranscripts = Set<String>()

    if !result.transcript.isEmpty {
      // Convert unified segments to local Segment type
      let segments = result.segments.map { segment in
        return Segment(
          startTimeMillis: segment.startTimeMillis,
          endTimeMillis: segment.endTimeMillis,
          segment: segment.segment,
          confidence: segment.confidence
        )
      }

      var transcript = result.transcript

      // Apply space prefix for continuous mode (matching legacy behavior)
      if hasSeenFinalResult {
        transcript = " " + result.transcript
      }

      let item = TranscriptionResult(
        transcript: transcript,
        confidence: result.confidence,
        segments: segments
      )
      results.append(item)
      seenTranscripts.insert(result.transcript)
    }

    if maxAlternatives > results.count {
      let remainingSlots = maxAlternatives - results.count
      let additionalAlternatives = result.alternatives
        .filter { !$0.transcript.isEmpty && !seenTranscripts.contains($0.transcript) }
        .prefix(remainingSlots)

      for alternative in additionalAlternatives {
        let transcript = hasSeenFinalResult ? " " + alternative.transcript : alternative.transcript
        results.append(
          TranscriptionResult(
            transcript: transcript,
            confidence: alternative.confidence,
            segments: []
          )
        )
        seenTranscripts.insert(alternative.transcript)
      }
    }

    // Track final results for continuous mode
    if result.isFinal {
      hasSeenFinalResult = true
    }

    // Handle nomatch case
    if result.isFinal && results.isEmpty {
      sendEvent("nomatch")
      return
    }

    sendEvent(
      "result",
      [
        "isFinal": result.isFinal,
        "results": results.map { $0.toDictionary() },
      ]
    )
  }

  func handleRecognitionError(_ error: Error) {
    // Handle legacy RecognizerError (from LegacySpeechRecognizer)
    if let recognitionError = error as? RecognizerError {
      switch recognitionError {
      case .nilRecognizer:
        sendEvent(
          "error", ["error": "language-not-supported", "message": recognitionError.message])
      case .notAuthorizedToRecognize:
        sendEvent("error", ["error": "not-allowed", "message": recognitionError.message])
      case .notPermittedToRecord:
        sendEvent("error", ["error": "not-allowed", "message": recognitionError.message])
      case .recognizerIsUnavailable:
        sendEvent("error", ["error": "service-not-allowed", "message": recognitionError.message])
      case .invalidAudioSource:
        sendEvent("error", ["error": "audio-capture", "message": recognitionError.message])
      case .audioInputBusy:
        sendEvent("error", ["error": "audio-capture", "message": recognitionError.message])
      case .audioSessionInterrupted:
        sendEvent("error", ["error": "interrupted", "message": recognitionError.message])
      case .audioRouteChanged:
        sendEvent("error", ["error": "audio-capture", "message": recognitionError.message])
      }
      return
    }

    // Handle SpeechRecognitionEngineError (from SpeechAnalyzerEngine iOS 26+)
    if let engineError = error as? SpeechRecognitionEngineError {
      sendEvent("error", ["error": engineError.code, "message": engineError.message])
      return
    }

    // Other errors thrown by SFSpeechRecognizer / SFSpeechRecognitionTask

    /*
     Error Code | Error Domain | Description
     102 | kLSRErrorDomain | Assets are not installed.
     201 | kLSRErrorDomain | Siri or Dictation is disabled.
     300 | kLSRErrorDomain | Failed to initialize recognizer.
     301 | kLSRErrorDomain | Request was canceled.
     203 | kAFAssistantErrorDomain | Failure occurred during speech recognition.
     1100 | kAFAssistantErrorDomain | Trying to start recognition while an earlier instance is still active.
     1101 | kAFAssistantErrorDomain | Connection to speech process was invalidated.
     1107 | kAFAssistantErrorDomain | Connection to speech process was interrupted.
     1110 | kAFAssistantErrorDomain | Failed to recognize any speech.
     1700 | kAFAssistantErrorDomain | Request is not authorized.
     */
    let nsError = error as NSError
    let errorCode = nsError.code

    let errorTypes: [(codes: [Int], code: String, message: String)] = [
      (
        [102, 201], "service-not-allowed",
        "Assets are not installed, Siri or Dictation is disabled."
      ),
      ([203], "audio-capture", "Failure occurred during speech recognition."),
      ([1100], "busy", "Trying to start recognition while an earlier instance is still active."),
      ([1101, 1107], "network", "Connection to speech process was invalidated or interrupted."),
      ([1110], "no-speech", "No speech was detected."),
      ([1700], "not-allowed", "Request is not authorized."),
    ]

    for (codes, code, message) in errorTypes {
      if codes.contains(errorCode) {
        // Handle nomatch error for the underlying error:
        // +[AFAggregator logDictationFailedWithErrr:] Error Domain=kAFAssistantErrorDomain Code=203 "Retry" UserInfo={NSLocalizedDescription=Retry, NSUnderlyingError=0x600000d0ca50 {Error Domain=SiriSpeechErrorDomain Code=1 "(null)"}}
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
          if errorCode == 203 && underlyingError.domain == "SiriSpeechErrorDomain"
            && underlyingError.code == 1
          {
            sendEvent("nomatch")
          } else {
            sendEvent("error", ["error": code, "message": message])
          }
        } else {
          sendEvent("error", ["error": code, "message": message])
        }
        return
      }
    }

    // Unknown error (but not a canceled request)
    if errorCode != 301 {
      sendEvent("error", ["error": "audio-capture", "message": error.localizedDescription])
    }
  }
}
