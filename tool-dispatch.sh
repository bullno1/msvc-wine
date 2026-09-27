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

# Architecture independent tool dispatcher for the container image.
#
# The Dockerfile installs this as /opt/msvc/bin/any/<tool> for every wrapper
# in /opt/msvc/bin/<arch>/ and puts that directory on PATH, so that both
# `podman run --rm msvc-wine cl` and `podman exec <container> cl` work. The
# tool named by $0 is forwarded to the wrapper for the architecture selected
# by MSVC_ARCH (x86, x64, arm or arm64; default x64).
#
# Two extra commands are provided the same way:
#
#   wine-run <exe> [args...]  Run a Windows executable built with this
#                             toolchain, with the environment set up so that
#                             the MSVC runtime DLLs are found. Never rely on
#                             the kernel's binfmt_misc to run .exe files
#                             inside the container; a registration from the
#                             host leaks in and points at a path in the
#                             container that may not exist.
#   msvc-wine-daemon          Start a persistent wineserver and wait, for use
#                             with `podman exec` (avoids paying the wine
#                             startup cost on every tool invocation). If
#                             MSVC_WINE_IDLE_TIMEOUT is set to a number of
#                             seconds, exit after not having run any tool
#                             for that long.

MSVC_ARCH=${MSVC_ARCH:-x64}
MSVC_BIN=/opt/msvc/bin/$MSVC_ARCH
tool=$(basename "$0")
# Touched on every invocation, so that the daemon can detect idleness.
ACTIVITY=/tmp/.msvc-wine-activity

if [ ! -d "$MSVC_BIN" ]; then
    echo "$tool: unsupported MSVC_ARCH '$MSVC_ARCH'; available:" \
        $(cd /opt/msvc/bin && ls -d */ | tr -d / | grep -v '^any$') >&2
    exit 1
fi

WINE=$(command -v wine64 || command -v wine || false)
touch "$ACTIVITY"

case "$tool" in
    wine-run)
        . "$MSVC_BIN"/msvcenv.sh
        exec "$WINE" "$@"
        ;;
    msvc-wine-daemon)
        wineserver -p
        "$WINE" wineboot
        timeout=${MSVC_WINE_IDLE_TIMEOUT:-0}
        if [ "$timeout" -le 0 ]; then
            exec sleep infinity
        fi
        while true; do
            sleep 30
            last=$(stat -c %Y "$ACTIVITY")
            if [ $(( $(date +%s) - last )) -ge "$timeout" ]; then
                echo "$tool: idle for ${timeout}s, exiting" >&2
                wineserver -k
                exit 0
            fi
        done
        ;;
esac

"$MSVC_BIN/$tool" "$@"
ec=$?
touch "$ACTIVITY"
exit $ec
