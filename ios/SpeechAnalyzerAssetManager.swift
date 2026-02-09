import Foundation
import Speech

/// iOS 26+ SpeechAnalyzer asset management.
/// Provides status checks, download initiation, and locale listing for JS APIs.
@available(iOS 26, *)
actor SpeechAnalyzerAssetManager {
  static let shared = SpeechAnalyzerAssetManager()

  private var activeDownloadProgress: [String: Progress] = [:]

  func getAssetStatus(for locale: Locale, useDictation: Bool = false) async -> SpeechAnalyzerAssetInfo {
    let inventoryStatus = await Self.getInventoryStatus(for: locale, useDictation: useDictation)
    var status = Self.mapInventoryStatus(inventoryStatus)
    let progressKey = Self.progressKey(for: locale.identifier, useDictation: useDictation)

    if status == .installing, let progress = activeDownloadProgress[progressKey] {
      // Keep status/install progress in sync with locally-triggered requests.
      if progress.isFinished {
        activeDownloadProgress[progressKey] = nil
        let refreshedStatus = await Self.getInventoryStatus(for: locale, useDictation: useDictation)
        status = Self.mapInventoryStatus(refreshedStatus)
      } else {
        return SpeechAnalyzerAssetInfo(
          locale: locale.identifier,
          status: .installing,
          progress: progress.fractionCompleted
        )
      }
    } else if status != .installing {
      activeDownloadProgress[progressKey] = nil
    }

    return SpeechAnalyzerAssetInfo(
      locale: locale.identifier,
      status: status,
      progress: nil
    )
  }

  func downloadAsset(for locale: Locale, useDictation: Bool = false) async throws {
    let statusInfo = await getAssetStatus(for: locale, useDictation: useDictation)

    switch statusInfo.status {
    case .installed:
      return
    case .notAvailable:
      throw SpeechRecognitionEngineError.localeNotSupported(locale: locale.identifier)
    case .installing:
      return
    case .notInstalled, .unknown:
      let module = Self.createAssetModule(locale: locale, useDictation: useDictation)

      guard
        let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
      else {
        return
      }

      let progressKey = Self.progressKey(for: locale.identifier, useDictation: useDictation)
      activeDownloadProgress[progressKey] = request.progress

      Task.detached(priority: .utility) {
        do {
          try await request.downloadAndInstall()
        } catch {
          // Keep cleanup best-effort and let callers inspect status/errors independently.
        }
        await SpeechAnalyzerAssetManager.shared.clearProgress(for: progressKey)
      }
    }
  }

  func getAllLocalesStatus(useDictation: Bool = false) async -> [SpeechAnalyzerAssetInfo] {
    let supportedLocales: [Locale]
    if useDictation {
      supportedLocales = await DictationTranscriber.supportedLocales
    } else {
      supportedLocales = await SpeechTranscriber.supportedLocales
    }

    var results: [SpeechAnalyzerAssetInfo] = []
    results.reserveCapacity(supportedLocales.count)

    for locale in supportedLocales.sorted(by: { $0.identifier < $1.identifier }) {
      let status = await getAssetStatus(for: locale, useDictation: useDictation)
      results.append(status)
    }

    return results
  }

  private func clearProgress(for localeIdentifier: String) {
    activeDownloadProgress[localeIdentifier] = nil
  }

  private static func getInventoryStatus(for locale: Locale, useDictation: Bool) async -> AssetInventory.Status {
    let module = createAssetModule(locale: locale, useDictation: useDictation)
    return await AssetInventory.status(forModules: [module])
  }

  private static func createAssetModule(locale: Locale, useDictation: Bool) -> any SpeechModule {
    if useDictation {
      return DictationTranscriber(
        locale: locale,
        contentHints: [],
        transcriptionOptions: [.punctuation],
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

  private static func progressKey(for localeIdentifier: String, useDictation: Bool) -> String {
    let transcriber = useDictation ? "dictation" : "speech"
    return "\(localeIdentifier)#\(transcriber)"
  }

  private static func mapInventoryStatus(_ status: AssetInventory.Status) -> SpeechAnalyzerAssetStatus {
    switch status {
    case .installed:
      return .installed
    case .downloading:
      return .installing
    case .supported:
      return .notInstalled
    case .unsupported:
      return .notAvailable
    @unknown default:
      return .unknown
    }
  }
}
