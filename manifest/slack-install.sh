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

# 4) launcher. The setuid chrome-sandbox is not usable inside a flatpak sandbox,
#    so disable the SUID sandbox (Electron falls back to/without the ns sandbox).
cat > /app/bin/slack <<'LAUNCHER'
#!/bin/sh
exec /app/slack/slack --no-sandbox --disable-gpu-sandbox "$@"
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
