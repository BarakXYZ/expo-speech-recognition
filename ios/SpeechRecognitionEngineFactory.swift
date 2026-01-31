import Foundation
import Speech

/// Factory for creating speech recognition engines
/// Selects the appropriate engine based on iOS version, options, and asset availability
class SpeechRecognitionEngineFactory {

  /// Creates the appropriate speech recognition engine based on options and platform capabilities
  /// - Parameters:
  ///   - locale: The locale to use for recognition
  ///   - options: Recognition options that may influence engine selection
  /// - Returns: A speech recognition engine instance
  static func createEngine(
    locale: Locale,
    options: SpeechRecognitionOptions
  ) async throws -> any SpeechRecognitionEngine {
    // Phase 2: Always return LegacySpeechRecognizer
    // Phase 3+ will add SpeechAnalyzer selection logic for iOS 26+

    // Future iOS 26+ logic will go here:
    // if #available(iOS 26, *) {
    //   // Check iosForceLegacyEngine
    //   // Check contextualStrings (requires legacy)
    //   // Check asset availability
    //   // Return SpeechAnalyzerEngine or LegacySpeechRecognizer
    // }

    return try await LegacySpeechRecognizer(locale: locale)
  }

  /// Determines which engine would be selected without creating it
  /// Useful for informing the user before starting recognition
  /// - Parameters:
  ///   - locale: The locale to check
  ///   - options: Recognition options
  /// - Returns: Information about which engine would be selected and why
  static func getPreferredEngine(
    locale: String?,
    options: SpeechRecognitionOptions? = nil
  ) -> EngineSelectionInfo {
    // Phase 2: Always return SFSpeechRecognizer
    // Phase 3+ will add logic for iOS 26+

    // Future iOS 26+ logic will go here:
    // if #available(iOS 26, *) {
    //   // Check various conditions
    // }

    return EngineSelectionInfo(
      engine: .sfSpeechRecognizer,
      reason: .iosVersion
    )
  }
}
