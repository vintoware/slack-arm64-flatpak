#!/bin/sh
#
# slack-install.sh — runs inside the flatpak build sandbox, next to the extracted
# overlay (slack-overlay/) and the other module sources. Installs ONLY the
# redistributable arm64 parts into /app; Slack itself arrives at install time via
# extra-data (see apply_extra). build.sh renders @APP_ID@.
#
set -eu

APP_ID="@APP_ID@"
O=slack-overlay
[ -d "$O/electron" ] || { echo "overlay not found"; exit 1; }

# 1) arm64 Electron runtime. Electron loads resources/ next to its binary; that is
#    Slack's app, assembled into /app/extra by apply_extra at install time.
mkdir -p /app/slack
cp -a "$O/electron/." /app/slack/
ln -sfn /app/extra/resources /app/slack/resources
chmod 755 /app/slack/slack

# 2) arm64 native modules, copied over app.asar.unpacked by apply_extra
mkdir -p /app/lib/slack-native
cp -a "$O/native/." /app/lib/slack-native/

# 3) install-time hook
install -D -m 755 apply_extra /app/bin/apply_extra

# 4) launcher. Chromium's sandbox stays ON: the setuid chrome-sandbox can't work
#    inside flatpak, so zypak (built in the zypak module) redirects Chromium's
#    sandboxed process creation to the Flatpak portal (flatpak-spawn --sandbox).
#    Same approach as Flathub's com.slack.Slack.
#    TMPDIR: the per-process sandboxes don't share /tmp, so point it at the app's cache.
#    WebRtcPipeWireCamera: use the camera through PipeWire + the xdg camera portal,
#    so no --device=all is needed (see pw-camera-filter for the Apple camera fix).
cat > /app/bin/slack <<'LAUNCHER'
#!/bin/sh
export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}"
XDG_DOWNLOAD_DIR="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
[ -n "$XDG_DOWNLOAD_DIR" ] && export XDG_DOWNLOAD_DIR
exec zypak-wrapper /app/slack/slack --enable-features=WebRtcPipeWireCamera "$@"
LAUNCHER
chmod 755 /app/bin/slack

# 5) desktop entry, icon, metainfo
install -d /app/share/applications
cat > "/app/share/applications/${APP_ID}.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Slack
Comment=Slack Desktop
Exec=slack %U
Icon=${APP_ID}
Terminal=false
Categories=Network;InstantMessaging;
MimeType=x-scheme-handler/slack;
StartupWMClass=Slack
X-GNOME-UsesNotifications=true
DESK
install -D -m 644 slack.svg "/app/share/icons/hicolor/scalable/apps/${APP_ID}.svg"
install -D -m 644 metainfo.xml "/app/share/metainfo/${APP_ID}.metainfo.xml"

echo "slack runtime installed into /app (app_id=$APP_ID); Slack itself is extra-data"
