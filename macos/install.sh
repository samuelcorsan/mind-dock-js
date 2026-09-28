#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$HOME/Applications/MindDock.app"
config_dir="$HOME/Library/Application Support/MindDock"

mkdir -p "$app_dir/Contents/MacOS" "$config_dir"
swiftc -target arm64-apple-macosx26.0 \
  -o "$app_dir/Contents/MacOS/MindDock" \
  "$project_dir/macos/MindDock.swift" "$project_dir/macos/Recording.swift" \
  -framework SwiftUI -framework ScreenCaptureKit -framework Speech -framework AVFoundation

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>MindDock</string>
  <key>CFBundleIdentifier</key><string>dev.disam.minddock</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>MindDock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>MindDock records your voice during meetings.</string>
  <key>NSScreenCaptureUsageDescription</key><string>MindDock captures call audio to transcribe meetings.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>MindDock transcribes meeting audio on this Mac.</string>
</dict></plist>
PLIST

python3 - "$project_dir/.env" "$config_dir/config.json" <<'PY'
import json
import os
import sys

values = {}
with open(sys.argv[1], encoding="utf-8") as env_file:
    for line in env_file:
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.strip().split("=", 1)
            values[key] = value.strip().strip('"')
key = values.get("MEMORY_API_KEY")
if not key:
    raise SystemExit("MEMORY_API_KEY is missing from .env")
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as config_file:
    json.dump({"apiBaseURL": values.get("MINDDOCK_API_URL", "https://meeting-memory-rho.vercel.app").rstrip("/"), "apiKey": key}, config_file)
os.chmod(sys.argv[2], 0o600)
PY

signing_identity="$(security find-identity -v -p codesigning | sed -n 's/^[[:space:]]*[0-9]*) \([A-F0-9]\{40\}\) .*/\1/p' | head -1)"
codesign --force --sign "${signing_identity:--}" "$app_dir" >/dev/null
touch "$app_dir"
echo "MindDock installed in ~/Applications. Search for MindDock in Spotlight to open it."
