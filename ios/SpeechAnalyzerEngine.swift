import AVFoundation
import Accelerate
import Foundation
import Speech
import os

/// iOS 26+ SpeechAnalyzer-based engine
/// Implements the SpeechRecognitionEngine protocol using Apple's new SpeechAnalyzer API
@available(iOS 26, *)
actor SpeechAnalyzerEngine: SpeechRecognitionEngine {
  // MARK: - Types

  /// Error types specific to SpeechAnalyzer
  enum AnalyzerError: Error {
    case failedToCreateTranscriber
    case failedToCreateAnalyzer
    case invalidAudioFormat
    case analyzerNotStarted
    case localeNotSupported
    case assetNotInstalled
    case bufferConversionFailed
    case localeReservationFailed
  }

  enum ActiveTranscriber {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)
  }

  // MARK: - Properties

  private var options: SpeechRecognitionOptions?
  private var locale: Locale
  private var audioEngine: AVAudioEngine?
  private var mixerNode: AVAudioMixerNode?
  private var speechTranscriber: SpeechTranscriber?
  private var dictationTranscriber: DictationTranscriber?
  private var analyzer: SpeechAnalyzer?
  private var analyzerFormat: AVAudioFormat?

  /// AsyncStream for feeding audio to the analyzer
  private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?

  /// Task for consuming recognition results
  private var resultsTask: Task<Void, Error>?

  /// Task for file streaming
  private var fileStreamingTask: Task<Void, Never>?

  /// Audio buffer converter for format conversion
  private var bufferConverter: AudioBufferConverter?

  /// Delegate for receiving recognition events
  private weak var delegate: SpeechRecognitionEngineDelegate?

  /// Current recognition state
  private var state: String = "inactive"

  /// Whether speech has been detected (for speechstart event)
  private var hasSpeechStarted = false

  /// Whether sound has been detected (for soundstart event)
  private var hasSoundStarted = false

  /// Audio file recording support
  private var audioFileRef: ExtAudioFileRef?
  private var outputFileUrl: URL?

  /// Audio session observers
  private var audioSessionInterruptionObserver: NSObjectProtocol?
  private var audioSessionRouteChangeObserver: NSObjectProtocol?

  /// Whether the recognizer has been stopped by the user
  private var stoppedListening = false

  /// Whether the locale has been reserved (must release on cleanup)
  private var localeReserved = false

  /// For volume change events
  @MainActor var volumeChangeHandler: ((Float) -> Void)?
  @MainActor var endHandler: (() -> Void)?
  @MainActor var audioEndHandler: ((String?) -> Void)?
  @MainActor var errorHandler: ((Error) -> Void)?

  /// Detection timer for non-continuous mode (matches legacy behavior)
  @MainActor var detectionTimer: Timer?

  // MARK: - Initialization

  init(locale: Locale) async throws {
    self.locale = locale

    // Verify locale is supported
    let supportedLocales = await SpeechTranscriber.supportedLocales
    let isSupported = supportedLocales.contains { supported in
      Self.localesMatch(supported, locale)
    }

    guard isSupported else {
      print(
        "[SpeechAnalyzerEngine] Locale \(locale.identifier) not supported. Supported: \(supportedLocales.map { $0.identifier })"
      )
      throw AnalyzerError.localeNotSupported
    }
  }

  // MARK: - SpeechRecognitionEngine Protocol

  func getState() -> String {
    return state
  }

  func getLocale() -> String? {
    return locale.identifier
  }

  func supports(feature: SpeechRecognitionFeature) -> Bool {
    switch feature {
    case .contextualStrings:
      return false  // SpeechAnalyzer does NOT support contextualStrings
    case .onDeviceRecognition:
      return true  // SpeechAnalyzer is always on-device
    case .automaticLanguageDetection:
      return false  // Not yet implemented
    case .dictationMode:
      return true  // Via DictationTranscriber
    case .punctuation:
      return true  // Via DictationTranscriber
    case .networkRecognition:
      return false  // SpeechAnalyzer is on-device only
    case .maxAlternatives:
      return false  // SpeechAnalyzer returns single best result
    }
  }

  // MARK: - Start Method

  @MainActor func start(
    options: SpeechRecognitionOptions,
    delegate: SpeechRecognitionEngineDelegate
  ) async throws {
    // Store delegate
    await setDelegate(delegate)
    await setOptions(options)

    // Note: engineselected event is emitted by the factory with the correct reason

    // Set up handlers for MainActor callbacks
    self.endHandler = { delegate.onEnd() }
    self.audioEndHandler = { filePath in delegate.onAudioEnd(filePath: filePath) }
    self.volumeChangeHandler = { value in delegate.onVolumeChange(value) }
    self.errorHandler = { error in delegate.onError(error) }

    // Start recognition in a Task
    Task {
      await startRecognition(
        options: options,
        delegate: delegate
      )
    }
  }

  private func setDelegate(_ delegate: SpeechRecognitionEngineDelegate) {
    self.delegate = delegate
  }

  private func setOptions(_ options: SpeechRecognitionOptions) {
    self.options = options
  }

  // MARK: - Core Recognition

  private func startRecognition(
    options: SpeechRecognitionOptions,
    delegate: SpeechRecognitionEngineDelegate
  ) async {
    // Reset state
    await reset(andEmitEnd: false)
    state = "starting"
    hasSpeechStarted = false
    hasSoundStarted = false
    stoppedListening = false

    do {
      // CRITICAL: Reserve locale before using SpeechAnalyzer
      // This is required by Apple's AssetInventory API
      try await reserveLocaleIfNeeded()

      // Create transcriber based on options
      let activeTranscriber = try await createTranscriber(options: options)
      let analyzerModules: [any SpeechModule]

      switch activeTranscriber {
      case .speech(let transcriber):
        speechTranscriber = transcriber
        dictationTranscriber = nil
        analyzerModules = [transcriber]
      case .dictation(let transcriber):
        dictationTranscriber = transcriber
        speechTranscriber = nil
        analyzerModules = [transcriber]
      }

      // Create analyzer with the selected transcriber module
      analyzer = SpeechAnalyzer(modules: analyzerModules)

      guard analyzer != nil else {
        throw AnalyzerError.failedToCreateAnalyzer
      }

      // Get best audio format for the selected transcriber
      analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: analyzerModules)

      guard analyzerFormat != nil else {
        throw AnalyzerError.invalidAudioFormat
      }

      // Initialize buffer converter with thread-safe implementation
      bufferConverter = AudioBufferConverter()

      // Create async stream for audio input
      let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
      self.inputBuilder = continuation

      // Determine audio source
      let isSourcedFromFile = options.audioSource?.uri != nil

      // Start the results consumer task
      switch activeTranscriber {
      case .speech(let transcriber):
        resultsTask = Task {
          await consumeSpeechResults(
            transcriber: transcriber,
            options: options,
            delegate: delegate,
            isSourcedFromFile: isSourcedFromFile
          )
        }
      case .dictation(let transcriber):
        resultsTask = Task {
          await consumeDictationResults(
            transcriber: transcriber,
            options: options,
            delegate: delegate,
            isSourcedFromFile: isSourcedFromFile
          )
        }
      }

      if isSourcedFromFile {
        // File-based recognition
        guard let uri = options.audioSource?.uri, let url = URL(string: uri) else {
          throw AnalyzerError.invalidAudioFormat
        }
        try await prepareFileRecognition(url: url, options: options)
      } else {
        // Microphone-based recognition
        try await prepareMicrophoneRecognition(options: options)
      }

      // Start the analyzer
      try await analyzer?.start(inputSequence: inputSequence)

      state = "recognizing"

      // Emit start event
      delegate.onStart()

      // Emit audiostart event
      delegate.onAudioStart(filePath: outputFileUrl?.absoluteString)

      // Set up detection timer for non-continuous mode (matching legacy behavior)
      if !options.continuous && !isSourcedFromFile {
        await invalidateAndScheduleTimer()
      }

      print("[SpeechAnalyzerEngine] Recognition started successfully")

    } catch {
      print("[SpeechAnalyzerEngine] Failed to start recognition: \(error)")
      state = "inactive"

      // Convert to appropriate error type
      if let analyzerError = error as? AnalyzerError {
        switch analyzerError {
        case .localeNotSupported:
          delegate.onError(
            SpeechRecognitionEngineError.localeNotSupported(locale: locale.identifier)
          )
        case .assetNotInstalled:
          delegate.onError(
            SpeechRecognitionEngineError.assetNotInstalled(locale: locale.identifier))
        case .localeReservationFailed:
          delegate.onError(
            SpeechRecognitionEngineError.assetNotInstalled(locale: locale.identifier))
        default:
          delegate.onError(SpeechRecognitionEngineError.analyzerUnavailable)
        }
      } else {
        delegate.onError(error)
      }

      await reset(andEmitEnd: true)
    }
  }

  // MARK: - Locale Reservation (CRITICAL for SpeechAnalyzer)

  /// Reserve the locale for use with SpeechAnalyzer
  /// This is REQUIRED by Apple's AssetInventory API before using any transcriber
  private func reserveLocaleIfNeeded() async throws {
    let reservedLocales = await AssetInventory.reservedLocales

    // Check if already reserved
    let isAlreadyReserved = reservedLocales.contains { reserved in
      Self.localesMatch(reserved, locale)
    }

    if isAlreadyReserved {
      print("[SpeechAnalyzerEngine] Locale \(locale.identifier) already reserved")
      localeReserved = true
      return
    }

    // Reserve the locale
    do {
      try await AssetInventory.reserve(locale: locale)
      localeReserved = true
      print("[SpeechAnalyzerEngine] Reserved locale: \(locale.identifier)")
    } catch {
      print("[SpeechAnalyzerEngine] Failed to reserve locale \(locale.identifier): \(error)")
      throw AnalyzerError.localeReservationFailed
    }
  }

  /// Release the reserved locale on cleanup
  private func releaseLocaleIfNeeded() async {
    guard localeReserved else { return }

    // Note: We don't release immediately as other sessions might need it
    // The system manages locale slots; releasing too aggressively can cause issues
    // For now, we keep the locale reserved for future use
    print("[SpeechAnalyzerEngine] Keeping locale \(locale.identifier) reserved for future use")
  }

  // MARK: - Transcriber Creation

  private func createTranscriber(options: SpeechRecognitionOptions) async throws
    -> ActiveTranscriber
  {
    // Determine if we should use dictation mode
    // DictationTranscriber is preferred for explicit dictation requests and punctuation-heavy flows.
    let useDictation =
      options.iosTranscriberType == .dictation
      || options.addsPunctuation

    if useDictation {
      let supportedLocales = await DictationTranscriber.supportedLocales
      let isSupported = supportedLocales.contains { supported in
        Self.localesMatch(supported, locale)
      }

      guard isSupported else {
        throw AnalyzerError.localeNotSupported
      }

      print("[SpeechAnalyzerEngine] Using DictationTranscriber for locale: \(locale.identifier)")

      var transcriptionOptions: Set<DictationTranscriber.TranscriptionOption> = []
      if options.addsPunctuation || options.iosTranscriberType == .dictation {
        transcriptionOptions.insert(.punctuation)
      }

      let reportingOptions: Set<DictationTranscriber.ReportingOption> =
        options.interimResults ? [.volatileResults] : []

      let transcriber = DictationTranscriber(
        locale: locale,
        contentHints: [],
        transcriptionOptions: transcriptionOptions,
        reportingOptions: reportingOptions,
        attributeOptions: [.audioTimeRange]
      )
      return .dictation(transcriber)
    } else {
      print("[SpeechAnalyzerEngine] Using SpeechTranscriber for locale: \(locale.identifier)")

      let reportingOptions: Set<SpeechTranscriber.ReportingOption> =
        options.interimResults ? [.volatileResults] : []

      let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: reportingOptions,
        attributeOptions: [.audioTimeRange]
      )
      return .speech(transcriber)
    }
  }

  // MARK: - Results Consumer

  private func consumeSpeechResults(
    transcriber: SpeechTranscriber,
    options: SpeechRecognitionOptions,
    delegate: SpeechRecognitionEngineDelegate,
    isSourcedFromFile: Bool
  ) async {
    print("[SpeechAnalyzerEngine] Starting SpeechTranscriber results consumer...")

    var streamEndedNaturally = false

    do {
      for try await result in transcriber.results {
        // Check if we've been stopped
        if stoppedListening {
          break
        }

        // Emit soundstart on first result (matching legacy behavior)
        if !hasSoundStarted {
          hasSoundStarted = true
          delegate.onSoundStart()
        }

        // Convert AttributedString to plain text
        let text = String(result.text.characters)
        let isFinal = result.isFinal

        // Emit speechstart on first non-empty result
        if !hasSpeechStarted && !text.isEmpty {
          hasSpeechStarted = true
          delegate.onSpeechStart()
        }

        print(
          "[SpeechAnalyzerEngine] Result: isFinal=\(isFinal), text=\"\(text.prefix(50))\(text.count > 50 ? "..." : "")\""
        )

        // Reschedule timer on each result (matching legacy behavior for non-continuous)
        if !options.continuous && !isSourcedFromFile {
          await invalidateAndScheduleTimer()
        }

        // Emit result via the unified format
        // Note: SpeechAnalyzer always produces punctuated text. If addsPunctuation is false,
        // we post-process to strip punctuation to match the expected behavior.
        await emitResult(
          attributedText: result.text,
          alternatives: result.alternatives,
          isFinal: isFinal,
          delegate: delegate,
          stripPunctuation: !options.addsPunctuation
        )

        // If final and not continuous, we're done
        if isFinal && !options.continuous {
          break
        }
      }

      streamEndedNaturally = !stoppedListening
      print("[SpeechAnalyzerEngine] Results stream ended normally")

    } catch is CancellationError {
      streamEndedNaturally = false
    } catch {
      if !stoppedListening {
        print("[SpeechAnalyzerEngine] Results stream error: \(error)")
        delegate.onError(SpeechRecognitionEngineError.analysisInterrupted)
      }
    }

    await finalizeResultsConsumption(
      streamEndedNaturally: streamEndedNaturally,
      delegate: delegate
    )
  }

  private func consumeDictationResults(
    transcriber: DictationTranscriber,
    options: SpeechRecognitionOptions,
    delegate: SpeechRecognitionEngineDelegate,
    isSourcedFromFile: Bool
  ) async {
    print("[SpeechAnalyzerEngine] Starting DictationTranscriber results consumer...")

    var streamEndedNaturally = false

    do {
      for try await result in transcriber.results {
        // Check if we've been stopped
        if stoppedListening {
          break
        }

        // Emit soundstart on first result (matching legacy behavior)
        if !hasSoundStarted {
          hasSoundStarted = true
          delegate.onSoundStart()
        }

        // Convert AttributedString to plain text
        let text = String(result.text.characters)
        let isFinal = result.isFinal

        // Emit speechstart on first non-empty result
        if !hasSpeechStarted && !text.isEmpty {
          hasSpeechStarted = true
          delegate.onSpeechStart()
        }

        print(
          "[SpeechAnalyzerEngine] Result: isFinal=\(isFinal), text=\"\(text.prefix(50))\(text.count > 50 ? "..." : "")\""
        )

        // Reschedule timer on each result (matching legacy behavior for non-continuous)
        if !options.continuous && !isSourcedFromFile {
          await invalidateAndScheduleTimer()
        }

        await emitResult(
          attributedText: result.text,
          alternatives: result.alternatives,
          isFinal: isFinal,
          delegate: delegate,
          stripPunctuation: !options.addsPunctuation
        )

        // If final and not continuous, we're done
        if isFinal && !options.continuous {
          break
        }
      }

      streamEndedNaturally = !stoppedListening
      print("[SpeechAnalyzerEngine] Results stream ended normally")

    } catch is CancellationError {
      streamEndedNaturally = false
    } catch {
      if !stoppedListening {
        print("[SpeechAnalyzerEngine] Results stream error: \(error)")
        delegate.onError(SpeechRecognitionEngineError.analysisInterrupted)
      }
    }

    await finalizeResultsConsumption(
      streamEndedNaturally: streamEndedNaturally,
      delegate: delegate
    )
  }

  private func finalizeResultsConsumption(
    streamEndedNaturally: Bool,
    delegate: SpeechRecognitionEngineDelegate
  ) async {
    // Emit speechend and soundend if we had started (matching legacy behavior)
    if hasSpeechStarted {
      delegate.onSpeechEnd()
    }
    if hasSoundStarted {
      delegate.onSoundEnd()
    }

    if streamEndedNaturally {
      Task { [weak self] in
        guard let self = self else { return }
        let currentState = await self.state
        if currentState == "starting" || currentState == "recognizing" {
          await self.performStop()
        }
      }
    }
  }

  /// Emit a result using the unified result format
  private func emitResult(
    attributedText: AttributedString,
    alternatives: [AttributedString],
    isFinal: Bool,
    delegate: SpeechRecognitionEngineDelegate,
    stripPunctuation: Bool = false
  ) async {
    // Extract segments from AttributedString runs if available
    var segments: [UnifiedSegment] = []

    // Try to extract timing information from attributed string runs
    for run in attributedText.runs {
      if let timeRange = run.audioTimeRange {
        let startMillis = CMTimeGetSeconds(timeRange.start) * 1000
        let endMillis = CMTimeGetSeconds(timeRange.end) * 1000
        var segmentText = String(attributedText[run.range].characters)

        // Strip punctuation from segment if requested
        if stripPunctuation {
          segmentText = Self.removePunctuation(from: segmentText)
        }

        segments.append(UnifiedSegment(
          startTimeMillis: startMillis,
          endTimeMillis: endMillis,
          segment: segmentText,
          confidence: 1.0  // SpeechAnalyzer doesn't provide per-segment confidence
        ))
      }
    }

    // Process the transcript text
    let rawText = String(attributedText.characters)
    var processedText = rawText
    if stripPunctuation {
      processedText = Self.removePunctuation(from: rawText)
    }

    let unifiedAlternatives = alternatives
      .map { alternative in
        var alternativeText = String(alternative.characters)
        if stripPunctuation {
          alternativeText = Self.removePunctuation(from: alternativeText)
        }
        return UnifiedAlternative(
          transcript: alternativeText,
          confidence: 1.0
        )
      }
      .filter { !$0.transcript.isEmpty }

    // Create a unified result
    let unifiedResult = UnifiedTranscriptionResult(
      transcript: processedText,
      confidence: 1.0,  // SpeechAnalyzer doesn't provide confidence scores
      segments: segments,
      isFinal: isFinal,
      alternatives: unifiedAlternatives
    )

    // Emit via the unified result delegate method
    delegate.onUnifiedResult(unifiedResult)
  }

  /// Removes punctuation from text while preserving word spacing
  /// This matches the behavior expected when addsPunctuation is false
  private static func removePunctuation(from text: String) -> String {
    // Define punctuation characters to remove
    // This includes common sentence-ending and mid-sentence punctuation
    let punctuationCharacters = CharacterSet(charactersIn: ".,!?;:\"'()[]{}—–-…")

    // Remove punctuation while preserving spaces
    return text.unicodeScalars
      .filter { !punctuationCharacters.contains($0) }
      .map { Character($0) }
      .reduce(into: "") { result, char in
        result.append(char)
      }
      .trimmingCharacters(in: .whitespaces)
      // Clean up any double spaces that might result from removed punctuation
      .replacingOccurrences(of: "  ", with: " ")
  }

  // MARK: - Audio Setup

  private func prepareMicrophoneRecognition(options: SpeechRecognitionOptions) async throws {
    // Set up audio session
    try Self.setupAudioSession(options.iosCategory)

    // Register for audio session notifications
    await registerAudioSessionObservers()

    // Create audio engine
    audioEngine = AVAudioEngine()

    guard let audioEngine = audioEngine else {
      print("[SpeechAnalyzerEngine] ERROR - Failed to create AVAudioEngine")
      throw AnalyzerError.invalidAudioFormat
    }

    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    // Check if audio input is available (matching legacy check)
    guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
      print("[SpeechAnalyzerEngine] ERROR - Audio input is busy: \(inputFormat)")
      throw SpeechRecognitionEngineError.audioInputBusy
    }

    // Set up mixer node (matching legacy architecture for proper audio chain)
    mixerNode = AVAudioMixerNode()
    audioEngine.attach(mixerNode!)
    audioEngine.connect(inputNode, to: mixerNode!, format: inputFormat)

    // Configure voice processing if enabled (matching legacy option)
    if options.iosVoiceProcessingEnabled == true {
      do {
        try audioEngine.inputNode.setVoiceProcessingEnabled(true)
        try audioEngine.outputNode.setVoiceProcessingEnabled(true)
        print("[SpeechAnalyzerEngine] Voice processing enabled")
      } catch {
        print("[SpeechAnalyzerEngine] WARNING - Failed to set voice processing: \(error)")
      }
    }

    // Set up file recording if requested
    if options.recordingOptions?.persist == true {
      let fileFormat = Self.getFileAudioFormat(options: options, engine: audioEngine)
        ?? analyzerFormat ?? inputFormat
      outputFileUrl = prepareFileWriter(
        outputDirectory: options.recordingOptions?.outputDirectory,
        outputFileName: options.recordingOptions?.outputFileName,
        audioFormat: fileFormat
      )
    }

    // Install tap on mixer node (not directly on input - matching legacy pattern)
    let bufferSize: AVAudioFrameCount = 4096

    // Capture audioFileRef before closure to avoid actor isolation issues
    let capturedAudioFileRef = audioFileRef

    mixerNode!.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
      [weak self] buffer, time in
      guard let self = self else { return }

      // Process buffer for transcription
      Task {
        await self.processAudioBuffer(buffer)
      }

      // Write to file if recording
      if let audioFileRef = capturedAudioFileRef {
        ExtAudioFileWrite(audioFileRef, buffer.frameLength, buffer.audioBufferList)
      }
    }

    // Install separate tap for volume changes (matching legacy pattern)
    if options.volumeChangeEventOptions?.enabled == true {
      let desiredDuration: TimeInterval =
        TimeInterval(options.volumeChangeEventOptions?.intervalMillis ?? 100) / 1000.0
      let volumeBufferSize = AVAudioFrameCount(inputFormat.sampleRate * desiredDuration)

      let volumeMixerNode = AVAudioMixerNode()
      audioEngine.attach(volumeMixerNode)
      audioEngine.connect(mixerNode!, to: volumeMixerNode, format: inputFormat)

      volumeMixerNode.installTap(onBus: 0, bufferSize: volumeBufferSize, format: inputFormat) {
        [weak self] buffer, _ in
        guard let self = self else { return }

        if let power = Self.calculatePower(buffer: buffer) {
          let normalized = Self.normalizeVolume(power)
          Task { @MainActor in
            self.volumeChangeHandler?(normalized)
          }
        }
      }
    }

    audioEngine.prepare()
    try audioEngine.start()

    print("[SpeechAnalyzerEngine] Audio engine started with mixer node architecture")
  }

  private func prepareFileRecognition(url: URL, options: SpeechRecognitionOptions) async throws {
    audioEngine = nil
    mixerNode = nil

    // Determine chunk delay (matching legacy values)
    let chunkDelayMillis = options.audioSource?.chunkDelayMillis ?? 15  // On-device default
    let chunkDelayNs = UInt64(chunkDelayMillis) * 1_000_000

    // Start file streaming task
    fileStreamingTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self = self else { return }

      do {
        let file = try AVAudioFile(forReading: url)
        let bufferCapacity: AVAudioFrameCount = 4096
        let inputBuffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat,
          frameCapacity: bufferCapacity
        )!

        while file.framePosition < file.length {
          // Check if stopped
          let shouldStop = await self.stoppedListening
          if shouldStop { break }

          let framesToRead = min(
            bufferCapacity,
            AVAudioFrameCount(file.length - file.framePosition)
          )
          try file.read(into: inputBuffer, frameCount: framesToRead)

          await self.processAudioBuffer(inputBuffer)

          try await Task.sleep(nanoseconds: chunkDelayNs)
        }

        print("[SpeechAnalyzerEngine] File streaming completed")

        // Signal end of audio
        await self.finishInputStream()

      } catch {
        print("[SpeechAnalyzerEngine] File streaming error: \(error)")
        await self.finishInputStream()
      }
    }
  }

  private func finishInputStream() {
    inputBuilder?.finish()
  }

  // MARK: - Audio Processing

  private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
    guard let analyzerFormat = analyzerFormat,
      let inputBuilder = inputBuilder
    else {
      return
    }

    do {
      // Convert buffer to analyzer format if needed
      let convertedBuffer: AVAudioPCMBuffer

      if Self.formatsMatch(buffer.format, analyzerFormat) {
        convertedBuffer = buffer
      } else {
        guard let converter = bufferConverter else {
          return
        }
        convertedBuffer = try converter.convert(buffer, to: analyzerFormat)
      }

      // Feed to analyzer
      let input = AnalyzerInput(buffer: convertedBuffer)
      inputBuilder.yield(input)

    } catch {
      print("[SpeechAnalyzerEngine] Buffer conversion error: \(error)")
    }
  }

  // MARK: - Stop / Abort

  @MainActor func stop() async {
    print("[SpeechAnalyzerEngine] Stop requested")

    // Invalidate timer
    detectionTimer?.invalidate()
    detectionTimer = nil

    // Perform stop on actor
    await performStop()
  }

  @MainActor func abort() async {
    print("[SpeechAnalyzerEngine] Abort requested")

    // Invalidate timer
    detectionTimer?.invalidate()
    detectionTimer = nil

    // Perform abort on actor
    await performAbort()
  }

  /// Internal stop implementation that runs on the actor
  private func performStop() async {
    // Prevent double entry
    if stoppedListening {
      return
    }
    stoppedListening = true

    // Finish input stream
    inputBuilder?.finish()

    // Cancel file streaming if active
    fileStreamingTask?.cancel()
    fileStreamingTask = nil

    // Finalize analyzer gracefully (attempt to get final result)
    do {
      try await analyzer?.finalizeAndFinishThroughEndOfInput()
    } catch {
      print("[SpeechAnalyzerEngine] Error finalizing analyzer: \(error)")
    }

    // Wait for results task to complete
    _ = await resultsTask?.result

    await reset(andEmitEnd: true)
  }

  /// Internal abort implementation that runs on the actor
  private func performAbort() async {
    // Prevent double entry
    if stoppedListening {
      return
    }
    stoppedListening = true

    // Cancel results task immediately (don't wait for final result)
    resultsTask?.cancel()

    // Cancel file streaming if active
    fileStreamingTask?.cancel()
    fileStreamingTask = nil

    // Finish input stream
    inputBuilder?.finish()

    // Cancel analyzer immediately without finalizing
    await analyzer?.cancelAndFinishNow()

    await reset(andEmitEnd: true)
  }

  // MARK: - Detection Timer (matching legacy non-continuous behavior)

  nonisolated private func invalidateAndScheduleTimer() async {
    await MainActor.run {
      self.detectionTimer?.invalidate()

      // Don't schedule if not recognizing
      Task {
        let currentState = await self.state
        if currentState != "recognizing" && currentState != "starting" {
          return
        }

        self.detectionTimer = Timer.scheduledTimer(
          withTimeInterval: 3.0,  // Match legacy 3-second timeout
          repeats: false
        ) { [weak self] _ in
          Task { [weak self] in
            guard let self = self else { return }
            print("[SpeechAnalyzerEngine] Detection timer fired, stopping recognition")
            await self.performStop()
          }
        }
      }
    }
  }

  // MARK: - Reset

  private func reset(andEmitEnd: Bool) async {
    let wasRunning = state == "recognizing" || state == "starting"
    state = "inactive"

    // Invalidate timer
    await MainActor.run {
      self.detectionTimer?.invalidate()
      self.detectionTimer = nil
    }

    // Stop audio engine
    if let engine = audioEngine {
      if engine.isRunning {
        engine.stop()
      }
      // Remove taps from all attached nodes
      engine.attachedNodes.forEach { $0.removeTap(onBus: 0) }
      engine.inputNode.removeTap(onBus: 0)
      engine.inputNode.reset()
      engine.reset()
    }
    audioEngine = nil
    mixerNode = nil

    // Cancel tasks
    resultsTask?.cancel()
    resultsTask = nil
    fileStreamingTask?.cancel()
    fileStreamingTask = nil

    // Close input stream
    inputBuilder?.finish()
    inputBuilder = nil

    // Clear analyzer
    analyzer = nil
    speechTranscriber = nil
    dictationTranscriber = nil
    bufferConverter = nil

    // Remove observers
    if let observer = audioSessionInterruptionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = audioSessionRouteChangeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    audioSessionInterruptionObserver = nil
    audioSessionRouteChangeObserver = nil

    // Close audio file
    if let audioFileRef = audioFileRef {
      ExtAudioFileDispose(audioFileRef)
    }
    audioFileRef = nil

    // Release locale reservation (optional - we keep it for future use)
    // await releaseLocaleIfNeeded()

    // Emit end events
    if andEmitEnd && wasRunning {
      let filePath = outputFileUrl?.absoluteString
      outputFileUrl = nil

      Task { @MainActor in
        self.audioEndHandler?(filePath)
        self.audioEndHandler = nil
        self.endHandler?()
        self.errorHandler = nil
        self.volumeChangeHandler = nil
      }
    }
  }

  // MARK: - Audio Session

  private static func setupAudioSession(_ options: SetCategoryOptions?) throws {
    let audioSession = AVAudioSession.sharedInstance()

    if let options = options {
      let categoryOptions = options.categoryOptions.reduce(AVAudioSession.CategoryOptions()) {
        result, option in
        result.union(option.avCategoryOption)
      }
      try audioSession.setCategory(
        options.category.avCategory,
        mode: options.mode.avMode,
        options: categoryOptions
      )
    } else {
      // Default: match legacy behavior with measurement mode
      try audioSession.setCategory(
        .playAndRecord,
        mode: .measurement,
        options: [.defaultToSpeaker, .allowBluetoothHFP]
      )
    }

    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private func registerAudioSessionObservers() async {
    // Store observers in local variables first, then assign to actor properties
    let interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      guard let self = self else { return }

      let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))

      if type == .began {
        Task {
          await self.handleInterruption()
        }
      }
    }

    let routeChangeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      Task {
        await self.handleRouteChange()
      }
    }

    // Assign to actor properties
    audioSessionInterruptionObserver = interruptionObserver
    audioSessionRouteChangeObserver = routeChangeObserver
  }

  private func handleInterruption() async {
    if state == "recognizing" || state == "starting" {
      Task { @MainActor in
        self.errorHandler?(SpeechRecognitionEngineError.audioSessionInterrupted)
      }
      await reset(andEmitEnd: true)
    }
  }

  private func handleRouteChange() async {
    if state == "recognizing" {
      // Try to restart audio engine (matching legacy behavior)
      if let engine = audioEngine, !engine.isRunning {
        do {
          try engine.start()
          print("[SpeechAnalyzerEngine] Audio engine restarted after route change")
        } catch {
          print("[SpeechAnalyzerEngine] Failed to restart audio engine: \(error)")
          Task { @MainActor in
            self.errorHandler?(SpeechRecognitionEngineError.audioRouteChanged)
          }
          await reset(andEmitEnd: true)
        }
      }
    }
  }

  // MARK: - File Recording

  private static func getFileAudioFormat(
    options: SpeechRecognitionOptions, engine: AVAudioEngine
  ) -> AVAudioFormat? {
    var commonFormat: AVAudioCommonFormat = .pcmFormatFloat32

    if let outputEncoding = options.recordingOptions?.outputEncoding {
      switch outputEncoding {
      case "pcmFormatFloat32":
        commonFormat = .pcmFormatFloat32
      case "pcmFormatFloat64":
        commonFormat = .pcmFormatFloat64
      case "pcmFormatInt16":
        commonFormat = .pcmFormatInt16
      case "pcmFormatInt32":
        commonFormat = .pcmFormatInt32
      default:
        print("[SpeechAnalyzerEngine] Unsupported encoding: \(outputEncoding). Using default.")
      }
    }

    if let outputSampleRate = options.recordingOptions?.outputSampleRate {
      return AVAudioFormat(
        commonFormat: commonFormat,
        sampleRate: outputSampleRate,
        channels: 1,
        interleaved: false
      )
    }

    return engine.inputNode.outputFormat(forBus: 0)
  }

  private func prepareFileWriter(
    outputDirectory: String?,
    outputFileName: String?,
    audioFormat: AVAudioFormat
  ) -> URL? {
    let baseDir: URL

    if let outputDirectory = outputDirectory {
      if let url = URL(string: outputDirectory), url.isFileURL {
        baseDir = url.hasDirectoryPath ? url : url.appendingPathComponent("")
      } else {
        let expandedPath = (outputDirectory as NSString).expandingTildeInPath
        baseDir = URL(fileURLWithPath: expandedPath, isDirectory: true)
      }
    } else {
      guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first
      else {
        return nil
      }
      baseDir = cacheDir
    }

    do {
      try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    } catch {
      print("[SpeechAnalyzerEngine] Failed to create output directory: \(error)")
      return nil
    }

    let fileName = outputFileName ?? "recording_\(UUID().uuidString).wav"
    let filePath = baseDir.appendingPathComponent(fileName)

    let status = ExtAudioFileCreateWithURL(
      filePath as CFURL,
      kAudioFileWAVEType,
      audioFormat.streamDescription,
      nil,
      AudioFileFlags.eraseFile.rawValue,
      &audioFileRef
    )

    guard status == noErr else {
      print("[SpeechAnalyzerEngine] Failed to create audio file: \(status)")
      audioFileRef = nil
      return nil
    }

    return filePath
  }

  // MARK: - Volume Calculation (matching legacy implementation)

  private static func calculatePower(buffer: AVAudioPCMBuffer) -> Float? {
    let length = vDSP_Length(buffer.frameLength)
    guard length > 0 else { return nil }

    if let floatData = buffer.floatChannelData {
      return calculatePowers(data: floatData[0], strideFrames: buffer.stride, length: length)
    } else if let int16Data = buffer.int16ChannelData {
      // Convert int16 to float (matching legacy)
      var floatChannelData: [Float] = Array(repeating: 0.0, count: Int(buffer.frameLength))
      vDSP_vflt16(int16Data[0], buffer.stride, &floatChannelData, buffer.stride, length)
      var scalar = Float(INT16_MAX)
      vDSP_vsdiv(floatChannelData, buffer.stride, &scalar, &floatChannelData, buffer.stride, length)
      return calculatePowers(data: floatChannelData, strideFrames: buffer.stride, length: length)
    } else if let int32Data = buffer.int32ChannelData {
      // Convert int32 to float (matching legacy)
      var floatChannelData: [Float] = Array(repeating: 0.0, count: Int(buffer.frameLength))
      vDSP_vflt32(int32Data[0], buffer.stride, &floatChannelData, buffer.stride, length)
      var scalar = Float(INT32_MAX)
      vDSP_vsdiv(floatChannelData, buffer.stride, &scalar, &floatChannelData, buffer.stride, length)
      return calculatePowers(data: floatChannelData, strideFrames: buffer.stride, length: length)
    }

    return nil
  }

  private static func calculatePowers(
    data: UnsafePointer<Float>, strideFrames: Int, length: vDSP_Length
  ) -> Float? {
    let kMinLevel: Float = 1e-7  // -160 dB
    var max: Float = 0.0
    vDSP_maxv(data, strideFrames, &max, length)
    if max < kMinLevel { max = kMinLevel }
    return 20.0 * log10(max)
  }

  private static func normalizeVolume(_ power: Float) -> Float {
    let minDb: Float = -60.0
    let maxDb: Float = 0.0
    let normalized = (power - minDb) / (maxDb - minDb)
    let clamped = min(max(normalized, 0.0), 1.0)
    return clamped * 12.0 - 2.0  // Scale to -2 to 10 range (matching legacy)
  }

  // MARK: - Utility Methods

  /// Compare two locales for equality (handling different identifier formats)
  private static func localesMatch(_ a: Locale, _ b: Locale) -> Bool {
    return a.identifier == b.identifier
      || a.identifier(.bcp47) == b.identifier(.bcp47)
  }

  /// Compare two audio formats for equality (more robust than == operator)
  static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
    return a.sampleRate == b.sampleRate
      && a.channelCount == b.channelCount
      && a.commonFormat == b.commonFormat
  }
}

// MARK: - Audio Buffer Converter (Thread-Safe)

@available(iOS 26, *)
private class AudioBufferConverter {
  private var converter: AVAudioConverter?
  private let lock = OSAllocatedUnfairLock(initialState: false)

  func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let inputFormat = buffer.format

    // If formats match, return original buffer
    if SpeechAnalyzerEngine.formatsMatch(inputFormat, format) {
      return buffer
    }

    // Create or update converter
    if converter == nil || converter?.outputFormat != format {
      converter = AVAudioConverter(from: inputFormat, to: format)
      // Sacrifice quality of first samples to avoid timestamp drift (as per swift-scribe)
      converter?.primeMethod = .none
    }

    guard let converter = converter else {
      throw SpeechRecognitionEngineError.invalidAudioSource
    }

    // Calculate output buffer size
    let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let scaledLength = Double(buffer.frameLength) * sampleRateRatio
    let frameCapacity = AVAudioFrameCount(scaledLength.rounded(.up))

    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat,
        frameCapacity: frameCapacity
      )
    else {
      throw SpeechRecognitionEngineError.invalidAudioSource
    }

    // Perform conversion with thread-safe flag (matching swift-scribe pattern)
    var nsError: NSError?

    let status = converter.convert(to: outputBuffer, error: &nsError) {
      [self] _, inputStatusPointer in
      let wasProcessed = lock.withLock { processed in
        let was = processed
        processed = true
        return was
      }
      inputStatusPointer.pointee = wasProcessed ? .noDataNow : .haveData
      return wasProcessed ? nil : buffer
    }

    // Reset lock for next conversion
    lock.withLock { $0 = false }

    if status == .error {
      throw nsError ?? SpeechRecognitionEngineError.invalidAudioSource
    }

    return outputBuffer
  }
}

  // MARK: - Asset Management (Static Methods)

@available(iOS 26, *)
extension SpeechAnalyzerEngine {

  /// Check if assets are installed for a locale
  static func isAssetInstalled(for locale: Locale, useDictation: Bool = false) async -> Bool {
    let installed =
      useDictation
      ? await DictationTranscriber.installedLocales
      : await SpeechTranscriber.installedLocales
    return installed.contains { installed in
      localesMatch(installed, locale)
    }
  }

  /// Check if a locale is supported
  static func isLocaleSupported(_ locale: Locale, useDictation: Bool = false) async -> Bool {
    let supported =
      useDictation
      ? await DictationTranscriber.supportedLocales
      : await SpeechTranscriber.supportedLocales
    return supported.contains { supported in
      localesMatch(supported, locale)
    }
  }

  /// Get all supported locales
  static func getSupportedLocales(useDictation: Bool = false) async -> [Locale] {
    return useDictation
      ? await DictationTranscriber.supportedLocales
      : await SpeechTranscriber.supportedLocales
  }

  /// Get all installed locales
  static func getInstalledLocales(useDictation: Bool = false) async -> [Locale] {
    return useDictation
      ? await DictationTranscriber.installedLocales
      : await SpeechTranscriber.installedLocales
  }

  /// Get all reserved locales
  static func getReservedLocales() async -> [Locale] {
    return await AssetInventory.reservedLocales
  }

  /// Request asset installation for a locale
  static func requestAssetInstallation(for locale: Locale, useDictation: Bool = false) async throws
    -> Progress?
  {
    let module = createAssetModule(locale: locale, useDictation: useDictation)

    if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module])
    {
      // Start download in background
      Task {
        try? await downloader.downloadAndInstall()
      }
      return downloader.progress
    }

    return nil
  }

  /// Reserve a locale for use (must be called before using SpeechAnalyzer with that locale)
  static func reserveLocale(_ locale: Locale) async throws {
    let reserved = await AssetInventory.reservedLocales
    let isAlreadyReserved = reserved.contains { localesMatch($0, locale) }

    if !isAlreadyReserved {
      try await AssetInventory.reserve(locale: locale)
    }
  }

  /// Release a reserved locale
  static func releaseLocale(_ locale: Locale) async {
    await AssetInventory.release(reservedLocale: locale)
  }

  private static func createAssetModule(locale: Locale, useDictation: Bool) -> any SpeechModule {
    if useDictation {
      return DictationTranscriber(
        locale: locale,
        contentHints: [],
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: []
      )
    }

    return SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: []
    )
  }
}
