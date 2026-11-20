#!/usr/bin/env bash
#
# build-flatpak.sh — runs INSIDE the flatpak Docker image (as the container's default user). Builds a
# self-contained `.flatpak` bundle (+ the OSTree repo it came from) from the staged manifest + overlay in
# /work. flatpak does a per-user install (its own `--user` flag — not OS
# privileges) under /root/.local/share/flatpak, which is host-mounted so the
# aarch64 runtime is cached across builds. No host/root privilege is needed.
#
set -euo pipefail
cd /work

# We run as the container's default user (root — the Docker default; we simply
# don't set `docker --user`). We deliberately do NOT launch the container as a
# bare non-root uid: a uid absent from the image's /etc/passwd is the case that
# trips flatpak's rofiles-fuse/fusermount3 helper ("could not determine
# username"), and there's no reason to go there. (flatpak's `--user` below
# means "per-user install", not OS privileges.)
export XDG_RUNTIME_DIR=/tmp/runtime-root
export FLATPAK_USER_DATA=/root/.local/share/flatpak
mkdir -p "$FLATPAK_USER_DATA" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "flatpak:   $(flatpak --version 2>/dev/null || echo n/a)"
echo "builder:   $(flatpak-builder --version 2>/dev/null || echo n/a)"
echo "arch=$FLATPAK_ARCH  runtime=$FLATPAK_RUNTIME/$FLATPAK_RUNTIME_VERSION  app=$SLACK_APP_ID"
echo "state:     $FLATPAK_USER_DATA"

# Make the base resolvable and PRE-INSTALL the exact base refs (SDK + runtime)
# into the USER installation. Flathub serves org.gnome.{Sdk,Platform} for every
# arch (incl. aarch64). flatpak-builder expects them present and won't pull them
# itself, so install explicitly. FULL refs (id/arch/branch) — "id:branch" is
# rejected by flatpak 1.16.
: "${FLATPAK_SDK:=org.gnome.Sdk}"
flatpak remote-add --if-not-exists --user flathub "$FLATPAK_REMOTE_URL"
flatpak install --user -y --noninteractive flathub \
  "$FLATPAK_SDK/$FLATPAK_ARCH/$FLATPAK_RUNTIME_VERSION" \
  "$FLATPAK_RUNTIME/$FLATPAK_ARCH/$FLATPAK_RUNTIME_VERSION"

# Build the app layer against the installed base (aarch64 runtime sandbox).
# (elfutils/eu-strip is in the image for the debuginfo strip step.)
#
# AppStream: the manifest sets "appstream-compose": false and we compose here
# instead. On GNOME 49+ runtimes, flatpak-builder's in-sandbox `appstreamcli
# compose` loads icons through glycin, which sandboxes its loaders with
# `flatpak-spawn --sandbox`. That needs the Flatpak portal on a session bus, which a
# container doesn't have ("file-read-error" on the icon). Debian's appstreamcli
# renders the icon directly. The catalog is what gives the repo's appstream branch
# (software centers) its name, description and icon.
flatpak-builder --force-clean --user --arch="$FLATPAK_ARCH" build-dir manifest.json

appstreamcli compose --no-net --prefix=/ \
  --origin="$SLACK_APP_ID" \
  --result-root=build-dir/files \
  --data-dir=build-dir/files/share/app-info/xmls \
  --icons-dir=build-dir/files/share/app-info/icons/flatpak \
  --components="$SLACK_APP_ID,$SLACK_APP_ID.desktop" \
  build-dir/files
[ -s "build-dir/files/share/app-info/xmls/$SLACK_APP_ID.xml.gz" ] || { echo "appstream compose produced no catalog" >&2; exit 1; }

# Export to a local repo (commits the extra-data declarations from the metadata).
rm -rf repo
flatpak build-export --arch="$FLATPAK_ARCH" repo build-dir master

flatpak --user list

# Produce a self-contained bundle into /work (the user-owned mount).
# build-bundle (flatpak 1.16): LOCATION FILENAME NAME [BRANCH]; arch + the
# runtime's source repo are option flags, not positionals.
OUT="/work/$SLACK_APP_ID.$FLATPAK_ARCH.flatpak"
flatpak build-bundle \
  --arch="$FLATPAK_ARCH" \
  --runtime-repo="$FLATPAK_REMOTE_URL" \
  repo "$OUT" "$SLACK_APP_ID"

echo
echo "BUNDLE OK: $OUT ($(du -h "$OUT" | cut -f1))"
