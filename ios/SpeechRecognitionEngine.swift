import AVFoundation
import Foundation
import Speech

// MARK: - Unified Result Types

/// Unified transcription result that both engines produce
struct UnifiedTranscriptionResult {
  let transcript: String
  let confidence: Float
  let segments: [UnifiedSegment]
  let isFinal: Bool
  let alternatives: [UnifiedAlternative]
}

struct UnifiedSegment {
  let startTimeMillis: Double
  let endTimeMillis: Double
  let segment: String
  let confidence: Float
}

struct UnifiedAlternative {
  let transcript: String
  let confidence: Float
}

// MARK: - Unified Error Types

enum SpeechRecognitionEngineError: Error {
  // Legacy errors (from SFSpeechRecognizer)
  case nilRecognizer
  case notAuthorizedToRecognize
  case notPermittedToRecord
  case recognizerIsUnavailable
  case invalidAudioSource
  case audioInputBusy
  case audioSessionInterrupted
  case audioRouteChanged

  // New errors (for SpeechAnalyzer iOS 26+)
  case assetNotInstalled(locale: String)
  case assetDownloadFailed(locale: String)
  case analyzerUnavailable
  case analysisInterrupted
  case localeNotSupported(locale: String)

  /// Maps to JavaScript error code
  var code: String {
    switch self {
    case .nilRecognizer:
      return "language-not-supported"
    case .notAuthorizedToRecognize, .notPermittedToRecord:
      return "not-allowed"
    case .recognizerIsUnavailable, .analyzerUnavailable:
      return "service-not-allowed"
    case .invalidAudioSource, .audioInputBusy, .audioRouteChanged:
      return "audio-capture"
    case .audioSessionInterrupted, .analysisInterrupted:
      return "interrupted"
    case .assetNotInstalled:
      return "asset-not-installed"
    case .assetDownloadFailed:
      return "asset-download-failed"
    case .localeNotSupported:
      return "language-not-supported"
    }
  }

  var message: String {
    switch self {
    case .nilRecognizer:
      return "Can't initialize speech recognizer. Ensure the locale is supported by the device."
    case .notAuthorizedToRecognize:
      return "Not authorized to recognize speech"
    case .notPermittedToRecord:
      return "Not permitted to record audio"
    case .recognizerIsUnavailable:
      return "Recognizer is unavailable"
    case .invalidAudioSource:
      return "Invalid audio source"
    case .audioInputBusy:
      return "The audio input is busy"
    case .audioSessionInterrupted:
      return "Audio session was interrupted"
    case .audioRouteChanged:
      return "Audio route changed and failed to restart the audio engine"
    case .assetNotInstalled(let locale):
      return
        "Speech recognition assets for '\(locale)' are not installed. Call downloadSpeechAnalyzerAsset() first."
    case .assetDownloadFailed(let locale):
      return "Failed to download speech recognition assets for '\(locale)'"
    case .analyzerUnavailable:
      return "SpeechAnalyzer is unavailable"
    case .analysisInterrupted:
      return "Speech analysis was interrupted"
    case .localeNotSupported(let locale):
      return "Locale '\(locale)' is not supported for speech recognition"
    }
  }
}

// MARK: - Engine Selection Info

enum SpeechRecognitionEngineType: String {
  case speechAnalyzer = "SpeechAnalyzer"
  case sfSpeechRecognizer = "SFSpeechRecognizer"
}

enum EngineSelectionReason: String {
  case iosVersion = "ios_version"
  case assetInstalled = "asset_installed"
  case assetNotInstalled = "asset_not_installed"
  case localeNotSupported = "locale_not_supported"
  case forceLegacy = "force_legacy"
  case contextualStrings = "contextual_strings"
  case android = "android"
}

struct EngineSelectionInfo {
  let engine: SpeechRecognitionEngineType
  let reason: EngineSelectionReason
}

// MARK: - Asset Status

enum SpeechAnalyzerAssetStatus: String {
  case installed = "installed"
  case notInstalled = "not_installed"
  case installing = "installing"
  case notAvailable = "not_available"
  case unknown = "unknown"
}

struct SpeechAnalyzerAssetInfo {
  let locale: String
  let status: SpeechAnalyzerAssetStatus
  let progress: Double?
}

// MARK: - Delegate Protocol

/// Callbacks for speech recognition events
/// Note: For legacy engine, result/error types match SFSpeechRecognizer directly for full compatibility
protocol SpeechRecognitionEngineDelegate: AnyObject {
  /// Called when legacy engine (SFSpeechRecognizer) produces a result
  func onResult(_ result: SFSpeechRecognitionResult)

  /// Called when SpeechAnalyzer (iOS 26+) produces a result
  /// This provides a unified format since SFSpeechRecognitionResult can't be created directly
  func onUnifiedResult(_ result: UnifiedTranscriptionResult)

  func onError(_ error: Error)
  func onStart()
  func onSpeechStart()
  func onSpeechEnd()
  func onSoundStart()
  func onSoundEnd()
  func onAudioStart(filePath: String?)
  func onAudioEnd(filePath: String?)
  func onEnd()
  func onVolumeChange(_ value: Float)
  func onEngineSelected(_ info: EngineSelectionInfo)
  func onAssetRequired(locale: String, status: SpeechAnalyzerAssetStatus, progress: Double?)
}

// MARK: - Feature Support

/// Features that may differ between engines
enum SpeechRecognitionFeature {
  case contextualStrings
  case onDeviceRecognition
  case automaticLanguageDetection
  case dictationMode
  case punctuation
  case networkRecognition
  case maxAlternatives
}

// MARK: - Engine Protocol

/// The main protocol that both speech recognition engines implement
protocol SpeechRecognitionEngine: Actor {
  /// Get current recognition state
  func getState() -> String

  /// Get current locale
  func getLocale() -> String?

  /// Check if engine supports the given feature
  func supports(feature: SpeechRecognitionFeature) -> Bool

  /// Start recognition with the given options
  /// Note: This method runs on MainActor because audio session setup requires main thread
  @MainActor func start(
    options: SpeechRecognitionOptions,
    delegate: SpeechRecognitionEngineDelegate
  ) async throws

  /// Stop recognition gracefully (attempt to return final result)
  func stop() async

  /// Abort recognition immediately
  func abort() async
}
