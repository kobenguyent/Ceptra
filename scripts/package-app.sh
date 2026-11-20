#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="1.0.0"
BUILD_NUMBER="1"
GITHUB_REPO="kobenguyent/Ceptra"
ARCH_MODE="native" # native | universal
OUTPUT_DIR="$ROOT_DIR/build"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2#v}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --github-repo)
      GITHUB_REPO="$2"
      shift 2
      ;;
    --arch)
      ARCH_MODE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

APP_NAME="Ceptra"
BUNDLE_ID="com.kobenguyent.Ceptra"
APP_BUNDLE="$OUTPUT_DIR/${APP_NAME}.app"
DMG_STAGING="$OUTPUT_DIR/dmg-staging"

echo "==> Packaging ${APP_NAME} v${VERSION} (mode: ${ARCH_MODE}, repo: ${GITHUB_REPO})"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# 1. Build Release Binary
if [[ "$ARCH_MODE" == "universal" ]]; then
  echo "==> Building universal binary (arm64 + x86_64)..."
  swift build -c release --arch arm64 --arch x86_64
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
  ARCH_LABEL="universal"
else
  HOST_ARCH="$(uname -m)"
  echo "==> Building native release binary (${HOST_ARCH})..."
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
  ARCH_LABEL="${HOST_ARCH}"
fi

GUI_BIN="${BIN_DIR}/${APP_NAME}"
if [[ ! -x "$GUI_BIN" ]]; then
  echo "ERROR: Expected binary at ${GUI_BIN}" >&2
  exit 1
fi

echo "==> Binary architecture check:"
lipo -info "$GUI_BIN" || file "$GUI_BIN"

# 2. Generate App Icon (.icns)
ICON_PATH="$OUTPUT_DIR/Ceptra.icns"
echo "==> Generating Ceptra.icns..."
swift "$ROOT_DIR/scripts/generate-icon.swift" "$ICON_PATH"

# 3. Assemble Ceptra.app Bundle
echo "==> Assembling ${APP_BUNDLE}..."
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$GUI_BIN" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
chmod 755 "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
cp "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/Ceptra.icns"
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>Ceptra</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>CeptraGitHubRepo</key>
    <string>${GITHUB_REPO}</string>
</dict>
</plist>
EOF

# 4. Code Signing (Developer ID when provided, otherwise ad-hoc sign for Apple Silicon & local install without Apple Developer account)
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with Developer ID identity: ${CODESIGN_IDENTITY}"
  codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
  echo "==> Applying ad-hoc signature (no Apple Developer account required)..."
  codesign --force --deep --sign - "$APP_BUNDLE"
fi
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
codesign --verify --deep --strict "$APP_BUNDLE"

# 5. Create ZIP archive (preferred for fast silent in-app self-updates)
ZIP_NAME="${APP_NAME}-${VERSION}-macOS-${ARCH_LABEL}.zip"
ZIP_PATH="$OUTPUT_DIR/${ZIP_NAME}"
echo "==> Creating ZIP archive: ${ZIP_NAME}"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# 6. Create DMG disk image with /Applications drag-and-drop symlink
DMG_NAME="${APP_NAME}-${VERSION}-macOS-${ARCH_LABEL}.dmg"
DMG_PATH="$OUTPUT_DIR/${DMG_NAME}"
echo "==> Creating DMG disk image: ${DMG_NAME}"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_STAGING" "$ICON_PATH"

# 7. Generate SHA256SUMS.txt (used by Ceptra in-app Auto-Update cryptographic verifier)
echo "==> Generating SHA256SUMS.txt..."
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
)

echo "==> Packaging complete! Artifacts in ${OUTPUT_DIR}:"
ls -lh "$OUTPUT_DIR"
cat "$OUTPUT_DIR/SHA256SUMS.txt"
