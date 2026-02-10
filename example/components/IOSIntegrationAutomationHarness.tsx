import { useAssets } from "expo-asset";
import {
  ExpoSpeechRecognitionModule,
  useSpeechRecognitionEvent,
} from "expo-speech-recognition";
import type {
  EngineSelectionInfo,
  ExpoSpeechRecognitionErrorEvent,
  ExpoSpeechRecognitionOptions,
  ExpoSpeechRecognitionResultEvent,
  PreferredEngineSelectionInfo,
} from "expo-speech-recognition";
import { useCallback, useMemo, useRef, useState } from "react";
import { Platform, StyleSheet, Text, View } from "react-native";
import { BigButton, SmallButton } from "./ui/Buttons";
import { Card } from "./ui/Card";
import { validateResultInvariants } from "./iosAutomationValidation";

type ScenarioStatus = "PASS" | "FAIL" | "SKIP";
type SuiteStatus = "IDLE" | "RUNNING" | "PASS" | "FAIL";

type ScenarioResult = {
  id: string;
  status: ScenarioStatus;
  durationMs: number;
  notes: string[];
};

type PendingCapture = {
  startedAtMs: number;
  timeoutHandle: ReturnType<typeof setTimeout>;
  settled: boolean;
  resolve: (value: RecognitionCapture) => void;
  capture: RecognitionCapture;
};

type RecognitionCapture = {
  startCount: number;
  endCount: number;
  nomatchCount: number;
  timedOut: boolean;
  engines: EngineSelectionInfo[];
  assetRequiredEvents: {
    locale: string;
    status: "not_installed" | "installing";
    progress: number | null;
  }[];
  errors: ExpoSpeechRecognitionErrorEvent[];
  results: ExpoSpeechRecognitionResultEvent[];
  endedAtMs: number;
};

type FixtureKey =
  | "helloWorld"
  | "longSentence"
  | "shortSentence"
  | "technicalTerms";

const FIXTURE_ENTRIES: { key: FixtureKey; moduleId: number; relativePath: string }[] = [
  {
    key: "helloWorld",
    moduleId: require("../assets/test-fixtures/audio/speech/hello-world.wav"),
    relativePath: "speech/hello-world.wav",
  },
  {
    key: "longSentence",
    moduleId: require("../assets/test-fixtures/audio/speech/long-sentence.wav"),
    relativePath: "speech/long-sentence.wav",
  },
  {
    key: "shortSentence",
    moduleId: require("../assets/test-fixtures/audio/speech/short-sentence.wav"),
    relativePath: "speech/short-sentence.wav",
  },
  {
    key: "technicalTerms",
    moduleId: require("../assets/test-fixtures/audio/speech/technical-terms.wav"),
    relativePath: "speech/technical-terms.wav",
  },
];

const automationMarkerPrefix = "IOS_AUTOMATION";

const WAIT_AFTER_ABORT_MS = 150;
const DEFAULT_SCENARIO_TIMEOUT_MS = 35_000;
const ASSET_INSTALL_TIMEOUT_MS = 120_000;

function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function toEngineSelectionOptions(
  options: ExpoSpeechRecognitionOptions,
): Parameters<typeof ExpoSpeechRecognitionModule.getPreferredEngine>[0] {
  return {
    lang: options.lang,
    locale: options.lang,
    iosForceLegacyEngine: options.iosForceLegacyEngine,
    contextualStrings: options.contextualStrings,
    addsPunctuation: options.addsPunctuation,
    iosTranscriberType: options.iosTranscriberType,
    iosSpeechAnalyzerAssetPolicy: options.iosSpeechAnalyzerAssetPolicy,
  };
}

export function IOSIntegrationAutomationHarness() {
  const [assets] = useAssets(FIXTURE_ENTRIES.map((entry) => entry.moduleId));
  const fixtureUris = useMemo(() => {
    const map = new Map<FixtureKey, string>();
    if (!assets || assets.length !== FIXTURE_ENTRIES.length) {
      return map;
    }
    FIXTURE_ENTRIES.forEach((entry, index) => {
      const uri = assets[index]?.localUri;
      if (uri) {
        map.set(entry.key, uri);
      }
    });
    return map;
  }, [assets]);

  const [suiteStatus, setSuiteStatus] = useState<SuiteStatus>("IDLE");
  const [suiteSummary, setSuiteSummary] = useState("NOT_RUN");
  const [scenarioResults, setScenarioResults] = useState<ScenarioResult[]>([]);
  const [logLines, setLogLines] = useState<string[]>([]);
  const [runningScenarioId, setRunningScenarioId] = useState<string | null>(null);

  const pendingCaptureRef = useRef<PendingCapture | null>(null);

  const appendLog = useCallback((line: string) => {
    setLogLines((prev) => [line, ...prev].slice(0, 40));
  }, []);

  const clearPendingCapture = useCallback(() => {
    const pending = pendingCaptureRef.current;
    if (!pending || pending.settled) {
      return;
    }
    pending.settled = true;
    clearTimeout(pending.timeoutHandle);
    pending.capture.endedAtMs = Date.now();
    pending.resolve({ ...pending.capture });
    pendingCaptureRef.current = null;
  }, []);

  useSpeechRecognitionEvent("start", () => {
    const pending = pendingCaptureRef.current;
    if (!pending || pending.settled) {
      return;
    }
    pending.capture.startCount += 1;
  });

  useSpeechRecognitionEvent("engineselected", (event) => {
    const pending = pendingCaptureRef.current;
    if (!pending || pending.settled) {
      return;
    }
    pending.capture.engines.push(event);
  });

  useSpeechRecognitionEvent("assetrequired", (event) => {
    const pending = pendingCaptureRef.current;
    if (!pending || pending.settled) {
      return;
    }
    pending.capture.assetRequiredEvents.push(event);
  });

  useSpeechRecognitionEvent("result", (event) => {
    const pending = pendingCaptureRef.current;
    if (!pending || pending.settled) {
      return;
    }
    pending.capture.results.push(event);
  });

  useSpeechRecognitionEvent("error", (event) => {
    const pending = pendingCaptureRef.current;
    if (!pending || pending.settled) {
      return;
    }
    pending.capture.errors.push(event);
  });

  useSpeechRecognitionEvent("nomatch", () => {
    const pending = pendingCaptureRef.current;
    if (!pending || pending.settled) {
      return;
    }
    pending.capture.nomatchCount += 1;
  });

  useSpeechRecognitionEvent("end", () => {
    const pending = pendingCaptureRef.current;
    if (!pending || pending.settled) {
      return;
    }
    pending.capture.endCount += 1;
    clearPendingCapture();
  });

  const ensureEngineIdle = useCallback(async () => {
    await ExpoSpeechRecognitionModule.abort();
    await sleep(WAIT_AFTER_ABORT_MS);
  }, []);

  const captureRecognitionRun = useCallback(
    async (options: ExpoSpeechRecognitionOptions, timeoutMs = DEFAULT_SCENARIO_TIMEOUT_MS) => {
      await ensureEngineIdle();

      return await new Promise<RecognitionCapture>((resolve) => {
        const capture: RecognitionCapture = {
          startCount: 0,
          endCount: 0,
          nomatchCount: 0,
          timedOut: false,
          engines: [],
          assetRequiredEvents: [],
          errors: [],
          results: [],
          endedAtMs: 0,
        };

        const timeoutHandle = setTimeout(async () => {
          const pending = pendingCaptureRef.current;
          if (!pending || pending.settled) {
            return;
          }
          pending.capture.timedOut = true;
          await ExpoSpeechRecognitionModule.abort();
          clearPendingCapture();
        }, timeoutMs);

        pendingCaptureRef.current = {
          startedAtMs: Date.now(),
          timeoutHandle,
          settled: false,
          resolve,
          capture,
        };

        ExpoSpeechRecognitionModule.start(options);
      });
    },
    [clearPendingCapture, ensureEngineIdle],
  );

  const getFixtureUri = useCallback(
    (key: FixtureKey) => {
      return fixtureUris.get(key) ?? null;
    },
    [fixtureUris],
  );

  const ensureAssetInstalled = useCallback(
    async (locale: string, queryOptions?: { iosTranscriberType?: "speech" | "dictation"; addsPunctuation?: boolean }) => {
      let status = await ExpoSpeechRecognitionModule.getSpeechAnalyzerAssetStatus(
        locale,
        queryOptions,
      );
      if (status.status === "installed") {
        return { ok: true, note: `Asset already installed for ${locale}.` };
      }

      if (status.status === "not_available") {
        return { ok: false, note: `Asset not available for ${locale}.` };
      }

      try {
        await ExpoSpeechRecognitionModule.downloadSpeechAnalyzerAsset(locale, queryOptions);
      } catch (error) {
        return {
          ok: false,
          note: `Asset download call failed for ${locale}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        };
      }

      const startedAt = Date.now();
      while (Date.now() - startedAt < ASSET_INSTALL_TIMEOUT_MS) {
        await sleep(1_000);
        status = await ExpoSpeechRecognitionModule.getSpeechAnalyzerAssetStatus(
          locale,
          queryOptions,
        );
        if (status.status === "installed") {
          return { ok: true, note: `Asset installed for ${locale}.` };
        }
      }

      return { ok: false, note: `Timed out waiting for ${locale} asset installation.` };
    },
    [],
  );

  const runLegacyForceScenario = useCallback(async (): Promise<ScenarioResult> => {
    const id = "legacy_force_contextual";
    const startedAt = Date.now();
    const notes: string[] = [];
    const fixtureUri = getFixtureUri("technicalTerms");

    if (!fixtureUri) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: ["Missing fixture URI for technicalTerms."],
      };
    }

    const options: ExpoSpeechRecognitionOptions = {
      lang: "en-US",
      interimResults: true,
      continuous: false,
      maxAlternatives: 3,
      addsPunctuation: true,
      iosForceLegacyEngine: true,
      contextualStrings: ["Praggnanandhaa", "Nepomniachtchi", "Carlsen"],
      audioSource: {
        uri: fixtureUri,
      },
    };

    const capture = await captureRecognitionRun(options);
    const failures = validateResultInvariants({
      capture,
      maxAlternatives: 3,
      requireTranscript: true,
    });

    const selectedEngine = capture.engines[capture.engines.length - 1];
    if (!selectedEngine) {
      failures.push("Expected engineselected event for legacy force scenario.");
    } else {
      if (selectedEngine.engine !== "SFSpeechRecognizer") {
        failures.push(`Expected legacy engine, got ${selectedEngine.engine}.`);
      }
      if (selectedEngine.reason !== "force_legacy") {
        failures.push(`Expected force_legacy reason, got ${selectedEngine.reason}.`);
      }
    }

    if (capture.timedOut) {
      failures.push("Scenario timed out before completion.");
    }

    if (capture.errors.length > 0) {
      notes.push(
        `Observed error events: ${capture.errors.map((error) => error.error).join(", ")}`,
      );
    }

    return {
      id,
      status: failures.length === 0 ? "PASS" : "FAIL",
      durationMs: Date.now() - startedAt,
      notes: failures.length === 0 ? notes.concat("Legacy force path validated.") : failures,
    };
  }, [captureRecognitionRun, getFixtureUri]);

  const runSpeechAnalyzerContextualScenario = useCallback(async (): Promise<ScenarioResult> => {
    const id = "ios26_contextual_analyzer";
    const startedAt = Date.now();
    const fixtureUri = getFixtureUri("technicalTerms");
    if (!fixtureUri) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: ["Missing fixture URI for technicalTerms."],
      };
    }

    const assetCheck = await ensureAssetInstalled("en-US", {
      iosTranscriberType: "speech",
    });
    if (!assetCheck.ok) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: [assetCheck.note],
      };
    }

    const options: ExpoSpeechRecognitionOptions = {
      lang: "en-US",
      interimResults: true,
      continuous: false,
      maxAlternatives: 2,
      addsPunctuation: true,
      iosForceLegacyEngine: false,
      iosTranscriberType: "speech",
      iosSpeechAnalyzerAssetPolicy: "require",
      contextualStrings: ["Praggnanandhaa", "Nakamura", "Carlsen"],
      audioSource: {
        uri: fixtureUri,
      },
    };

    const preferred = await ExpoSpeechRecognitionModule.getPreferredEngine(
      toEngineSelectionOptions(options),
    );
    const capture = await captureRecognitionRun(options);
    const failures = validateResultInvariants({
      capture,
      maxAlternatives: 2,
      requireTranscript: true,
    });

    const selectedEngine = capture.engines[capture.engines.length - 1];
    if (!selectedEngine) {
      failures.push("Expected engineselected event for SpeechAnalyzer contextual scenario.");
    } else {
      if (selectedEngine.engine !== "SpeechAnalyzer") {
        failures.push(`Expected SpeechAnalyzer engine, got ${selectedEngine.engine}.`);
      }
      if (selectedEngine.reason !== "asset_installed") {
        failures.push(`Expected asset_installed reason, got ${selectedEngine.reason}.`);
      }
      if (selectedEngine.reason === "contextual_strings") {
        failures.push("contextualStrings must not force legacy on iOS 26 path.");
      }
      if (selectedEngine.engine !== preferred.engine || selectedEngine.reason !== preferred.reason) {
        failures.push(
          `Engine selection mismatch. preferred=${preferred.engine}/${preferred.reason}, actual=${selectedEngine.engine}/${selectedEngine.reason}.`,
        );
      }
    }

    if (capture.timedOut) {
      failures.push("Scenario timed out before completion.");
    }

    return {
      id,
      status: failures.length === 0 ? "PASS" : "FAIL",
      durationMs: Date.now() - startedAt,
      notes:
        failures.length === 0
          ? ["SpeechAnalyzer contextualStrings path validated."]
          : failures,
    };
  }, [captureRecognitionRun, ensureAssetInstalled, getFixtureUri]);

  const runMaxAlternativesConfidenceScenario = useCallback(async (): Promise<ScenarioResult> => {
    const id = "ios26_alternatives_confidence";
    const startedAt = Date.now();
    const fixtureUri = getFixtureUri("longSentence");
    if (!fixtureUri) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: ["Missing fixture URI for longSentence."],
      };
    }

    const assetCheck = await ensureAssetInstalled("en-US", {
      iosTranscriberType: "speech",
    });
    if (!assetCheck.ok) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: [assetCheck.note],
      };
    }

    const options: ExpoSpeechRecognitionOptions = {
      lang: "en-US",
      interimResults: true,
      continuous: false,
      maxAlternatives: 3,
      addsPunctuation: false,
      iosForceLegacyEngine: false,
      iosTranscriberType: "speech",
      iosSpeechAnalyzerAssetPolicy: "require",
      audioSource: {
        uri: fixtureUri,
      },
    };

    const capture = await captureRecognitionRun(options);
    const failures = validateResultInvariants({
      capture,
      maxAlternatives: 3,
      requireTranscript: true,
      expectPunctuationStripped: true,
    });

    const selectedEngine = capture.engines[capture.engines.length - 1];
    if (!selectedEngine) {
      failures.push("Expected engineselected event for alternatives/confidence scenario.");
    } else if (selectedEngine.engine !== "SpeechAnalyzer") {
      failures.push(
        `Expected SpeechAnalyzer engine for alternatives/confidence scenario, got ${selectedEngine.engine}.`,
      );
    }

    if (capture.timedOut) {
      failures.push("Scenario timed out before completion.");
    }

    return {
      id,
      status: failures.length === 0 ? "PASS" : "FAIL",
      durationMs: Date.now() - startedAt,
      notes:
        failures.length === 0
          ? ["maxAlternatives + confidence + punctuation-stripping invariants validated."]
          : failures,
    };
  }, [captureRecognitionRun, ensureAssetInstalled, getFixtureUri]);

  const runRequirePolicyMissingAssetScenario = useCallback(async (): Promise<ScenarioResult> => {
    const id = "asset_policy_require_missing";
    const startedAt = Date.now();
    const fixtureUri = getFixtureUri("helloWorld");
    if (!fixtureUri) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: ["Missing fixture URI for helloWorld."],
      };
    }

    const locales = await ExpoSpeechRecognitionModule.getSpeechAnalyzerLocales({
      iosTranscriberType: "speech",
    });
    const candidate = locales.find((entry) => entry.status === "not_installed");
    if (!candidate) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: ["No not_installed SpeechAnalyzer locale found on this simulator."],
      };
    }

    const options: ExpoSpeechRecognitionOptions = {
      lang: candidate.locale,
      interimResults: false,
      continuous: false,
      maxAlternatives: 1,
      addsPunctuation: false,
      iosSpeechAnalyzerAssetPolicy: "require",
      iosForceLegacyEngine: false,
      audioSource: {
        uri: fixtureUri,
      },
    };

    const preferred = await ExpoSpeechRecognitionModule.getPreferredEngine(
      toEngineSelectionOptions(options),
    );
    const capture = await captureRecognitionRun(options);
    const failures: string[] = [];

    const hasAssetRequiredEvent = capture.assetRequiredEvents.length > 0;
    if (!hasAssetRequiredEvent) {
      failures.push("Expected at least one assetrequired event.");
    }

    const hasAssetNotInstalledError = capture.errors.some(
      (error) => error.error === "asset-not-installed",
    );
    if (!hasAssetNotInstalledError) {
      failures.push(
        `Expected asset-not-installed error, got [${capture.errors
          .map((error) => error.error)
          .join(", ")}].`,
      );
    }

    if (capture.errors.some((error) => error.error === "not-allowed")) {
      failures.push(
        "Unexpected not-allowed error in assetPolicy=require flow (should fail with asset-not-installed first).",
      );
    }

    if (preferred.reason !== "asset_not_installed") {
      failures.push(
        `Preferred-engine preflight should report asset_not_installed; got ${preferred.reason}.`,
      );
    }

    return {
      id,
      status: failures.length === 0 ? "PASS" : "FAIL",
      durationMs: Date.now() - startedAt,
      notes:
        failures.length === 0
          ? [`Validated require policy using missing locale ${candidate.locale}.`]
          : failures,
    };
  }, [captureRecognitionRun, getFixtureUri]);

  const runFileSourcePermissionBypassScenario = useCallback(async (): Promise<ScenarioResult> => {
    const id = "file_source_permission_bypass";
    const startedAt = Date.now();
    const fixtureUri = getFixtureUri("shortSentence");
    if (!fixtureUri) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: ["Missing fixture URI for shortSentence."],
      };
    }

    const assetCheck = await ensureAssetInstalled("en-US", {
      iosTranscriberType: "speech",
    });
    if (!assetCheck.ok) {
      return {
        id,
        status: "SKIP",
        durationMs: Date.now() - startedAt,
        notes: [assetCheck.note],
      };
    }

    const micPermission = await ExpoSpeechRecognitionModule.getMicrophonePermissionsAsync();

    const options: ExpoSpeechRecognitionOptions = {
      lang: "en-US",
      interimResults: true,
      continuous: false,
      maxAlternatives: 2,
      iosSpeechAnalyzerAssetPolicy: "require",
      iosForceLegacyEngine: false,
      audioSource: {
        uri: fixtureUri,
      },
    };

    const capture = await captureRecognitionRun(options);
    const failures = validateResultInvariants({
      capture,
      maxAlternatives: 2,
      requireTranscript: true,
    });

    if (capture.errors.some((error) => error.error === "not-allowed")) {
      failures.push(
        "Received not-allowed for file source recognition (microphone permission should not be required).",
      );
    }

    const notes: string[] = [
      `Microphone permission status during run: ${micPermission.status}.`,
    ];
    if (micPermission.granted) {
      notes.push(
        "Permission-bypass scenario is strongest when microphone permission is denied or undetermined.",
      );
    }

    return {
      id,
      status: failures.length === 0 ? "PASS" : "FAIL",
      durationMs: Date.now() - startedAt,
      notes: failures.length === 0 ? notes : failures,
    };
  }, [captureRecognitionRun, ensureAssetInstalled, getFixtureUri]);

  const runScenario = useCallback(
    async (scenarioRunner: () => Promise<ScenarioResult>) => {
      const result = await scenarioRunner();
      setScenarioResults((prev) => [...prev, result]);
      appendLog(
        `${automationMarkerPrefix}_SCENARIO:${result.id}:${result.status}:${result.notes[0] ?? "OK"}`,
      );
      return result;
    },
    [appendLog],
  );

  const runSuite = useCallback(async () => {
    if (Platform.OS !== "ios" || suiteStatus === "RUNNING") {
      return;
    }

    setSuiteStatus("RUNNING");
    setSuiteSummary("RUNNING");
    setScenarioResults([]);
    setLogLines([]);
    appendLog(`${automationMarkerPrefix}_STATUS:RUNNING`);

    try {
      const results: ScenarioResult[] = [];
      const runners: { id: string; run: () => Promise<ScenarioResult> }[] = [
        { id: "legacy_force_contextual", run: runLegacyForceScenario },
        { id: "ios26_contextual_analyzer", run: runSpeechAnalyzerContextualScenario },
        { id: "ios26_alternatives_confidence", run: runMaxAlternativesConfidenceScenario },
        { id: "asset_policy_require_missing", run: runRequirePolicyMissingAssetScenario },
        { id: "file_source_permission_bypass", run: runFileSourcePermissionBypassScenario },
      ];

      for (const runner of runners) {
        setRunningScenarioId(runner.id);
        const result = await runScenario(runner.run);
        results.push(result);
      }

      const hasFailure = results.some((result) => result.status === "FAIL");
      const hasSkip = results.some((result) => result.status === "SKIP");
      const nextStatus: SuiteStatus = hasFailure ? "FAIL" : "PASS";
      const summary = hasFailure
        ? "FAIL"
        : hasSkip
          ? "PASS_WITH_SKIPS"
          : "PASS";

      setSuiteStatus(nextStatus);
      setSuiteSummary(summary);
      appendLog(`${automationMarkerPrefix}_STATUS:${nextStatus}`);
      appendLog(`${automationMarkerPrefix}_SUMMARY:${summary}`);
    } catch (error) {
      setSuiteStatus("FAIL");
      setSuiteSummary("FAIL");
      appendLog(`${automationMarkerPrefix}_STATUS:FAIL`);
      appendLog(
        `${automationMarkerPrefix}_UNCAUGHT_ERROR:${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    } finally {
      setRunningScenarioId(null);
      await ensureEngineIdle();
    }
  }, [
    appendLog,
    ensureEngineIdle,
    runFileSourcePermissionBypassScenario,
    runLegacyForceScenario,
    runMaxAlternativesConfidenceScenario,
    runRequirePolicyMissingAssetScenario,
    runScenario,
    runSpeechAnalyzerContextualScenario,
    suiteStatus,
  ]);

  const requestPermissions = useCallback(async () => {
    if (Platform.OS !== "ios") {
      return;
    }
    const microphone = await ExpoSpeechRecognitionModule.requestMicrophonePermissionsAsync();
    appendLog(
      `${automationMarkerPrefix}_PERMISSION:microphone:${microphone.status}:${microphone.granted}`,
    );

    const speech = await ExpoSpeechRecognitionModule.requestSpeechRecognizerPermissionsAsync();
    appendLog(
      `${automationMarkerPrefix}_PERMISSION:speech:${speech.status}:${speech.granted}`,
    );
  }, [appendLog]);

  const resetResults = useCallback(() => {
    setScenarioResults([]);
    setLogLines([]);
    setSuiteStatus("IDLE");
    setSuiteSummary("NOT_RUN");
    setRunningScenarioId(null);
    appendLog(`${automationMarkerPrefix}_STATUS:IDLE`);
  }, [appendLog]);

  if (Platform.OS !== "ios") {
    return null;
  }

  const fixturesReady = fixtureUris.size >= 4;

  return (
    <Card>
      <Text style={styles.title}>iOS Automation Harness (Fixture Driven)</Text>
      <Text style={styles.mono}>
        {automationMarkerPrefix}_FIXTURES_READY:{String(fixturesReady)}
      </Text>
      <Text style={styles.mono}>
        {automationMarkerPrefix}_STATUS:{suiteStatus}
      </Text>
      <Text style={styles.mono}>
        {automationMarkerPrefix}_SUMMARY:{suiteSummary}
      </Text>
      {runningScenarioId ? (
        <Text style={styles.mono}>
          {automationMarkerPrefix}_RUNNING_SCENARIO:{runningScenarioId}
        </Text>
      ) : null}

      <View style={styles.buttonRow}>
        <BigButton
          title={suiteStatus === "RUNNING" ? "Running iOS Suite..." : "Run iOS Automation Suite"}
          disabled={suiteStatus === "RUNNING" || !fixturesReady}
          onPress={() => {
            void runSuite();
          }}
          color="#1f8f49"
        />
      </View>
      <View style={styles.buttonRow}>
        <SmallButton
          title="Request iOS Permissions"
          onPress={() => {
            void requestPermissions();
          }}
        />
        <SmallButton title="Reset Harness" onPress={resetResults} />
      </View>

      {scenarioResults.length > 0 ? (
        <View style={styles.section}>
          {scenarioResults.map((result) => (
            <View key={result.id} style={styles.scenarioRow}>
              <Text style={styles.mono}>
                {automationMarkerPrefix}_SCENARIO:{result.id}:{result.status}
              </Text>
              <Text style={styles.note}>
                {result.notes[0] ?? "No notes"} ({result.durationMs}ms)
              </Text>
            </View>
          ))}
        </View>
      ) : null}

      {logLines.length > 0 ? (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Recent Harness Logs</Text>
          {logLines.slice(0, 10).map((line) => (
            <Text key={line} style={styles.note}>
              {line}
            </Text>
          ))}
        </View>
      ) : null}
    </Card>
  );
}

const styles = StyleSheet.create({
  title: {
    fontWeight: "700",
    fontSize: 13,
    marginBottom: 6,
  },
  sectionTitle: {
    fontWeight: "700",
    marginBottom: 4,
    fontSize: 12,
  },
  mono: {
    fontFamily: Platform.OS === "ios" ? "Courier" : "monospace",
    fontSize: 11,
  },
  buttonRow: {
    flexDirection: "row",
    gap: 8,
    marginTop: 8,
    flexWrap: "wrap",
  },
  section: {
    marginTop: 10,
    gap: 4,
  },
  scenarioRow: {
    paddingVertical: 2,
    gap: 1,
  },
  note: {
    fontSize: 10,
    color: "#333",
    fontFamily: Platform.OS === "ios" ? "Courier" : "monospace",
  },
});
