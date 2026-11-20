#!/usr/bin/env bash
#
# 05-assemble.sh — Package the REDISTRIBUTABLE arm64 parts into
# slack-overlay-<VER>-arm64.tar.xz, and describe Slack's own packages (which are
# NOT shipped — flatpak downloads them as extra-data at install time) in
# extra-data.env. Also writes build-inputs.json (versions + hashes).
#
# Overlay layout:
#   slack-overlay/electron/   stock arm64 Electron (binary renamed `slack`), no resources/
#   slack-overlay/native/     arm64 .node files built here from MIT npm sources + our
#                             no-op stubs, laid out relative to
#                             resources/app.asar.unpacked/node_modules/
#
# Stages 03/04 already produced a full arm64 app tree in $APP_ROOT and verified that
# every native module in it is aarch64. That tree contains Slack's code, so it is only
# a build-time check and is never packaged.
#
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
. "$BUILD/versions.env"

UNPACKED="$APP_ROOT/resources/app.asar.unpacked/node_modules"
SDU_DEST="$(cat "$BUILD/sdu-dest.txt")"

STAGE_ROOT="$BUILD/overlay"
STAGE="$STAGE_ROOT/slack-overlay"
rm -rf "$STAGE_ROOT"; mkdir -p "$STAGE/electron" "$STAGE/native"

# 1) stock arm64 Electron, straight from the Electron release zip (stage 03).
cp -a "$BUILD/electron/." "$STAGE/electron/"
mv "$STAGE/electron/electron" "$STAGE/electron/slack"
rm -rf "$STAGE/electron/resources"   # default_app.asar; Slack's resources/ come at install time

# 2) every arm64 .node except Slack's proprietary slack-desktop-utils (extra-data).
( cd "$UNPACKED" && find . -name '*.node' ! -path "./$SDU_DEST" -print0 ) |
  while IFS= read -r -d '' f; do
    mkdir -p "$STAGE/native/$(dirname "$f")"
    cp -f "$UNPACKED/$f" "$STAGE/native/$f"
    echo "  native: ${f#./}"
  done

# Guard: nothing from Slack's package may end up in the overlay.
LEAK="$(find "$STAGE" \( -name 'app.asar' -o -name 'slackdesktoputils.node' -o -path '*/resources/*' \) -print)"
[ -z "$LEAK" ] || die "Slack-proprietary files leaked into the overlay:
$LEAK"
X86="$(find "$STAGE" -type f -exec file {} + | grep 'x86-64' || true)"
[ -z "$X86" ] || die "x86-64 binaries in overlay:
$X86"
echo "Overlay check OK: arm64 only, no Slack-proprietary files."

OVERLAY="$OUT/slack-overlay-$SLACK_VERSION-arm64.tar.xz"
log "Tarring overlay -> $OVERLAY"
tar -C "$STAGE_ROOT" --owner=0 --group=0 -cJf "$OVERLAY" slack-overlay
OVERLAY_SHA="$(sha256sum "$OVERLAY" | awk '{print $1}')"

# 3) extra-data description, rendered into the manifest + apply_extra by build.sh.
cat > "$OUT/extra-data.env" <<EOF
SLACK_DEB_URL=$(cat "$BUILD/input-url.txt")
SLACK_DEB_SHA256=$(cat "$BUILD/input-sha256.txt")
SLACK_DEB_SIZE=$(cat "$BUILD/input-size.txt")
SLACK_DEB_APPDIR=$(cat "$BUILD/input-appdir.txt")
SDU_URL=$(cat "$BUILD/sdu-url.txt")
SDU_SHA256=$(cat "$BUILD/sdu-sha256.txt")
SDU_SIZE=$(cat "$BUILD/sdu-size.txt")
SDU_DEST=$SDU_DEST
EOF
cat "$OUT/extra-data.env"

cat > "$OUT/build-inputs.json" <<EOF
{
  "slack_version": "$SLACK_VERSION",
  "electron_version": "$ELECTRON_VERSION",
  "native_keymap_version": "$NATIVE_KEYMAP_VERSION",
  "electron_native_auth_version": "$ENA_VER",
  "file_handler_info_version": "$FHI_VER",
  "slack_desktop_utils_version": "$SDU_VER",
  "napi_version": "$NAPI_VER",
  "input_package_url": "$(cat "$BUILD/input-url.txt")",
  "input_package_sha256": "$(cat "$BUILD/input-sha256.txt")",
  "electron_zip_sha256": "$(cat "$BUILD/electron-zip-sha256.txt")",
  "slack_desktop_utils_prebuild_url": "$(cat "$BUILD/sdu-url.txt")",
  "slack_desktop_utils_prebuild_sha256": "$(cat "$BUILD/sdu-sha256.txt")",
  "overlay_sha256": "$OVERLAY_SHA"
}
EOF
log "Stage 05 done (overlay sha256=$OVERLAY_SHA)"
