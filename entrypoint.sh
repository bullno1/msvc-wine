#!/usr/bin/env bash
#
# Copyright (c) 2026 Bach Le
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

# Container entrypoint for the msvc-wine image.
#
# Puts the wrappers for the architecture selected by MSVC_ARCH (x86, x64,
# arm or arm64; default x64) on PATH and runs the given command, so that
# e.g. `podman run --rm msvc-wine cl` works. A few first arguments are
# handled specially:
#
#   wine-run <exe> [args...]  Run a Windows executable built with this
#                             toolchain, with the environment set up so
#                             that the MSVC runtime DLLs are found.
#   daemon                    Start a persistent wineserver and sleep, for
#                             use with `podman exec` (avoids paying the
#                             wine startup cost on every tool invocation).
#   <something>.exe [args...] Same as wine-run. Never rely on the kernel's
#                             binfmt_misc to run .exe files inside the
#                             container; a registration from the host leaks
#                             in and points at a path in the container that
#                             may not exist.

set -e

MSVC_ARCH=${MSVC_ARCH:-x64}
MSVC_BIN=/opt/msvc/bin/$MSVC_ARCH

if [ ! -d "$MSVC_BIN" ]; then
    echo "entrypoint: unsupported MSVC_ARCH '$MSVC_ARCH'; available:" \
        $(ls /opt/msvc/bin | grep -v '\.exe$') >&2
    exit 1
fi

export PATH=$MSVC_BIN:$PATH
WINE=$(command -v wine64 || command -v wine || false)

run_exe() {
    . "$MSVC_BIN"/msvcenv.sh
    exec "$WINE" "$@"
}

case "$1" in
    wine-run)
        shift
        run_exe "$@"
        ;;
    *.exe|*.EXE)
        # Only if it names an actual file; otherwise fall through to PATH
        # lookup, where e.g. cl.exe resolves to a wrapper script.
        if [ -f "$1" ]; then
            run_exe "$@"
        fi
        ;;
    daemon)
        wineserver -p
        "$WINE" wineboot
        exec sleep infinity
        ;;
esac

exec "$@"
