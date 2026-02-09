import Foundation
import Speech

/// iOS 26+ SpeechAnalyzer asset management.
/// Provides status checks, download initiation, and locale listing for JS APIs.
@available(iOS 26, *)
actor SpeechAnalyzerAssetManager {
  static let shared = SpeechAnalyzerAssetManager()

  private var activeDownloadProgress: [String: Progress] = [:]

  func getAssetStatus(for locale: Locale) async -> SpeechAnalyzerAssetInfo {
    let inventoryStatus = await Self.getInventoryStatus(for: locale)
    var status = Self.mapInventoryStatus(inventoryStatus)

    if status == .installing, let progress = activeDownloadProgress[locale.identifier] {
      // Keep status/install progress in sync with locally-triggered requests.
      if progress.isFinished {
        activeDownloadProgress[locale.identifier] = nil
        let refreshedStatus = await Self.getInventoryStatus(for: locale)
        status = Self.mapInventoryStatus(refreshedStatus)
      } else {
        return SpeechAnalyzerAssetInfo(
          locale: locale.identifier,
          status: .installing,
          progress: progress.fractionCompleted
        )
      }
    } else if status != .installing {
      activeDownloadProgress[locale.identifier] = nil
    }

    return SpeechAnalyzerAssetInfo(
      locale: locale.identifier,
      status: status,
      progress: nil
    )
  }

  func downloadAsset(for locale: Locale) async throws {
    let statusInfo = await getAssetStatus(for: locale)

    switch statusInfo.status {
    case .installed:
      return
    case .notAvailable:
      throw SpeechRecognitionEngineError.localeNotSupported(locale: locale.identifier)
    case .installing:
      return
    case .notInstalled, .unknown:
      let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: []
      )

      guard
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
      else {
        return
      }

      let localeIdentifier = locale.identifier
      activeDownloadProgress[localeIdentifier] = request.progress

      Task.detached(priority: .utility) {
        do {
          try await request.downloadAndInstall()
        } catch {
          // Keep cleanup best-effort and let callers inspect status/errors independently.
        }
        await SpeechAnalyzerAssetManager.shared.clearProgress(for: localeIdentifier)
      }
    }
  }

  func getAllLocalesStatus() async -> [SpeechAnalyzerAssetInfo] {
    let supportedLocales = await SpeechTranscriber.supportedLocales

    var results: [SpeechAnalyzerAssetInfo] = []
    results.reserveCapacity(supportedLocales.count)

    for locale in supportedLocales.sorted(by: { $0.identifier < $1.identifier }) {
      let status = await getAssetStatus(for: locale)
      results.append(status)
    }

    return results
  }

  private func clearProgress(for localeIdentifier: String) {
    activeDownloadProgress[localeIdentifier] = nil
  }

  private static func getInventoryStatus(for locale: Locale) async -> AssetInventory.Status {
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: []
    )
    return await AssetInventory.status(forModules: [transcriber])
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
