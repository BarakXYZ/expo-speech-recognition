import { useCallback, useEffect, useMemo, useState } from "react";
import { Platform, StyleSheet, Text, View } from "react-native";
import {
  ExpoSpeechRecognitionModule,
  useSpeechRecognitionEvent,
} from "expo-speech-recognition";
import type {
  PreferredEngineSelectionInfo,
  SpeechAnalyzerAssetQueryOptions,
  SpeechAnalyzerAssetStatus,
} from "expo-speech-recognition";

import { SmallButton } from "./ui/Buttons";
import { Card } from "./ui/Card";

type SpeechAnalyzerStatusProps = {
  locale: string;
  iosTranscriberType?: "speech" | "dictation";
  iosForceLegacyEngine?: boolean;
  iosSpeechAnalyzerAssetPolicy?: "auto" | "require" | "download";
  addsPunctuation?: boolean;
  useContextualStrings: boolean;
  contextualStrings: string[];
};

export function SpeechAnalyzerStatus(props: SpeechAnalyzerStatusProps) {
  const {
    locale,
    iosTranscriberType,
    iosForceLegacyEngine,
    iosSpeechAnalyzerAssetPolicy,
    addsPunctuation,
    useContextualStrings,
    contextualStrings,
  } = props;

  const normalizedLocale = locale.replaceAll("_", "-");

  const assetQueryOptions = useMemo<SpeechAnalyzerAssetQueryOptions>(
    () => ({
      iosTranscriberType,
      addsPunctuation,
    }),
    [addsPunctuation, iosTranscriberType],
  );

  const [assetStatus, setAssetStatus] = useState<SpeechAnalyzerAssetStatus | null>(
    null,
  );
  const [preferredEngine, setPreferredEngine] =
    useState<PreferredEngineSelectionInfo | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [isDownloading, setIsDownloading] = useState(false);
  const [lastError, setLastError] = useState<string | null>(null);

  const refreshStatus = useCallback(async () => {
    if (Platform.OS !== "ios") {
      return;
    }

    setIsRefreshing(true);
    setLastError(null);

    try {
      const [nextAssetStatus, nextPreferredEngine] = await Promise.all([
        ExpoSpeechRecognitionModule.getSpeechAnalyzerAssetStatus(
          normalizedLocale,
          assetQueryOptions,
        ),
        ExpoSpeechRecognitionModule.getPreferredEngine({
          locale: normalizedLocale,
          iosForceLegacyEngine,
          iosSpeechAnalyzerAssetPolicy,
          iosTranscriberType,
          addsPunctuation,
          contextualStrings: useContextualStrings ? contextualStrings : undefined,
        }),
      ]);

      setAssetStatus(nextAssetStatus);
      setPreferredEngine(nextPreferredEngine);
    } catch (error) {
      setLastError(
        error instanceof Error ? error.message : "Failed to refresh analyzer status.",
      );
    } finally {
      setIsRefreshing(false);
    }
  }, [
    addsPunctuation,
    assetQueryOptions,
    contextualStrings,
    iosForceLegacyEngine,
    iosSpeechAnalyzerAssetPolicy,
    iosTranscriberType,
    normalizedLocale,
    useContextualStrings,
  ]);

  const downloadAssets = useCallback(async () => {
    if (Platform.OS !== "ios") {
      return;
    }

    setIsDownloading(true);
    setLastError(null);

    try {
      await ExpoSpeechRecognitionModule.downloadSpeechAnalyzerAsset(
        normalizedLocale,
        assetQueryOptions,
      );
      await refreshStatus();
    } catch (error) {
      setLastError(
        error instanceof Error ? error.message : "Failed to start asset download.",
      );
    } finally {
      setIsDownloading(false);
    }
  }, [assetQueryOptions, normalizedLocale, refreshStatus]);

  useSpeechRecognitionEvent("assetrequired", (event) => {
    if (event.locale.replaceAll("_", "-") !== normalizedLocale) {
      return;
    }

    setAssetStatus({
      locale: normalizedLocale,
      status: event.status,
      progress: event.progress,
    });
  });

  useEffect(() => {
    void refreshStatus();
  }, [refreshStatus]);

  if (Platform.OS !== "ios") {
    return null;
  }

  const transcriberLabel =
    iosTranscriberType ??
    (addsPunctuation ? "dictation (via addsPunctuation)" : "speech");
  const assetStatusLabel = assetStatus?.status ?? "unknown";
  const downloadProgress =
    assetStatus?.progress != null
      ? `${Math.round(assetStatus.progress * 100)}%`
      : "n/a";

  return (
    <Card style={styles.card}>
      <View style={[styles.row, styles.spaceBetween]}>
        <Text style={styles.title}>iOS 26 SpeechAnalyzer</Text>
        <View style={[styles.row, styles.gap]}>
          <SmallButton
            title={isRefreshing ? "Refreshing..." : "Refresh"}
            onPress={() => void refreshStatus()}
            disabled={isRefreshing || isDownloading}
          />
          <SmallButton
            title={isDownloading ? "Downloading..." : "Download"}
            onPress={() => void downloadAssets()}
            disabled={isDownloading || isRefreshing || assetStatusLabel === "installed"}
          />
        </View>
      </View>

      <Text style={styles.text}>Locale: {normalizedLocale}</Text>
      <Text style={styles.text}>Transcriber: {transcriberLabel}</Text>
      <Text style={styles.text}>
        Preferred engine:{" "}
        {preferredEngine
          ? `${preferredEngine.engine} (${preferredEngine.reason})`
          : "loading..."}
      </Text>
      <Text style={styles.text}>
        Asset status: {assetStatusLabel} (progress: {downloadProgress})
      </Text>
      {lastError ? <Text style={styles.error}>Last error: {lastError}</Text> : null}
    </Card>
  );
}

const styles = StyleSheet.create({
  card: {
    gap: 4,
  },
  title: {
    fontWeight: "700",
    fontSize: 12,
  },
  text: {
    fontFamily: Platform.OS === "ios" ? "Courier" : "monospace",
    fontSize: 11,
  },
  error: {
    color: "#b00020",
    fontSize: 11,
    fontFamily: Platform.OS === "ios" ? "Courier" : "monospace",
  },
  row: {
    flexDirection: "row",
    alignItems: "center",
  },
  gap: {
    gap: 4,
  },
  spaceBetween: {
    justifyContent: "space-between",
  },
});
