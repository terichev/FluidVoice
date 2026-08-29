#!/bin/bash
# Installs the latest FluidVoice + GigaAM v3 build from this fork's CI.
#
# Requires the GitHub CLI (`brew install gh`, then `gh auth login`).
#
# What it repairs and why:
# - actions/upload-artifact materializes framework symlinks into file copies,
#   which breaks the bundle layout codesign expects.
# - CI builds are only linker-signed; macOS TCC (Accessibility) refuses to
#   register an app without a full bundle signature, so we ad-hoc sign locally.
# - The Debug build shares the release CFBundleIdentifier; TCC keys permission
#   grants by bundle id + signature, so this copy gets its own id and can
#   coexist with an official FluidVoice installation.
#
# macOS pins Accessibility to the ad-hoc signature hash, so the permission has
# to be re-granted after every update — use the prompt inside the app, not the
# "+" button in System Settings (silently fails for ad-hoc apps on macOS 26).
set -euo pipefail

REPO="${FLUIDVOICE_FORK:-terichev/FluidVoice}"
BRANCH="${FLUIDVOICE_BRANCH:-feat/gigaam-v3}"
APP_PATH="/Applications/FluidVoice Debug.app"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Fetching latest successful build of ${BRANCH} from ${REPO}..."
RUN_ID="$(gh run list -R "$REPO" --workflow build-app.yml --branch "$BRANCH" \
    --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
if [ -z "$RUN_ID" ]; then
    echo "No successful build found. Trigger one with:"
    echo "  gh workflow run build-app.yml -R $REPO --ref $BRANCH"
    exit 1
fi
echo "Using run $RUN_ID"

gh run download "$RUN_ID" -R "$REPO" -n FluidVoice-Debug -D "$WORKDIR"
ditto -x -k "$WORKDIR/FluidVoice-Debug.zip" "$WORKDIR/extracted"
APP_SRC="$(find "$WORKDIR/extracted" -maxdepth 1 -name '*.app' | head -1)"
if [ -z "$APP_SRC" ]; then
    echo "No .app bundle inside the artifact"
    exit 1
fi

for fw in "$APP_SRC/Contents/Frameworks"/*.framework; do
    [ -d "$fw" ] || continue
    name="$(basename "$fw" .framework)"
    if [ -d "$fw/Versions/A" ] && [ ! -L "$fw/Versions/Current" ]; then
        rm -rf "$fw/Versions/Current"
        ln -s A "$fw/Versions/Current"
    fi
    if [ -e "$fw/$name" ] && [ ! -L "$fw/$name" ] && [ -e "$fw/Versions/Current/$name" ]; then
        rm -rf "$fw/$name"
        ln -s "Versions/Current/$name" "$fw/$name"
    fi
    if [ -e "$fw/Resources" ] && [ ! -L "$fw/Resources" ] && [ -d "$fw/Versions/Current/Resources" ]; then
        rm -rf "$fw/Resources"
        ln -s Versions/Current/Resources "$fw/Resources"
    fi
done

plutil -replace CFBundleIdentifier -string "com.FluidApp.app.debug" "$APP_SRC/Contents/Info.plist"
codesign --force --deep --sign - "$APP_SRC"
codesign --verify --deep --strict "$APP_SRC"

pkill -f "FluidVoice Debug" 2>/dev/null || true
rm -rf "$APP_PATH"
ditto "$APP_SRC" "$APP_PATH"

# TCC pins Accessibility to the ad-hoc signature hash, so the previous grant
# turns into a stale row that shows as enabled yet silently denies the new
# binary. Clear it so the app prompts fresh on first use.
tccutil reset Accessibility com.FluidApp.app.debug > /dev/null 2>&1 || true

echo "Installed: $APP_PATH"
echo "Re-grant Accessibility when the app asks (the previous grant was cleared on purpose)."
open "$APP_PATH"
