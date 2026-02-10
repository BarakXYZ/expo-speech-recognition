#!/usr/bin/env bash
set -euo pipefail

MIC_PERMISSION_MODE="${1:-grant}"
FLOW_FILE="${2:-.maestro/ios-integration-suite.yaml}"
APP_ID="${APP_ID:-expo.modules.speechrecognition.example}"
SIMULATOR_DEVICE_NAME="${IOS_SIMULATOR_DEVICE_NAME:-iPhone 16}"

get_booted_udid() {
  xcrun simctl list devices | awk -F '[()]' '/Booted/{print $2; exit}'
}

BOOTED_UDID="$(get_booted_udid)"
if [[ -z "${BOOTED_UDID}" ]]; then
  echo "No booted simulator found. Attempting to boot '${SIMULATOR_DEVICE_NAME}'..."
  xcrun simctl boot "${SIMULATOR_DEVICE_NAME}" >/dev/null 2>&1 || true
  open -a Simulator >/dev/null 2>&1 || true
  sleep 5
  BOOTED_UDID="$(get_booted_udid)"
fi

if [[ -z "${BOOTED_UDID}" ]]; then
  echo "Failed to find a booted simulator. Boot one manually and retry."
  exit 1
fi

case "${MIC_PERMISSION_MODE}" in
  grant)
    xcrun simctl privacy "${BOOTED_UDID}" grant microphone "${APP_ID}" || true
    ;;
  revoke)
    xcrun simctl privacy "${BOOTED_UDID}" revoke microphone "${APP_ID}" || true
    ;;
  reset)
    xcrun simctl privacy "${BOOTED_UDID}" reset microphone "${APP_ID}" || true
    ;;
  *)
    echo "Invalid microphone permission mode '${MIC_PERMISSION_MODE}'. Use grant|revoke|reset."
    exit 1
    ;;
esac

if ! command -v maestro >/dev/null 2>&1; then
  echo "Maestro CLI not found. Install from https://maestro.mobile.dev/getting-started/installing-maestro."
  exit 1
fi

echo "Running Maestro flow '${FLOW_FILE}' on simulator ${BOOTED_UDID} (mic=${MIC_PERMISSION_MODE})..."
maestro test "${FLOW_FILE}"
