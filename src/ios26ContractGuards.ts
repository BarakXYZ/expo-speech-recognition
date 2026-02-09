import type {
  EngineSelectionReason,
  ExpoSpeechRecognitionModuleType,
} from "./ExpoSpeechRecognitionModule.types";

type AssertTrue<T extends true> = T;

type DownloadStatus = Awaited<
  ReturnType<ExpoSpeechRecognitionModuleType["downloadSpeechAnalyzerAsset"]>
>["status"];

// Compile-time guards for iOS 26+ API contracts.
const engineReasonIncludesLocaleNotSupported: AssertTrue<
  "locale_not_supported" extends EngineSelectionReason ? true : false
> = true;
const downloadStatusIncludesInstalled: AssertTrue<
  "installed" extends DownloadStatus ? true : false
> = true;
const downloadStatusIncludesAlreadyInstalled: AssertTrue<
  "already_installed" extends DownloadStatus ? true : false
> = true;
const downloadStatusIncludesAlreadyDownloading: AssertTrue<
  "already_downloading" extends DownloadStatus ? true : false
> = true;

export const ios26ContractGuards = {
  engineReasonIncludesLocaleNotSupported,
  downloadStatusIncludesInstalled,
  downloadStatusIncludesAlreadyInstalled,
  downloadStatusIncludesAlreadyDownloading,
} as const;
