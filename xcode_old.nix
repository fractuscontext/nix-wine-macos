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

            TARBALL="$(pwd)/crossover-sources-26.1.0.tar.gz"

            if [ ! -f "$TARBALL" ]; then
              echo "Error: crossover-sources-26.1.0.tar.gz not found in $(pwd)"
              exit 1
            fi

            tar -zvxf "$TARBALL" sources/wine --overwrite
            exit 0
          '';

          configure-wow64 = pkgs.writeShellScriptBin "configure-wow64" ''
            #!/usr/bin/env bash
            set -euo pipefail

            root_dir=$(pwd)

            if [ ! -d "''${root_dir}/sources/wine" ]; then
              echo "Error: sources/wine not found. Run extract-wine first."
              exit 1
            fi

            pushd "''${root_dir}/sources/wine"

            echo "Cleaning up previous builds..."
            make clean || true

            CC="clang" CXX="clang++" ./configure \
              --enable-archs=x86_64,i386 \
              --disable-winedbg \
              --disable-tests \
              --without-x \
              --without-wayland \
              --without-alsa \
              --without-oss \
              --without-pulse \
              --without-sane \
              --without-gphoto \
              --without-dbus \
              --without-udev \
              --without-v4l2 \
              --without-inotify \
              --without-capi

            popd
            echo "Configuration complete."
            exit 0
          '';

          compile-wow64 = pkgs.writeShellScriptBin "compile-wow64" ''
            #!/usr/bin/env bash
            set -euo pipefail

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

            cp ${pkgs.vulkan-loader}/lib/libvulkan*.dylib "$UNIX_DIR/"
            cp ${pkgs.moltenvk}/lib/libMoltenVK*.dylib "$UNIX_DIR/"
            cp ${pkgs.libpng}/lib/libpng*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.lcms2}/lib/liblcms2*.dylib "$UNIX_DIR/"
            cp ${pkgs.SDL2}/lib/libSDL2*.dylib "$UNIX_DIR/"

            # Copy FreeType and its transitive dependencies.
            # Without zlib, bzip2, and brotli, dlopen() on libfreetype will 
            # silently fail, causing Wine to throw a false 'FreeType not found' error.
            cp ${pkgs.freetype}/lib/libfreetype*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.zlib}/lib/libz*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.bzip2}/lib/libbz2*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.brotli}/lib/libbrotli*.dylib "$UNIX_DIR/"

            # TLS and crypto dependencies (REMOVED libiconv, libcharset, libintl)
            cp ${pkgs.lib.getLib pkgs.gnutls}/lib/libgnutls*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.nettle}/lib/libnettle*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.nettle}/lib/libhogweed*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.gmp}/lib/libgmp*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.p11-kit}/lib/libp11-kit*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.libtasn1}/lib/libtasn1*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.libidn2}/lib/libidn2*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.libunistring}/lib/libunistring*.dylib "$UNIX_DIR/"
            cp ${pkgs.lib.getLib pkgs.libffi}/lib/libffi*.dylib "$UNIX_DIR/"

            chmod +w "$UNIX_DIR"/*.dylib

            for dylib in "$UNIX_DIR"/*.dylib; do
              NIX_DEPS=$(otool -L "$dylib" | grep "/nix/store" | awk '{print $1}')
              for dep in $NIX_DEPS; do
                DEP_NAME=$(basename "$dep")
                
                # ONLY relink if we actually copied the file into our bundle!
                if [ -f "$UNIX_DIR/$DEP_NAME" ]; then
                  install_name_tool -change "$dep" "@loader_path/$DEP_NAME" "$dylib"
                fi
              done
              
              DYLIB_NAME=$(basename "$dylib")
              install_name_tool -id "@loader_path/$DYLIB_NAME" "$dylib"
            done

            echo "Dylibs successfully bundled and safely relinked!"
            exit 0
          '';

        in
        {
          default = pkgs.mkShellNoCC {
            buildInputs = [
              extract-wine
            ]
            ++ pkgs.lib.optionals (system == "x86_64-darwin") [
              configure-wow64
              compile-wow64
              install-wow64
              bundle-wow64

              pkgs.lld
              pkgs.llvm
              pkgs.flex
              pkgs.bison
              pkgs.pkg-config
              pkgs.freetype
              pkgs.libpng
              pkgs.zlib
              pkgs.bzip2
              pkgs.moltenvk
              pkgs.vulkan-headers
              pkgs.vulkan-loader
              pkgs.macdylibbundler
              pkgs.ccache
              pkgs.gnutls
              pkgs.nettle
              pkgs.gmp
              pkgs.p11-kit
              pkgs.libtasn1
              pkgs.libidn2
              pkgs.libunistring
              pkgs.libiconv
              pkgs.gettext
              pkgs.cacert
              pkgs.lcms2
              pkgs.SDL2
              pkgs.apple-sdk_15
            ];

            shellHook = ''
              export LEX="flex"
              export BISON="bison"

              # Manually point pkg-config to the .dev outputs of our libraries
              export PKG_CONFIG_PATH="${pkgs.freetype.dev}/lib/pkgconfig:${pkgs.libpng.dev}/lib/pkgconfig:${pkgs.zlib.dev}/lib/pkgconfig:${pkgs.gnutls.dev}/lib/pkgconfig:${pkgs.lcms2.dev}/lib/pkgconfig:${pkgs.SDL2.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
              export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
              export SDKROOT="${pkgs.apple-sdk_15}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

              export CFLAGS="-I${pkgs.vulkan-headers}/include -isysroot $SDKROOT"
              export LDFLAGS="-L${pkgs.moltenvk}/lib -L${pkgs.vulkan-loader}/lib -isysroot $SDKROOT -F$SDKROOT/System/Library/Frameworks"
              export DYLD_LIBRARY_PATH="${pkgs.freetype}/lib:${pkgs.vulkan-loader}/lib:${pkgs.moltenvk}/lib:$DYLD_LIBRARY_PATH"

              export CCACHE_DIR="$(pwd)/.ccache"
              export CCACHE_BASEDIR="$(pwd)"
              export CCACHE_COMPILERCHECK=content

              echo "Hijacking compiler paths for ccache natively via Nix store..."
              mkdir -p "$CCACHE_DIR/bin"
              ln -sf "${pkgs.ccache}/bin/ccache" "$CCACHE_DIR/bin/clang"
              ln -sf "${pkgs.ccache}/bin/ccache" "$CCACHE_DIR/bin/clang++"
              ln -sf "${pkgs.ccache}/bin/ccache" "$CCACHE_DIR/bin/cc"
              ln -sf "${pkgs.ccache}/bin/ccache" "$CCACHE_DIR/bin/c++"
              export PATH="$CCACHE_DIR/bin:$PATH"

              echo "Nix environment ready!"
              echo "Self: ${self}"
              echo "Pwd: $(pwd)"
            '';
          };
        }
      );
    };
}
