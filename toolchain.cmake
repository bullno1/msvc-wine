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

# CMake toolchain file for using the msvc-wine container image as a
# cross compiler (and as a runner for the resulting executables) without
# installing anything on the host besides a container runtime.
#
#     cmake -S . -B build -G Ninja --toolchain /path/to/toolchain.cmake
#     cmake --build build
#     ctest --test-dir build
#
# The image has no way of knowing the host's paths or working directory, so
# this file generates small shell scripts ("shims") in the build tree, one per
# tool, which run the tool in the container with the current directory and
# the host paths bind mounted at the same locations. The wrappers in the
# image translate absolute Unix paths to the drive letter z:, which maps to
# the container's root, so this only works if the source and build trees are
# visible at identical paths inside the container.
#
# Options (set with -D on the first configure):
#
#   MSVC_WINE_IMAGE     Image name (default: msvc-wine).
#   MSVC_WINE_ARCH      Target architecture: x86, x64, arm or arm64
#                       (default: x64).
#   MSVC_WINE_RUNTIME   Container runtime executable (default: podman).
#                       docker works too, but note that with a rootful
#                       runtime, files written into the mounted directories
#                       end up owned by root.
#   MSVC_WINE_MOUNTS    Host directories to bind mount at the same path in
#                       the container (default: $HOME). The source and build
#                       directories are added automatically if not covered.
#   MSVC_WINE_RUN_ARGS  Extra arguments to `podman run` (or `podman exec`),
#                       e.g. --security-opt=label=disable on SELinux hosts.
#   MSVC_WINE_CONTAINER If set, use `podman exec` into this running
#                       container instead of starting a new one per tool
#                       invocation. Start it with e.g.
#                         podman run -d --name msvc -v "$HOME:$HOME" \
#                             msvc-wine daemon
#                       This is a lot faster for big builds and allows
#                       separate PDB files (/Zi), since mspdbsrv.exe can
#                       outlive an individual compiler invocation.
#
# Each tool invocation in the default mode starts a fresh container and a
# fresh wineserver. That means mspdbsrv.exe can't persist between compiler
# invocations, so debug info is forced to the embedded (/Z7) format. For
# this to also apply to CMake's own compiler probing, the project needs
# cmake_minimum_required(VERSION 3.25) or cmake_policy(SET CMP0141 NEW).

if(CMAKE_VERSION VERSION_LESS 3.25)
    message(FATAL_ERROR "toolchain.cmake requires CMake 3.25 or newer")
endif()

set(MSVC_WINE_IMAGE "msvc-wine" CACHE STRING "msvc-wine container image")
set(MSVC_WINE_ARCH "x64" CACHE STRING "Target architecture: x86, x64, arm or arm64")
set(MSVC_WINE_RUNTIME "podman" CACHE STRING "Container runtime (podman or docker)")
set(MSVC_WINE_MOUNTS "$ENV{HOME}" CACHE STRING "Host directories to bind mount at the same path in the container")
set(MSVC_WINE_RUN_ARGS "" CACHE STRING "Extra arguments to the container runtime's run/exec command")
set(MSVC_WINE_CONTAINER "" CACHE STRING "Name of a running container (started with `daemon`) to exec into")

set(CMAKE_SYSTEM_NAME Windows)
if(MSVC_WINE_ARCH STREQUAL "x86")
    set(CMAKE_SYSTEM_PROCESSOR X86)
    set(_msvc_wine_masm ml)
elseif(MSVC_WINE_ARCH STREQUAL "x64")
    set(CMAKE_SYSTEM_PROCESSOR AMD64)
    set(_msvc_wine_masm ml64)
elseif(MSVC_WINE_ARCH STREQUAL "arm")
    set(CMAKE_SYSTEM_PROCESSOR ARM)
    set(_msvc_wine_masm armasm)
elseif(MSVC_WINE_ARCH STREQUAL "arm64")
    set(CMAKE_SYSTEM_PROCESSOR ARM64)
    set(_msvc_wine_masm armasm64)
else()
    message(FATAL_ERROR "MSVC_WINE_ARCH must be one of x86, x64, arm, arm64 (got '${MSVC_WINE_ARCH}')")
endif()

# Make sure the source and build trees are visible inside the container.
# This file is re-read by try_compile() projects; their scratch directories
# live under the top-level build directory, so they are covered by whatever
# was added for the top-level configure.
set(_msvc_wine_mounts ${MSVC_WINE_MOUNTS})
list(FILTER _msvc_wine_mounts EXCLUDE REGEX "^$")
foreach(dir IN ITEMS "${CMAKE_SOURCE_DIR}" "${CMAKE_BINARY_DIR}")
    if(dir STREQUAL "")
        continue()
    endif()
    set(_covered FALSE)
    foreach(mount IN LISTS _msvc_wine_mounts)
        cmake_path(IS_PREFIX mount "${dir}" NORMALIZE _covered)
        if(_covered)
            break()
        endif()
    endforeach()
    if(NOT _covered)
        list(APPEND _msvc_wine_mounts "${dir}")
    endif()
endforeach()

if(MSVC_WINE_CONTAINER)
    set(_msvc_wine_cmd "${MSVC_WINE_RUNTIME} exec -i -w \"$PWD\" -e MSVC_ARCH=${MSVC_WINE_ARCH}")
else()
    set(_msvc_wine_cmd "${MSVC_WINE_RUNTIME} run --rm -i -w \"$PWD\" -e MSVC_ARCH=${MSVC_WINE_ARCH}")
    foreach(mount IN LISTS _msvc_wine_mounts)
        string(APPEND _msvc_wine_cmd " -v \"${mount}:${mount}\"")
    endforeach()
endif()
if(MSVC_WINE_RUN_ARGS)
    string(APPEND _msvc_wine_cmd " ${MSVC_WINE_RUN_ARGS}")
endif()
if(MSVC_WINE_CONTAINER)
    string(APPEND _msvc_wine_cmd " ${MSVC_WINE_CONTAINER}")
else()
    string(APPEND _msvc_wine_cmd " ${MSVC_WINE_IMAGE}")
endif()

set(_msvc_wine_shims "${CMAKE_BINARY_DIR}/msvc-wine-shims")
foreach(tool IN ITEMS cl link lib rc mt ${_msvc_wine_masm} wine-run)
    set(_shim "${_msvc_wine_shims}/${tool}")
    set(_content "#!/bin/sh
# Generated by toolchain.cmake, do not edit.
exec ${_msvc_wine_cmd} ${tool} \"$@\"
")
    set(_existing "")
    if(EXISTS "${_shim}")
        file(READ "${_shim}" _existing)
    endif()
    if(NOT _existing STREQUAL _content)
        file(WRITE "${_shim}" "${_content}")
        file(CHMOD "${_shim}" PERMISSIONS
            OWNER_READ OWNER_WRITE OWNER_EXECUTE
            GROUP_READ GROUP_EXECUTE
            WORLD_READ WORLD_EXECUTE)
    endif()
endforeach()

set(CMAKE_C_COMPILER "${_msvc_wine_shims}/cl")
set(CMAKE_CXX_COMPILER "${_msvc_wine_shims}/cl")
set(CMAKE_RC_COMPILER "${_msvc_wine_shims}/rc")
set(CMAKE_ASM_MASM_COMPILER "${_msvc_wine_shims}/${_msvc_wine_masm}")
set(CMAKE_LINKER "${_msvc_wine_shims}/link")
set(CMAKE_AR "${_msvc_wine_shims}/lib")
set(CMAKE_MT "${_msvc_wine_shims}/mt")
set(CMAKE_CROSSCOMPILING_EMULATOR "${_msvc_wine_shims}/wine-run")

if(NOT MSVC_WINE_CONTAINER AND NOT DEFINED CMAKE_MSVC_DEBUG_INFORMATION_FORMAT)
    set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT Embedded)
endif()
