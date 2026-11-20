#!/usr/bin/env bash
set -euo pipefail

# Ceptra Local MacBook Pro Installer — No Apple Developer Account Required!
# Builds a release binary, assembles Ceptra.app, applies an ad-hoc signature,
# strips quarantine attributes, and installs into /Applications (or ~/Applications).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LATEST_TAG="$(git describe --tags --abbrev=0 --match 'v*.*.*' 2>/dev/null || echo 'v1.0.0')"
VERSION="${LATEST_TAG#v}"
INSTALL_DIR="/Applications"
LAUNCH_AFTER="true"
GITHUB_REPO="kobenguyent/Ceptra"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2#v}"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --github-repo)
      GITHUB_REPO="$2"
      shift 2
      ;;
    --no-launch)
      LAUNCH_AFTER="false"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--version 1.0.0] [--install-dir /Applications] [--github-repo owner/repo] [--no-launch]" >&2
      exit 1
      ;;
  esac
done

echo "============================================================"
echo "  Ceptra Local Installer (Zero Apple Developer Account)     "
echo "============================================================"

# Build & ad-hoc sign via package-app.sh
chmod +x "$ROOT_DIR/scripts/package-app.sh"
"$ROOT_DIR/scripts/package-app.sh" \
  --version "$VERSION" \
  --github-repo "$GITHUB_REPO" \
  --arch native

SRC_APP="$ROOT_DIR/build/Ceptra.app"
DEST_APP="${INSTALL_DIR}/Ceptra.app"

# Close any currently running Ceptra instance cleanly before replacing
if pgrep -x "Ceptra" >/dev/null 2>&1; then
  echo "==> Closing running Ceptra instance..."
  osascript -e 'tell application "Ceptra" to quit' 2>/dev/null || killall Ceptra 2>/dev/null || true
  sleep 1
fi

echo "==> Installing Ceptra.app to ${DEST_APP}..."
if [[ ! -w "$INSTALL_DIR" ]]; then
  echo "Note: ${INSTALL_DIR} requires administrator permissions (or re-run with --install-dir \$HOME/Applications)."
  sudo rm -rf "$DEST_APP"
  sudo ditto "$SRC_APP" "$DEST_APP"
  sudo xattr -cr "$DEST_APP" || true
else
  mkdir -p "$INSTALL_DIR"
  rm -rf "$DEST_APP"
  ditto "$SRC_APP" "$DEST_APP"
  xattr -cr "$DEST_APP" 2>/dev/null || true
fi

echo "==> Verifying installed ad-hoc signature..."
codesign --verify --deep --strict "$DEST_APP"

echo ""
echo "✅ Installed Ceptra v${VERSION} at: ${DEST_APP}"
echo "   You can launch it anytime from Spotlight, Launchpad, or /Applications."

if [[ "$LAUNCH_AFTER" == "true" ]]; then
  echo "==> Launching Ceptra..."
  open -a "$DEST_APP"
fi
