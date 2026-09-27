FROM ubuntu:24.04

# winbind is needed for cl.exe to talk to mspdbsrv.exe, i.e. for separate
# PDB file debug info (/Zi), see https://github.com/mstorsjo/msvc-wine/issues/6
RUN apt-get update && \
    apt-get install -y wine64 winbind python3 msitools ca-certificates && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/*

# Initialize the wine environment. Wait until the wineserver process has
# exited before closing the session, to avoid corrupting the wine prefix.
RUN $(command -v wine64 || command -v wine || false) wineboot --init && \
    while pgrep wineserver > /dev/null; do sleep 1; done

WORKDIR /opt/msvc

COPY lowercase fixinclude install.sh vsdownload.py msvctricks.cpp ./
COPY wrappers/* ./wrappers/

RUN PYTHONUNBUFFERED=1 ./vsdownload.py --accept-license --dest /opt/msvc && \
    ./install.sh /opt/msvc && \
    rm lowercase fixinclude install.sh vsdownload.py && \
    rm -rf wrappers

COPY msvcenv-native.sh tool-dispatch.sh /opt/msvc/

# Put architecture independent entry points for all the tools on PATH, so
# that the image can be used directly as a toolchain, with both `run` and
# `exec`, e.g. `podman run --rm -v "$PWD:$PWD" -w "$PWD" msvc-wine cl hello.c`.
# See tool-dispatch.sh for the details and toolchain.cmake for how to use
# this from CMake on the host.
RUN mkdir -p /opt/msvc/bin/any && \
    cd /opt/msvc/bin/any && \
    for tool in $(ls /opt/msvc/bin/*/ | grep -v '\.exe$\|\.sh$\|:$' | sort -u) wine-run msvc-wine-daemon; do \
        ln -s ../../tool-dispatch.sh $tool; \
    done
ENV PATH=/opt/msvc/bin/any:$PATH
ENV MSVC_ARCH=x64

# Install VC runtime
RUN wine wineboot && wineserver -w \
   && r=$(ls -d /opt/msvc/VC/Redist/MSVC/*/ | head -1) \
   && s=/root/.wine/drive_c/windows/system32 \
   && cp "$r"/x64/Microsoft.VC145.CRT/*.dll "$s"/ \
   && cp "$r"/debug_nonredist/x64/Microsoft.VC145.DebugCRT/*.dll "$s"/ \
   && cp /opt/msvc/kits/10/bin/*/x64/ucrt/ucrtbased.dll "$s"/
