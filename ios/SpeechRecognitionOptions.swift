import ExpoModulesCore
import Speech

struct SpeechRecognitionOptions: Record {
  @Field
  var interimResults: Bool = false

  @Field
  var lang: String = "en-US"

  @Field
  var continuous: Bool = false

  @Field
  var maxAlternatives: Int = 5

  @Field
  var contextualStrings: [String]? = nil

  @Field
  var requiresOnDeviceRecognition: Bool = false

  @Field
  var addsPunctuation: Bool = false

  @Field
  var recordingOptions: RecordingOptions? = nil

  @Field
  var audioSource: AudioSourceOptions? = nil

  @Field
  var iosTaskHint: IOSTaskHint? = nil

  @Field
  var iosCategory: SetCategoryOptions? = nil

  @Field
  var volumeChangeEventOptions: VolumeChangeEventOptions? = nil

  @Field
  var iosVoiceProcessingEnabled: Bool? = false

  // MARK: - iOS 26+ SpeechAnalyzer Options

  /// [iOS 26+] Transcriber type for SpeechAnalyzer.
  /// - "speech": Raw words (commands, keywords) - uses SpeechTranscriber
  /// - "dictation": Full dictation with punctuation - uses DictationTranscriber
  /// Default: "speech"
  /// Note: When addsPunctuation=true, automatically uses "dictation"
  @Field
  var iosTranscriberType: IOSTranscriberType? = nil

  /// [iOS 26+] Force use of legacy SFSpeechRecognizer.
  /// Useful when you explicitly need legacy-only behavior.
  /// Default: false
  @Field
  var iosForceLegacyEngine: Bool = false

  /// [iOS 26+] Controls behavior when SpeechAnalyzer assets aren't installed.
  /// - "auto": Silently fallback to SFSpeechRecognizer (default)
  /// - "require": Emit 'asset-not-installed' error, don't fallback
  /// - "download": Auto-trigger download, use SFSpeechRecognizer meanwhile
  /// Default: "auto"
  @Field
  var iosSpeechAnalyzerAssetPolicy: IOSSpeechAnalyzerAssetPolicy? = nil
}

struct VolumeChangeEventOptions: Record {
  @Field
  var enabled: Bool? = false

  @Field
  var intervalMillis: Int? = nil
}

enum IOSTaskHint: String, Enumerable {
  case unspecified
  case dictation
  case search
  case confirmation

  var sfSpeechRecognitionTaskHint: SFSpeechRecognitionTaskHint {
    switch self {
    case .unspecified: return .unspecified
    case .dictation: return .dictation
    case .search: return .search
    case .confirmation: return .confirmation
    }
  }
}

// MARK: - iOS 26+ SpeechAnalyzer Enums

/// Transcriber type for iOS 26+ SpeechAnalyzer
enum IOSTranscriberType: String, Enumerable {
  /// Raw words - uses SpeechTranscriber for commands, keywords, short phrases
  case speech
  /// Full dictation with punctuation - uses DictationTranscriber
  case dictation
}

/// Asset policy for iOS 26+ SpeechAnalyzer
enum IOSSpeechAnalyzerAssetPolicy: String, Enumerable {
  /// Silently fallback to SFSpeechRecognizer if assets not installed (default)
  case auto
  /// Emit 'asset-not-installed' error, don't fallback
  case require
  /// Auto-trigger download, use SFSpeechRecognizer meanwhile
  case download
}

struct RecordingOptions: Record {
  @Field
  var persist: Bool = false

  @Field
  var outputDirectory: String? = nil

  @Field
  var outputFileName: String? = nil

  @Field
  var outputSampleRate: Double? = nil

  @Field
  var outputEncoding: String? = nil
}

struct AudioSourceOptions: Record {
  @Field
  var uri: String = ""

  @Field
  var audioEncoding: Int? = nil

  @Field
  var sampleRate: Int? = 16000

  @Field
  var audioChannels: Int? = 1

  @Field
  var chunkDelayMillis: Int? = nil
}

struct GetSupportedLocaleOptions: Record {
  @Field
  var androidRecognitionServicePackage: String? = nil
}

enum CategoryParam: String, Enumerable {
  case ambient
  case soloAmbient
  case playback
  case record
  case playAndRecord
  case multiRoute

  var avCategory: AVAudioSession.Category {
    switch self {
    case .ambient: return .ambient
    case .soloAmbient: return .soloAmbient
    case .playback: return .playback
    case .record: return .record
    case .playAndRecord: return .playAndRecord
    case .multiRoute: return .multiRoute
    }
  }
}

enum CategoryOptionsParam: String, Enumerable {
  case mixWithOthers
  case duckOthers
  case interruptSpokenAudioAndMixWithOthers
  case allowBluetooth
  case allowBluetoothA2DP
  case allowAirPlay
  case defaultToSpeaker
  case overrideMutedMicrophoneInterruption

  var avCategoryOption: AVAudioSession.CategoryOptions {
    switch self {
    case .mixWithOthers: return .mixWithOthers
    case .duckOthers: return .duckOthers
    case .interruptSpokenAudioAndMixWithOthers: return .interruptSpokenAudioAndMixWithOthers
    case .allowBluetooth: return .allowBluetooth
    case .allowBluetoothA2DP: return .allowBluetoothA2DP
    case .allowAirPlay: return .allowAirPlay
    case .defaultToSpeaker: return .defaultToSpeaker
    case .overrideMutedMicrophoneInterruption:
      if #available(iOS 14.5, *) {
        return .overrideMutedMicrophoneInterruption
      } else {
        return .mixWithOthers
      }
    }
  }
}

enum ModeParam: String, Enumerable {
  case `default`
  case gameChat
  case measurement
  case moviePlayback
  case spokenAudio
  case videoChat
  case videoRecording
  case voiceChat
  case voicePrompt

  var avMode: AVAudioSession.Mode {
    switch self {
    case .default: return .default
    case .gameChat: return .gameChat
    case .measurement: return .measurement
    case .moviePlayback: return .moviePlayback
    case .spokenAudio: return .spokenAudio
    case .videoChat: return .videoChat
    case .videoRecording: return .videoRecording
    case .voiceChat: return .voiceChat
    case .voicePrompt: return .voicePrompt
    }
  }
}

struct SetCategoryOptions: Record {
  @Field
  var category: CategoryParam = .playAndRecord

  @Field
  var categoryOptions: [CategoryOptionsParam] = [.duckOthers]

  @Field
  var mode: ModeParam = .measurement
}

struct SetAudioSessionActiveOptions: Record {
  @Field
  var notifyOthersOnDeactivation: Bool? = true
}
