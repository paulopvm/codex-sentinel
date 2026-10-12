#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Sentinel.app"
APP_PATH="$ROOT/dist/$APP_NAME"

cd "$ROOT"
swift build -c release
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/release/CodexSentinel "$APP_PATH/Contents/MacOS/CodexSentinel"
cp Info.plist "$APP_PATH/Contents/Info.plist"
chmod 755 "$APP_PATH/Contents/MacOS/CodexSentinel"

if [[ "${1:-}" == "--install" ]]; then
  DESTINATION="$HOME/Applications/$APP_NAME"
  mkdir -p "$HOME/Applications"
  rm -rf "$DESTINATION"
  ditto "$APP_PATH" "$DESTINATION"
  echo "Aplicativo instalado em: $DESTINATION"
else
  echo "Aplicativo pronto em: $APP_PATH"
fi
