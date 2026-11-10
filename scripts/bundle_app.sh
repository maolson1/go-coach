#!/usr/bin/env zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${PROJECT_DIR}/GoCoach.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
HUMAN_MODEL_PATH="${PROJECT_DIR}/Resources/models/b18c384nbt-humanv0.bin.gz"
HUMAN_MODEL_URL="https://github.com/lightvector/KataGo/releases/download/v1.15.0/b18c384nbt-humanv0.bin.gz"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}/scripts" "${RESOURCES_DIR}/models" "${PROJECT_DIR}/Resources/models"

# 1. Set up Python virtualenv with google-antigravity if not already present
if [[ ! -x "${PROJECT_DIR}/.venv/bin/python" ]]; then
    echo "Setting up Python virtual environment in .venv..."
    python3 -m venv "${PROJECT_DIR}/.venv"
    if [[ -f "${PROJECT_DIR}/requirements.txt" ]]; then
        "${PROJECT_DIR}/.venv/bin/pip" install --upgrade pip
        "${PROJECT_DIR}/.venv/bin/pip" install -r "${PROJECT_DIR}/requirements.txt" || \
            echo "Warning: Could not install optional google-antigravity SDK package; live .coach_ipc session bridge and offline KataGo coach will still work."
    fi
fi

# 2. Download KataGo Human SL model if not already present
if [[ ! -f "${HUMAN_MODEL_PATH}" ]]; then
    echo "Downloading KataGo Human SL model (b18c384nbt-humanv0.bin.gz)..."
    curl -L --fail -o "${HUMAN_MODEL_PATH}" "${HUMAN_MODEL_URL}"
fi

# 3. Compile Swift sources into GoCoach.app binary
echo "Compiling GoCoach..."
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

# 4. Bundle scripts, models, and icon
cp "${PROJECT_DIR}/scripts/coach_bridge.py" "${RESOURCES_DIR}/scripts/coach_bridge.py"
chmod +x "${RESOURCES_DIR}/scripts/coach_bridge.py"

if [[ -f "${HUMAN_MODEL_PATH}" ]]; then
    ln -sf "${HUMAN_MODEL_PATH}" "${RESOURCES_DIR}/models/b18c384nbt-humanv0.bin.gz"
fi

if [[ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

if [[ -f "${PROJECT_DIR}/cherry-tree.jpg" ]]; then
    cp "${PROJECT_DIR}/cherry-tree.jpg" "${RESOURCES_DIR}/cherry-tree.jpg"
elif [[ -f "${PROJECT_DIR}/Resources/cherry-tree.jpg" ]]; then
    cp "${PROJECT_DIR}/Resources/cherry-tree.jpg" "${RESOURCES_DIR}/cherry-tree.jpg"
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
