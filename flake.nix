{
  description = "CrossOver Wine Source Extractor";

  inputs = {
    nixpkgs.url = "github:Nixos/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          extract-wine = pkgs.writeShellScriptBin "extract-wine" ''
            #!/usr/bin/env bash
            set -euo pipefail

            TARBALL="$(pwd)/crossover-sources-26.2.0.tar.gz"

            if [ ! -f "$TARBALL" ]; then
              echo "Error: crossover-sources-26.2.0.tar.gz not found in $(pwd)"
              exit 1
            fi

            ${pkgs.gnutar}/bin/tar -I ${pkgs.pigz}/bin/pigz -xvf "$TARBALL" sources/wine --overwrite
            exit 0
          '';

          configure-wow64 = pkgs.writeShellScriptBin "configure-wow64" ''
            #!/usr/bin/env bash
            set -euo pipefail

            ulimit -n 4096 || true
            ulimit -u 2048 || true

            root_dir=$(pwd)

            if [ ! -d "''${root_dir}/sources/wine" ]; then
              echo "Error: sources/wine not found. Run extract-wine first."
              exit 1
            fi

            pushd "''${root_dir}/sources/wine"

            echo "Cleaning up previous builds..."
            make clean || true

            CC="clang" CXX="clang++" \
            i386_CC="i686-w64-mingw32-gcc" \
            x86_64_CC="x86_64-w64-mingw32-gcc" \
            EGL_LIBS="-lEGL -lGLESv2" \
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
              --with-opengl \
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

            popd
            echo "Configuration complete."
            exit 0
          '';

          compile-wow64 = pkgs.writeShellScriptBin "compile-wow64" ''
            #!/usr/bin/env bash
            set -euo pipefail

            ulimit -n 4096 || true
            ulimit -u 2048 || true

            root_dir=$(pwd)
            pushd "''${root_dir}/sources/wine"

            echo "Compiling (this will take a while)..."
            JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
            make -j"''${JOBS}"

            popd
            echo "Compilation complete."
            exit 0
          '';

          install-wow64 = pkgs.writeShellScriptBin "install-wow64" ''
            #!/usr/bin/env bash
            set -euo pipefail

            root_dir=$(pwd)
            pushd "''${root_dir}/sources/wine"

            echo "Redirecting output to output/wow64..."
            mkdir -p "''${root_dir}/output/wow64"
            make install DESTDIR="''${root_dir}/output/wow64"

            popd

            ccache --show-stats
            echo "Script ended successfully."
          '';

          bundle-wow64 = pkgs.writeShellScriptBin "bundle-wow64" ''
            #!/usr/bin/env bash
            set -euo pipefail

            root_dir=$(pwd)

            echo "Bundling external runtime dependencies natively..."
            UNIX_DIR="''${root_dir}/output/wow64/usr/local/lib/wine/x86_64-unix"

            if [ ! -d "$UNIX_DIR" ]; then
              echo "Error: $UNIX_DIR not found. Run install-wow64 first."
              exit 1
            fi

            # Copy matching libs without aborting when a glob matches nothing.
            # cp with an unexpanded glob would fail under set -e, so we iterate.
            copy_libs() {
              local matched=0
              local f
              for f in $1; do
                [ -e "$f" ] || continue
                cp "$f" "$UNIX_DIR/"
                matched=1
              done
              if [ "$matched" -eq 0 ]; then
                echo "  !! WARNING: no files matched: $1"
              fi
            }

            # Bypassing strict Khronos vulkan-loader to avoid VK_ERROR_INCOMPATIBLE_DRIVER (res -9).
            # Wine explicitly dlopens "libvulkan.1.dylib", so we mask MoltenVK as the loader
            # to feed Vulkan calls directly to Metal without portability flag restrictions.
            copy_libs "${pkgs.moltenvk}/lib/libMoltenVK*.dylib"
            ln -sf libMoltenVK.dylib "$UNIX_DIR/libvulkan.1.dylib"

            copy_libs "${pkgs.libpng}/lib/libpng*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.lcms2}/lib/liblcms2*.dylib"
            copy_libs "${pkgs.SDL2}/lib/libSDL2*.dylib"

            # Copy FreeType and its transitive dependencies.
            # Without zlib, bzip2, and brotli, dlopen() on libfreetype will
            # silently fail, causing Wine to throw a false 'FreeType not found' error.
            copy_libs "${pkgs.freetype}/lib/libfreetype*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.zlib}/lib/libz*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.bzip2}/lib/libbz2*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.brotli}/lib/libbrotli*.dylib"

            # TLS and crypto dependencies
            copy_libs "${pkgs.lib.getLib pkgs.gnutls}/lib/libgnutls*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.nettle}/lib/libnettle*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.nettle}/lib/libhogweed*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.gmp}/lib/libgmp*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.p11-kit}/lib/libp11-kit*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.libtasn1}/lib/libtasn1*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.libidn2}/lib/libidn2*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.libunistring}/lib/libunistring*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.libffi}/lib/libffi*.dylib"

            copy_libs "${pkgs.lib.getLib pkgs.gst_all_1.gstreamer}/lib/libgst*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.gst_all_1.gst-plugins-base}/lib/libgst*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.glib}/lib/libglib*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.glib}/lib/libgobject*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.glib}/lib/libgmodule*.dylib"

            # ANGLE: these dylibs are NOT linked against /nix/store paths.
            # They use @rpath/@loader_path among themselves, so the relink loop
            # below correctly finds zero /nix/store deps for them (awk, not grep,
            # so a zero-match does not abort under set -e).
            copy_libs "${pkgs.lib.getLib pkgs.angle}/lib/libEGL*.dylib"
            copy_libs "${pkgs.lib.getLib pkgs.angle}/lib/libGLESv2*.dylib"

            # Make everything writable. nullglob guards against an empty dir.
            shopt -s nullglob
            dylibs=( "$UNIX_DIR"/*.dylib "$UNIX_DIR"/*.so )
            shopt -u nullglob

            if [ ''${#dylibs[@]} -eq 0 ]; then
              echo "Error: no dylibs/so were bundled into $UNIX_DIR"
              exit 1
            fi

            chmod +w "''${dylibs[@]}"

            for libfile in "''${dylibs[@]}"; do
              LIB_NAME=$(basename "$libfile")
              echo "Processing: $LIB_NAME"

              # awk (not grep) so zero /nix/store matches still exits 0 under set -e.
              # ANGLE libs hit this path and legitimately produce no deps here.
              NIX_DEPS=$(otool -L "$libfile" | awk '/\/nix\/store/ {print $1}')
              for dep in $NIX_DEPS; do
                DEP_NAME=$(basename "$dep")
                if [ -f "$UNIX_DIR/$DEP_NAME" ]; then
                  echo "  -> Relinking dependency: $DEP_NAME"
                  install_name_tool -change "$dep" "@loader_path/$DEP_NAME" "$libfile"
                fi
              done

              echo "  -> Setting library ID: @loader_path/$LIB_NAME"
              install_name_tool -id "@loader_path/$LIB_NAME" "$libfile"
            done

            echo "Relinking complete!"

            # Verification pass: surface any /nix/store dep that was NOT bundled.
            # This is the silent-failure class your FreeType/zlib comment fights.
            echo "Verifying no unbundled /nix/store refs remain..."
            leftover=0
            for libfile in "''${dylibs[@]}"; do
              while IFS= read -r dep; do
                DEP_NAME=$(basename "$dep")
                if [ ! -f "$UNIX_DIR/$DEP_NAME" ]; then
                  echo "  !! $(basename "$libfile") -> MISSING bundled copy of: $dep"
                  leftover=1
                fi
              done < <(otool -L "$libfile" | awk '/\/nix\/store/ {print $1}')
            done

            if [ "$leftover" -ne 0 ]; then
              echo "WARNING: some /nix/store dependencies were not bundled (see above)."
              echo "These will fail to resolve outside the nix shell."
            else
              echo "All /nix/store dependencies accounted for."
            fi

            echo "Bundling complete."
          '';

        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              extract-wine
            ]
            ++ pkgs.lib.optionals (system == "x86_64-darwin") [
              configure-wow64
              compile-wow64
              install-wow64
              bundle-wow64

              pkgs.flex
              pkgs.bison
              pkgs.pkg-config
              pkgs.freetype
              pkgs.libpng
              pkgs.zlib
              pkgs.ccache
              pkgs.gnutls
              pkgs.gettext
              pkgs.lcms2
              pkgs.SDL2
              pkgs.apple-sdk_15
              pkgs.ffmpeg
              pkgs.gst_all_1.gstreamer
              pkgs.gst_all_1.gst-plugins-base
              pkgs.angle

              pkgs.pkgsCross.mingwW64.buildPackages.gcc
              pkgs.pkgsCross.mingwW64.buildPackages.binutils
              pkgs.pkgsCross.mingw32.buildPackages.gcc
              pkgs.pkgsCross.mingw32.buildPackages.binutils
            ];

            shellHook = ''
              export LEX="flex"
              export BISON="bison"

              export xcrun_log=1
              export xcrun_verbose=1
              export xcrun_nocache=1
              export MACOSX_DEPLOYMENT_TARGET="15.0"

              export PKG_CONFIG_PATH="${
                pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" (
                  with pkgs;
                  [
                    freetype
                    libpng
                    zlib
                    gnutls
                    lcms2
                    SDL2
                    ffmpeg
                    gst_all_1.gstreamer
                    gst_all_1.gst-plugins-base
                    angle
                    vulkan-loader
                    moltenvk
                  ]
                )
              }:$PKG_CONFIG_PATH"

              export SDKROOT="${pkgs.apple-sdk_15}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

              export CFLAGS="\
                -mmacosx-version-min=15.0 \
                -isysroot $SDKROOT \
                -I${pkgs.lib.getDev pkgs.angle}/include"
                
              export DYLD_LIBRARY_PATH="${
                pkgs.lib.makeLibraryPath (
                  with pkgs;
                  [
                    freetype
                    vulkan-loader
                    moltenvk
                    angle
                  ]
                )
              }:$DYLD_LIBRARY_PATH"

              export LDFLAGS="\
                -mmacosx-version-min=15.0 \
                -L${pkgs.moltenvk}/lib \
                -L${pkgs.vulkan-loader}/lib \
                -L${pkgs.angle}/lib \
                -isysroot $SDKROOT \
                -F$SDKROOT/System/Library/Frameworks"

              export CCACHE_DIR="$(pwd)/.ccache"
              export CCACHE_BASEDIR="$(pwd)"
              export CCACHE_COMPILERCHECK=content
              export CCACHE_MAXSIZE="5G"
              export PATH="$CCACHE_DIR/bin:$PATH"

              rm -r "$CCACHE_DIR/bin" 2>/dev/null || true
              mkdir -p "$CCACHE_DIR/bin"

              ln -sf "${pkgs.ccache}/bin/ccache" "$CCACHE_DIR/bin/clang"
              ln -sf "${pkgs.ccache}/bin/ccache" "$CCACHE_DIR/bin/clang++"
              ln -sf "${pkgs.ccache}/bin/ccache" "$CCACHE_DIR/bin/cc"
              ln -sf "${pkgs.ccache}/bin/ccache" "$CCACHE_DIR/bin/c++"

              # ===== MINGW HIJACK STARTS =====

              # MinGW compilers can't be plain ccache symlinks because winebuild
              # triggers EPERM on macOS, so we use wrapper scripts that pin the
              # keeps the cache key based on binary content, so these stay
              # consistent with the symlinked native compilers.

              mk_mingw_wrapper() {
                # $1 = wrapper name, $2 = real compiler path
                {
                  echo '#!/usr/bin/env bash'
                  echo "exec ${pkgs.ccache}/bin/ccache \"$2\" \"\$@\""
                } > "$CCACHE_DIR/bin/$1"
                chmod +x "$CCACHE_DIR/bin/$1"
              }

              mk_mingw_wrapper i686-w64-mingw32-gcc   "${pkgs.pkgsCross.mingw32.buildPackages.gcc}/bin/i686-w64-mingw32-gcc"
              mk_mingw_wrapper i686-w64-mingw32-g++   "${pkgs.pkgsCross.mingw32.buildPackages.gcc}/bin/i686-w64-mingw32-g++"
              mk_mingw_wrapper x86_64-w64-mingw32-gcc "${pkgs.pkgsCross.mingwW64.buildPackages.gcc}/bin/x86_64-w64-mingw32-gcc"
              mk_mingw_wrapper x86_64-w64-mingw32-g++ "${pkgs.pkgsCross.mingwW64.buildPackages.gcc}/bin/x86_64-w64-mingw32-g++"

              echo "Nix environment ready!"
              echo "Self: ${self}"
              echo "Pwd: $(pwd)"
            '';
          };
        }
      );
    };
}
