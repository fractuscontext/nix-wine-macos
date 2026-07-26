# SPDX-FileCopyrightText: 2026 Claire Tam <claire2026t@posteo.net>
#
# SPDX-License-Identifier: GPL-3.0-only

{
  inputs = {
    nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?shallow=1&ref=nixos-unstable";
    nixpkgs-darwin.url = "git+https://github.com/NixOS/nixpkgs?shallow=1&ref=nixpkgs-26.05-darwin";

    mac-bundler = {
      url = "github:fractuscontext/nix-dylibbundler";
      inputs.nixpkgs.follows = "nixpkgs-darwin";
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-darwin,
      mac-bundler,
      git-hooks,
      self,
    }:
    let
      # We added linux architectures so GitHub's ubuntu-latest runners
      # can evaluate the flake and run the 'wine-fetch' cronjob.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # Expose the hooks as flake checks so `nix flake check` works naturally
      checks = forAllSystems (
        system:
        let
          buildPkgs = import nixpkgs { inherit system; };
        in
        {
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixfmt.enable = true;

              actionlint.enable = true;

              rumdl = {
                enable = true;
                name = "Markdown Lint Check (rumdl)";
                entry = "${buildPkgs.rumdl}/bin/rumdl check";
                types = [ "markdown" ];
                pass_filenames = false;
              };

              reuse = {
                enable = true;
                name = "SPDX License Check";
                entry = "${buildPkgs.reuse}/bin/reuse lint";
                pass_filenames = false;
              };
            };
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          buildPkgs = import nixpkgs { inherit system; };
          targetPkgs = import nixpkgs-darwin { system = "x86_64-darwin"; };
          isDarwin = buildPkgs.stdenv.isDarwin;

          pre-commit-check = self.checks.${system}.pre-commit-check;

          sourcesFile = ./_sources/generated.nix;
          hasSources = builtins.pathExists sourcesFile;
          sources = if hasSources then buildPkgs.callPackage sourcesFile { } else { };

          wine-fetch = buildPkgs.writeShellScriptBin "wine-fetch" ''
            set -euo pipefail
            echo "[*] Updating Wine/CrossOver pins using nvfetcher..."
            ${buildPkgs.nvfetcher}/bin/nvfetcher -c nvfetcher.toml
            echo "[*] Done! Remember to exit and re-enter your shell to load the new paths."
          '';

          # Script 2: Extract specific source to a local directory
          wine-extract = buildPkgs.writeShellScriptBin "wine-extract" ''
            set -euo pipefail

            if [ $# -lt 1 ]; then
              echo "Usage: wine-extract <crossover|master|stable> [target-dir]"
              exit 1
            fi

            FLAVOUR=$1
            TARGET_DIR=''${2:-sources/wine}

            case "$FLAVOUR" in
              crossover)
                SRC="${if hasSources then sources."crossover-source".src else ""}"
                VERSION="${if hasSources then sources."crossover-source".version else ""}"
                PREFIX="cx"
                ;;
              master)
                SRC="${if hasSources then sources."wine-master".src else ""}"
                VERSION="${if hasSources then sources."wine-master".version else ""}"
                PREFIX="master"
                ;;
              stable)
                SRC="${if hasSources then sources."wine-stable".src else ""}"
                VERSION="${if hasSources then sources."wine-stable".version else ""}"
                PREFIX="stable"
                ;;
              *)
                echo "Error: Unknown flavour '$FLAVOUR'."
                exit 1
                ;;
            esac

            if [ -z "$SRC" ]; then
              echo "Error: Source not found. You must run 'wine-fetch' first."
              exit 1
            fi

            echo "[*] Extracting $FLAVOUR ($VERSION) from Nix store to $TARGET_DIR..."

            rm -rf "$TARGET_DIR"
            mkdir -p "$(dirname "$TARGET_DIR")"

            if [ -d "$SRC" ]; then
              cp -R "$SRC" "$TARGET_DIR"
              chmod -R +w "$TARGET_DIR"
            elif [ -f "$SRC" ]; then
              TMP_EXTRACT=$(mktemp -d)
              ${buildPkgs.gnutar}/bin/tar -I ${buildPkgs.pigz}/bin/pigz -xf "$SRC" -C "$TMP_EXTRACT" sources/wine
              mv "$TMP_EXTRACT/sources/wine" "$TARGET_DIR"
              rm -rf "$TMP_EXTRACT"
            fi

            echo "$PREFIX-$VERSION" > "$TARGET_DIR/WINE_FLAVOUR"
            echo "[*] Finished extracting to $TARGET_DIR"
          '';

          # Script 3: The actual macOS build script
          # (We only evaluate this if we are actually on macOS, avoiding cross-OS evaluation errors)
          buildWowScript =
            if isDarwin then
              (import ./scripts/build-macos.nix {
                inherit buildPkgs targetPkgs mac-bundler;
                srcDir = "sources/wine";
                installDir = "output/wow64";
              })
            else
              buildPkgs.hello;

        in
        {
          default = buildPkgs.mkShell {
            name = "wow64-dev-env";

            # We load the basic tools on all OSs, but buildWowScript only on Darwin
            packages = [
              buildPkgs.nvfetcher
              wine-fetch
              wine-extract
            ]
            ++ buildPkgs.lib.optionals isDarwin [ buildWowScript ];

            shellHook = ''
              ${pre-commit-check.shellHook}
              echo "🍷 Loaded Wow64 build environment"

              if [ "${if isDarwin then "true" else "false"}" = "false" ]; then
                echo "Notice: You are on Linux. Only 'wine-fetch' is available here."
              else
                echo "Standard Usage:"
                echo "  wine-fetch"
                echo "  wine-extract crossover"
                echo "  build-macos all"
              fi
            '';
          };
        }
      );
    };
}
