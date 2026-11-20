#!/bin/sh
# Build the pw-camera-filter wrapper (see pw-camera-filter.c). Runs in the flatpak
# build sandbox (org.gnome.Sdk); installs into ${PREFIX:-/app}/lib:
#   libpipewire-0.3-real.so.0 -> the runtime's real libpipewire
#   libpipewire-0.3.so.0      the wrapper (DT_NEEDED on the -real name)
set -eu
PREFIX="${PREFIX:-/app}"
MULTIARCH="$(gcc -print-multiarch)"
REAL="/usr/lib/$MULTIARCH/libpipewire-0.3.so.0"
[ -e "$REAL" ] || { echo "real libpipewire not found at $REAL" >&2; exit 1; }

mkdir -p "$PREFIX/lib" stub
ln -sfn "$REAL" "$PREFIX/lib/libpipewire-0.3-real.so.0"

# Linking against the real lib would record its SONAME (libpipewire-0.3.so.0) as
# DT_NEEDED, i.e. the wrapper itself. Link against an empty stub that carries the
# -real SONAME instead; at runtime the symlink above provides the real library.
echo 'void pw_camera_filter_stub(void){}' > stub/stub.c
gcc -shared -fPIC -o stub/libpipewire-0.3-real.so.0 -Wl,-soname,libpipewire-0.3-real.so.0 stub/stub.c

# shellcheck disable=SC2046
gcc -shared -fPIC -O2 -Wall -Wextra -Wno-unused-parameter \
  -o "$PREFIX/lib/libpipewire-0.3.so.0" -Wl,-soname,libpipewire-0.3.so.0 \
  $(pkg-config --cflags libpipewire-0.3) pw-camera-filter.c \
  -Wl,--no-as-needed -Lstub -l:libpipewire-0.3-real.so.0 -ldl

readelf -d "$PREFIX/lib/libpipewire-0.3.so.0" | grep -E 'NEEDED|SONAME'
