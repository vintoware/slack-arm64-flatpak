#!/bin/sh
# Build the pw-camera-filter wrapper (see pw-camera-filter.c). Runs in the flatpak
# build sandbox (org.gnome.Sdk); installs ${PREFIX:-/app}/lib/libpipewire-0.3.so.0.
#
# The wrapper's DT_NEEDED must be the runtime's real libpipewire by ABSOLUTE path:
# inside flatpak, /app/lib is only reachable through ld.so.cache, which indexes
# SONAMEs, so a renamed copy/symlink (libpipewire-0.3-real.so.0) is never found.
# A DT_NEEDED entry containing '/' is loaded as a path.
set -eu
PREFIX="${PREFIX:-/app}"
REAL="/usr/lib/$(gcc -print-multiarch)/libpipewire-0.3.so.0"
[ -e "$REAL" ] || { echo "real libpipewire not found at $REAL" >&2; exit 1; }

# Linking against $REAL would record its SONAME (libpipewire-0.3.so.0, i.e. the
# wrapper itself). Link against an empty stub whose SONAME is the absolute path.
mkdir -p "$PREFIX/lib" stub
echo 'void pw_camera_filter_stub(void){}' > stub/stub.c
gcc -shared -fPIC -o stub/libreal.so -Wl,-soname,"$REAL" stub/stub.c

# shellcheck disable=SC2046
gcc -shared -fPIC -O2 -Wall -Wextra -Wno-unused-parameter \
  -DREAL_LIBPIPEWIRE="\"$REAL\"" \
  -o "$PREFIX/lib/libpipewire-0.3.so.0" -Wl,-soname,libpipewire-0.3.so.0 \
  $(pkg-config --cflags libpipewire-0.3) pw-camera-filter.c \
  -Wl,--no-as-needed stub/libreal.so -ldl

readelf -d "$PREFIX/lib/libpipewire-0.3.so.0" | grep -E 'NEEDED|SONAME'
readelf -d "$PREFIX/lib/libpipewire-0.3.so.0" | grep -q "NEEDED.*\[$REAL\]" \
  || { echo "wrapper does not depend on $REAL by path" >&2; exit 1; }
