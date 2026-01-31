import Foundation
import Speech

/// Factory for creating speech recognition engines
/// Selects the appropriate engine based on iOS version, options, and asset availability
class SpeechRecognitionEngineFactory {

  /// Creates the appropriate speech recognition engine based on options and platform capabilities
  /// - Parameters:
  ///   - locale: The locale to use for recognition
  ///   - options: Recognition options that may influence engine selection
  ///   - delegate: Delegate to receive engine selection and asset events
  /// - Returns: A speech recognition engine instance
  static func createEngine(
    locale: Locale,
    options: SpeechRecognitionOptions,
    delegate: SpeechRecognitionEngineDelegate? = nil
  ) async throws -> any SpeechRecognitionEngine {

    // iOS 26+ SpeechAnalyzer logic
    if #available(iOS 26, *) {
      // Check if user explicitly wants legacy engine
      if options.iosForceLegacyEngine {
        print("[EngineFactory] Using legacy engine: iosForceLegacyEngine=true")
        delegate?.onEngineSelected(
          EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .forceLegacy))
        return try await LegacySpeechRecognizer(locale: locale)
      }

      // Check if contextualStrings is provided (requires legacy engine)
      if let contextualStrings = options.contextualStrings, !contextualStrings.isEmpty {
        print(
          "[EngineFactory] Using legacy engine: contextualStrings not supported by SpeechAnalyzer")
        delegate?.onEngineSelected(
          EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .contextualStrings))
        return try await LegacySpeechRecognizer(locale: locale)
      }

      // Check if locale is supported by SpeechAnalyzer
      let isSupported = await SpeechAnalyzerEngine.isLocaleSupported(locale)
      if !isSupported {
        print(
          "[EngineFactory] Using legacy engine: locale \(locale.identifier) not supported by SpeechAnalyzer"
        )
        delegate?.onEngineSelected(
          EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .iosVersion))
        return try await LegacySpeechRecognizer(locale: locale)
      }

      // Check asset installation status
      let isInstalled = await SpeechAnalyzerEngine.isAssetInstalled(for: locale)

      if isInstalled {
        // Assets installed - use SpeechAnalyzer
        print("[EngineFactory] Using SpeechAnalyzer: assets installed for \(locale.identifier)")
        return try await SpeechAnalyzerEngine(locale: locale)
      }

      // Assets not installed - handle based on policy
      let policy = options.iosSpeechAnalyzerAssetPolicy ?? .auto

      switch policy {
      case .require:
        // Emit error and don't fallback
        print("[EngineFactory] Asset policy 'require': emitting error")
        delegate?.onAssetRequired(
          locale: locale.identifier,
          status: .notInstalled,
          progress: nil
        )
        throw SpeechRecognitionEngineError.assetNotInstalled(locale: locale.identifier)

      case .download:
        // Trigger download and fallback to legacy
        print("[EngineFactory] Asset policy 'download': triggering download, using legacy engine")
        delegate?.onAssetRequired(
          locale: locale.identifier,
          status: .installing,
          progress: nil
        )

        // Start asset download in background
        Task {
          do {
            let progress = try await SpeechAnalyzerEngine.requestAssetInstallation(for: locale)
            if let progress = progress {
              // Could emit progress updates here
              print("[EngineFactory] Asset download started, progress: \(progress.fractionCompleted)"
              )
            }
          } catch {
            print("[EngineFactory] Asset download failed: \(error)")
          }
        }

        // Fallback to legacy engine
        delegate?.onEngineSelected(
          EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .assetNotInstalled))
        return try await LegacySpeechRecognizer(locale: locale)

      case .auto:
        // Silently fallback to legacy
        print("[EngineFactory] Asset policy 'auto': falling back to legacy engine")
        delegate?.onAssetRequired(
          locale: locale.identifier,
          status: .notInstalled,
          progress: nil
        )
        delegate?.onEngineSelected(
          EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .assetNotInstalled))
        return try await LegacySpeechRecognizer(locale: locale)
      }
    }

    // iOS < 26: Always use legacy engine
    print("[EngineFactory] iOS < 26: using legacy engine")
    delegate?.onEngineSelected(
      EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .iosVersion))
    return try await LegacySpeechRecognizer(locale: locale)
  }

  /// Determines which engine would be selected without creating it
  /// Useful for informing the user before starting recognition
  /// - Parameters:
  ///   - locale: The locale to check (as string identifier)
  ///   - options: Recognition options
  /// - Returns: Information about which engine would be selected and why
  static func getPreferredEngine(
    locale: String?,
    options: SpeechRecognitionOptions? = nil
  ) -> EngineSelectionInfo {

    // iOS 26+ logic
    if #available(iOS 26, *) {
      // Check iosForceLegacyEngine
      if options?.iosForceLegacyEngine == true {
        return EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .forceLegacy)
      }

      // Check contextualStrings
      if let contextualStrings = options?.contextualStrings, !contextualStrings.isEmpty {
        return EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .contextualStrings)
      }

      // For synchronous check, assume SpeechAnalyzer would be used if assets are installed
      // Actual asset check requires async
      return EngineSelectionInfo(engine: .speechAnalyzer, reason: .assetInstalled)
    }

    // iOS < 26
    return EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .iosVersion)
  }

  /// Async version that actually checks asset status
  @available(iOS 26, *)
  static func getPreferredEngineAsync(
    locale: Locale,
    options: SpeechRecognitionOptions? = nil
  ) async -> EngineSelectionInfo {

    // Check iosForceLegacyEngine
    if options?.iosForceLegacyEngine == true {
      return EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .forceLegacy)
    }

    // Check contextualStrings
    if let contextualStrings = options?.contextualStrings, !contextualStrings.isEmpty {
      return EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .contextualStrings)
    }

    // Check locale support
    let isSupported = await SpeechAnalyzerEngine.isLocaleSupported(locale)
    if !isSupported {
      return EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .iosVersion)
    }

    // Check asset installation
    let isInstalled = await SpeechAnalyzerEngine.isAssetInstalled(for: locale)
    if isInstalled {
      return EngineSelectionInfo(engine: .speechAnalyzer, reason: .assetInstalled)
    } else {
      return EngineSelectionInfo(engine: .sfSpeechRecognizer, reason: .assetNotInstalled)
    }
  }
}
