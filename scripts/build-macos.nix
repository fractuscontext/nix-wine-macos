# SPDX-FileCopyrightText: 2026 Claire Tam <claire2026t@posteo.net>
#
# SPDX-License-Identifier: GPL-3.0-only

{
  buildPkgs,
  targetPkgs,
  mac-bundler,
  srcDir ? "sources/wine",
  installDir ? "output/wow64",
  scriptName ? "build-macos",
}:

let
  dxvkPrecompiled = buildPkgs.fetchzip {
    url = "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz";
    sha256 = "sha256-Ckrb/7B3+COEfu3iaqsXK1q0L9KbwIsUmEegSNbiznQ=";
  };

  baseDeps = with targetPkgs; [
    freetype
    libpng
    zlib
    gnutls
    lcms2
    SDL2
    ffmpeg
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    glib
    pcre2
    libffi
    vulkan-loader
    moltenvk
  ];

  pluginDeps = with targetPkgs; [
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-libav
    gmp
    p11-kit
    bzip2
    libidn2
    libtasn1
  ];

  bundleRoots = baseDeps ++ pluginDeps;
in
buildPkgs.writeShellScriptBin scriptName ''
  set -euo pipefail

  source ${buildPkgs.stdenv}/setup

  COMMAND="''${1:-all}"
  SRC_DIR="''${2:-${srcDir}}"
  INSTALL_DIR="''${3:-${installDir}}"

  if [[ "$SRC_DIR" != /* ]]; then SRC_DIR="$PWD/$SRC_DIR"; fi
  if [[ "$INSTALL_DIR" != /* ]]; then INSTALL_DIR="$PWD/$INSTALL_DIR"; fi

  ulimit -n 4096 || true
  ulimit -u 2048 || true

  export xcrun_log=1
  export xcrun_verbose=1
  export xcrun_nocache=1

  export PATH="${
    buildPkgs.lib.makeBinPath (
      with buildPkgs;
      [
        coreutils
        stdenv.cc
        flex
        bison
        pkg-config
        gnumake
        gettext
        darwin.cctools
        gawk
        llvmPackages.bintools-unwrapped
        llvmPackages.lld
      ]
    )
  }:$PATH"

  export MACOSX_DEPLOYMENT_TARGET="14.0"

  export SDKROOT="${targetPkgs.apple-sdk_14}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

  export PKG_CONFIG_PATH="${
    targetPkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" baseDeps
  }:''${PKG_CONFIG_PATH:-}"

  export CFLAGS="\
    -target x86_64-apple-darwin \
    -mmacosx-version-min=14.0 \
    -isysroot $SDKROOT"

  export LDFLAGS="\
    -target x86_64-apple-darwin \
    -mmacosx-version-min=14.0 \
    -L${targetPkgs.moltenvk}/lib \
    -L${targetPkgs.vulkan-loader}/lib \
    -isysroot $SDKROOT \
    -F$SDKROOT/System/Library/Frameworks"

  export CCACHE_DIR="$PWD/.ccache"

  # Base directory for relative path rewrites to maximize cache hits
  export CCACHE_BASEDIR="$SRC_DIR"
  export CCACHE_NOHASHDIR=1
  export CCACHE_COMPILERCHECK="string:${buildPkgs.llvmPackages.clang-unwrapped.outPath}"
  export CCACHE_MAXSIZE="5G"
  export PATH="$CCACHE_DIR/bin:$PATH"

  rm -r "$CCACHE_DIR/bin" 2>/dev/null || true
  mkdir -p "$CCACHE_DIR/bin"

  mk_wrapper() {
    local bin_name=$1
    shift
    {
      echo '#!/usr/bin/env bash'
      echo -n "exec ${buildPkgs.ccache}/bin/ccache "
      for arg in "$@"; do
        printf '%q ' "$arg"
      done
      echo '"$@"'
    } > "$CCACHE_DIR/bin/$bin_name"
    chmod +x "$CCACHE_DIR/bin/$bin_name"
  }

  mk_wrapper clang   "${buildPkgs.llvmPackages.clang-unwrapped}/bin/clang" -v
  mk_wrapper clang++ "${buildPkgs.llvmPackages.clang-unwrapped}/bin/clang++" -v
  mk_wrapper cc      "${buildPkgs.llvmPackages.clang-unwrapped}/bin/clang" -v
  mk_wrapper c++     "${buildPkgs.llvmPackages.clang-unwrapped}/bin/clang++" -v

  do_configure() {
    echo "Configuring Wow64 in $SRC_DIR..."
    pushd "$SRC_DIR" >/dev/null || { echo "Error: Source dir $SRC_DIR not found"; exit 1; }

    ${buildPkgs.gnumake}/bin/make clean || true

    CC="clang" CXX="clang++" \
    i386_CC="clang" \
    i386_CXX="clang++" \
    i386_CFLAGS="-march=nehalem -O2" \
    i386_CXXFLAGS="-march=nehalem -O2" \
    x86_64_CC="clang" \
    x86_64_CXX="clang++" \
    x86_64_CFLAGS="-march=x86-64-v2 -mtune=nehalem -O2" \
    x86_64_CXXFLAGS="-march=x86-64-v2 -mtune=nehalem -O2" \
    ./configure \
      --build=x86_64-apple-darwin \
      --enable-archs=x86_64,i386 \
      --disable-winedbg \
      --disable-tests \
      --disable-winebth_sys \
      --with-coreaudio \
      --with-ffmpeg \
      --with-freetype \
      --with-gettext \
      --without-gettextpo \
      --with-gnutls \
      --without-gssapi \
      --with-gstreamer \
      --without-inotify \
      --with-sdl \
      --with-vulkan \
      --with-pthread \
      --without-x \
      --without-wayland \
      --without-netapi \
      --without-krb5 \
      --without-alsa \
      --without-oss \
      --without-pulse \
      --without-sane \
      --without-gphoto \
      --without-dbus \
      --without-udev \
      --without-v4l2 \
      --without-pcsclite \
      --without-cups \
      --without-usb \
      --without-capi \
      --without-pcap \
      --without-unwind \
      --without-opencl \
      --disable-win16 \
      --without-fontconfig \
      --without-hwloc

    popd >/dev/null
  }

  do_make() {
    echo "Compiling in $SRC_DIR..."
    pushd "$SRC_DIR" >/dev/null || exit 1
    JOBS=$(${buildPkgs.coreutils}/bin/nproc 2>/dev/null || echo 4)
    ${buildPkgs.gnumake}/bin/make -j"''${JOBS}"
    popd >/dev/null
  }

  do_install() {
    echo "Installing to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    pushd "$SRC_DIR" >/dev/null || exit 1
    ${buildPkgs.gnumake}/bin/make install DESTDIR="$INSTALL_DIR"
    popd >/dev/null
  }

  do_install_dxmt() {
    echo "Installing DXMT/DXVK binaries from ${dxvkPrecompiled}..."
    local WINE_LIB_DIR="$INSTALL_DIR/usr/local/lib/wine"

    if [ ! -d "$WINE_LIB_DIR/x86_64-unix" ]; then
      echo "Error: Wine lib dir not found. Run 'install' phase first."
      exit 1
    fi

    # Replace Wine's builtin DLLs & Unix SO with DXMT's equivalents
    # cp -f is used to forcibly overwrite the stub files created by Wine

    echo "-> Copying x86_64-unix binaries..."
    cp -f "${dxvkPrecompiled}/x86_64-unix/winemetal.so" "$WINE_LIB_DIR/x86_64-unix/"

    echo "-> Copying x86_64-windows binaries..."
    cp -f "${dxvkPrecompiled}/x86_64-windows/"*.dll "$WINE_LIB_DIR/x86_64-windows/"

    echo "-> Copying i386-windows binaries..."
    cp -f "${dxvkPrecompiled}/i386-windows/"*.dll "$WINE_LIB_DIR/i386-windows/"

    echo "DXMT installation completed."
  }

  do_bundle() {
    echo "Bundling external runtime dependencies natively using BFS..."
    UNIX_DIR="$INSTALL_DIR/usr/local/lib/wine/x86_64-unix"
    if [ ! -d "$UNIX_DIR" ]; then
      echo "Error: $UNIX_DIR not found. Run install phase first."
      exit 1
    fi

    ${mac-bundler.lib.bundleLibs {
      pkgs = targetPkgs;
      targetPackages = bundleRoots;
      outPath = "\"$UNIX_DIR\"";
      quiet = false;
    }}

    ln -sfn libMoltenVK.dylib "$UNIX_DIR/libvulkan.1.dylib"
  }

  case "$COMMAND" in
    configure)    do_configure ;;
    make)         do_make ;;
    install)      do_install ;;
    install-dxmt) do_install_dxmt ;;
    bundle)       do_bundle ;;
    all)
      do_configure
      do_make
      do_install
      do_install_dxmt
      do_bundle
      echo "Build pipeline completed successfully."
      ;;
    *)
      echo "Usage: ${scriptName} [command] [source_dir] [install_dir]"
      echo "Commands: configure, make, install, install-dxmt, bundle, all"
      exit 1
      ;;
  esac
''
