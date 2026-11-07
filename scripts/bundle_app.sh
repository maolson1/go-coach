#!/usr/bin/env zsh
set -euo pipefail

PROJECT_DIR="/Users/matt/go-coach"
APP_BUNDLE="${PROJECT_DIR}/GoCoach.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}/scripts" "${RESOURCES_DIR}/models"

if [[ -f "${PROJECT_DIR}/.build_bin" ]]; then
    cp "${PROJECT_DIR}/.build_bin" "${MACOS_DIR}/GoCoach"
else
    swiftc -module-cache-path /tmp/swift-module-cache -target arm64-apple-macosx14.0 -O \
        -o "${MACOS_DIR}/GoCoach" \
        "${PROJECT_DIR}"/Sources/GoCoach/GoCoachApp.swift \
        "${PROJECT_DIR}"/Sources/GoCoach/Models/*.swift \
        "${PROJECT_DIR}"/Sources/GoCoach/Services/*.swift \
        "${PROJECT_DIR}"/Sources/GoCoach/Views/*.swift
fi
chmod +x "${MACOS_DIR}/GoCoach"

cp "${PROJECT_DIR}/scripts/coach_bridge.py" "${RESOURCES_DIR}/scripts/coach_bridge.py"
chmod +x "${RESOURCES_DIR}/scripts/coach_bridge.py"

if [[ -f "${PROJECT_DIR}/Resources/models/b18c384nbt-humanv0.bin.gz" ]]; then
    ln -sf "${PROJECT_DIR}/Resources/models/b18c384nbt-humanv0.bin.gz" "${RESOURCES_DIR}/models/b18c384nbt-humanv0.bin.gz"
fi

if [[ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GoCoach</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.gocoach.app</string>
    <key>CFBundleName</key>
    <string>GoCoach</string>
    <key>CFBundleDisplayName</key>
    <string>GoCoach</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Bundled ${APP_BUNDLE} successfully."
