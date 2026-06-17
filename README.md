# Safer, Reproducible Wine Build for macOS

Similar to [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds), but safer and more transparent.

Most community builds are manually uploaded, meaning a compromised machine or broken Xcode version produces an undetectable supply chain risk.

This build is fully described by `flake.nix` - the toolchain, flags, dependencies, and bundling steps are all auditable and pinned to a  specific nixpkgs commit.

If your system flags a binary, you don't have to trust my word, you can audit the Nix flake, compile it yourself from scratch, and verify the build hashes locally to definitively prove it's a compiler heuristic and not a compromised artifact.

## How to Build

See [`flake.nix`](./flake.nix) for the exact build steps and dependencies.

### Standard Build (Using CrossOver sources)

Using Nix, run the following commands in order:

```bash
nix develop --command extract-wine && \
nix develop ".#default" --system x86_64-darwin --command "configure-wow64" && \
nix develop ".#default" --system x86_64-darwin --command "compile-wow64" && \
nix develop ".#default" --system x86_64-darwin --command "install-wow64" && \
nix develop ".#default" --system x86_64-darwin --command "bundle-wow64"
```

### Building with Custom Source Code

If you want to compile a specific version of Wine or use your own fork, inject it before configuring:

```bash
# Wipe the default extracted sources first
rm -rf sources

# Put your preferred source tree into sources/wine
# In this example, we are using wine 11.11
git clone --depth 1 --branch "wine-11.11" --single-branch https://gitlab.winehq.org/wine/wine.git sources/wine

# Change the configuration flags in flake.nix if needed.
# Finally, run configure-wow64, compile-wow64, install-wow64, and bundle-wow64 as normal.
```

## Debugging

### Compilation & Build Issues

#### Space/Path Issues During Install

```text
error: folder/output/wow64/usr/local/lib/wine/x86_64-windows: No such file or directory
make: *** [Makefile:217149: install] Error 1
```

`make install` breaks if the working directory path contains spaces (e.g., `untitled folder`). Rename it to something like `untitled_folder` and rerun.

#### Verifying Cross-Compiler & ccache Config

After configuring, verify that `ccache` is correctly wired into the PE cross-compilers:

```bash
grep -iE 'x86_64_CC|i386_CC' sources/wine/config.log
```

*Expected output:*

```cmake
i386_CC='ccache i686-w64-mingw32-gcc'
x86_64_CC='ccache x86_64-w64-mingw32-gcc'
```

`ccache` is passed as an explicit argv rather than a `PATH` symlink to avoid macOS refusing to execute symlinked binaries under `winebuild` (`EPERM`). Empty `ac_cv_*crosscc_c99` fields are normal. If the `ccache` prefix is missing, wipe the config cache and reconfigure.

Note: `i386_CC` and `x86_64_CC` are Wine's per-arch precious variables. If a future Wine version changes how it derives the cross-compiler from `-b <target>`, PE compilation may silently bypass `ccache`.

### Runtime error

#### Msync

```bash
WINEMSYNC=1 WINEDEBUG="+msync" ./output/wow64/usr/local/bin/wine winecfg
# Expected output: msync: up and running.
```

#### `kernel32.dll` panic (GStreamer Deadlock)

```text
wine: could not load kernel32.dll, status c0000135
```

To isolate whether GStreamer is sabotaging prefix initialisation:

```bash
# Remove the broken prefix
rm -rf ~/.wine
# Disable GStreamer entirely during boot
WINEDLLOVERRIDES="winegstreamer=d" ./output/wow64/usr/local/bin/wine clock
```

Run clock again; If it open, that means GStreamer's dependencies are either missing from the bundle or deadlocking via host library conflicts, see [WineHQ #51086](https://bugs.winehq.org/show_bug.cgi?id=51086).

#### Missing or Broken Dylibs

```bash
# Test if a dylib loads cleanly without Wine overhead
arch -x86_64 python3 -c "import ctypes; ctypes.cdll.LoadLibrary('./libgnutls.dylib')"
# Inspect dylib linkage and relative loader paths
otool -L output/wow64/usr/local/lib/wine/x86_64-unix/avicap32.so
```

A silent exit in Python means it loaded correctly. An `OSError` indicates exactly what dependency is missing or incorrectly linked.

### `winegcc` / `winebuild` Errors

Always enter the Nix shell first before running failing compile commands directly. Otherwise, the host macOS `ld`/`clang` gets picked up, and the error will mislead you (e.g., `clang: error: no such file or directory: 'libgcc.a'` or `invalid linker name '-fuse-ld=lld'`).

```bash
# Enter the shell using:
nix develop ".#default" --system x86_64-darwin --command "zsh"
# Inside the hermetic shell:
tools/winegcc/winegcc -o dlls/atmlib/x86_64-windows/atmlib.dll \
  --wine-objdir . -b x86_64-w64-mingw32 -Wl,--wine-builtin -shared \
  dlls/atmlib/atmlib.spec -Wb,--prefer-native dlls/atmlib/x86_64-windows/main.o \
  dlls/winecrt0/x86_64-windows/libwinecrt0.a dlls/ucrtbase/x86_64-windows/libucrtbase.a \
  dlls/kernel32/x86_64-windows/libkernel32.a dlls/ntdll/x86_64-windows/libntdll.a
```

### Finding Nix Packages

```bash
temp_pkg="angle" && nix shell "nixpkgs#legacyPackages.x86_64-darwin.$temp_pkg" -c bash -c "cd \$(nix eval --raw nixpkgs#legacyPackages.x86_64-darwin.$temp_pkg.outPath) && exec bash"
```

## Testing DXMT & MoltenVK

### Prerequisites

- Download a DXMT artifact from [3Shain/dxmt Actions](https://github.com/3Shain/dxmt/actions) (latest passing run → `dxmt-<hash>` zip).
- Download the [DxCapsViewer](https://github.com/microsoft/DxCapsViewer) release `.exe` for testing.

### Testing MoltenVK

```bash
env MVK_CONFIG_LOG_LEVEL=3 /path_to/wine /path_to/dxcapsviewer.exe
```

Expected output if MoltenVK is configured correctly, which should be the case by default:

```text
[mvk-info] MoltenVK version 1.4.1, supporting Vulkan version 1.4.341.
  The following 153 Vulkan extensions are supported:
  VK_KHR_16bit_storage v1
  ...
  VK_NV_fragment_shader_barycentric v1
[mvk-info] GPU device:
  model: Apple M2
  type: Integrated
  vendorID: 0x106b
  ...
```

### Installing DXMT

*(As of June 2026, upstream DXMT is built with `wine_builtin_dll=true` by default. PE DLLs go into the Wine tree; only `winemetal.dll` is required in the prefix.)*

```bash
# Download dependencies if needed
curl -L -o dxcapsviewer.exe https://github.com/microsoft/DxCapsViewer/releases/download/feb2022/dxcapsviewer.exe
curl -L -o dxmt.zip https://github.com/3Shain/dxmt/actions/runs/27461696379/artifacts/7609141308

DXMT="/path/to/dxmt-artifact"
WINE_ROOT="./output/wow64/usr/local/lib/wine"
PREFIX="$HOME/.wine"

# Unix side linkage
cp "$DXMT/x86_64-unix/winemetal.so" "$WINE_ROOT/x86_64-unix/winemetal.so"

# PE side — 64-bit (Builtins: injected directly into Wine tree)
cp "$DXMT/x86_64-windows/winemetal.dll" "$WINE_ROOT/x86_64-windows/winemetal.dll"
cp "$DXMT/x86_64-windows/d3d11.dll"     "$WINE_ROOT/x86_64-windows/d3d11.dll"
cp "$DXMT/x86_64-windows/dxgi.dll"      "$WINE_ROOT/x86_64-windows/dxgi.dll"
cp "$DXMT/x86_64-windows/d3d10core.dll" "$WINE_ROOT/x86_64-windows/d3d10core.dll"

# PE side — 32-bit (Builtins)
cp "$DXMT/i386-windows/winemetal.dll"   "$WINE_ROOT/i386-windows/winemetal.dll"
cp "$DXMT/i386-windows/d3d11.dll"       "$WINE_ROOT/i386-windows/d3d11.dll"
cp "$DXMT/i386-windows/dxgi.dll"        "$WINE_ROOT/i386-windows/dxgi.dll"
cp "$DXMT/i386-windows/d3d10core.dll"   "$WINE_ROOT/i386-windows/d3d10core.dll"
```

### Prefix Notes for DXMT

- **Fresh Prefix:** `winemetal.dll` is picked up from the Wine tree automatically upon creation.
- **Existing Prefix:** `winemetal.dll` will be absent from `system32`/`syswow64`, and stale files may shadow the builtins. You must manually inject it and clean the stale files:

```bash
# winemetal.dll MUST exist in prefix targets 
cp "$DXMT/x86_64-windows/winemetal.dll" "$PREFIX/drive_c/windows/system32/winemetal.dll"
cp "$DXMT/i386-windows/winemetal.dll"   "$PREFIX/drive_c/windows/syswow64/winemetal.dll"

# Remove stale DXMT/DXVK DLLs that shadow the new builtins
rm -f "$PREFIX/drive_c/windows/system32/"{d3d11,dxgi,d3d10core,d3d9}.dll
rm -f "$PREFIX/drive_c/windows/syswow64/"{d3d11,dxgi,d3d10core,d3d9}.dll
```

> [!WARN]
> Do not set `dxgi`, `d3d11`, or `d3d10core` as `native` overrides in `winecfg`. Because `wine_builtin_dll=true` is used, they are already registered as builtins. Re-run the copy steps after every `install-wow64` run, as the install target will wipe your DXMT overrides.

### Verifying the DXMT-macOS Bridge

DXMT's unix library (`winemetal.so`) communicates with `winemac.drv` via a `macdrv_functions` struct exported from `winemac.so`. Confirm it successfully compiled into your build:

```bash
nm ./output/wow64/usr/local/lib/wine/x86_64-unix/winemac.so | grep macdrv_functions
# Expected: 000000000006XXXX D _macdrv_functions
```

If absent, `d3dmetal.c` did not compile; verify the source exists in `dlls/winemac.drv/Makefile.in` under `SOURCES`.

### Running with DXMT

```bash
WINE="./output/wow64/usr/local/bin/wine"
export WINEPREFIX="$HOME/.wine"
export WINEDLLOVERRIDES="dxgi,d3d11,d3d10core=b"
export WINEDEBUG=+loaddll
export MTL_HUD_ENABLED=1

"$WINE" /path/to/dxcapsviewer.exe 2>&1 | grep -iE "err:module|winemetal|d3d11|dxgi"
```

A successful installation produces zero `not found` errors. Upon opening DxCapsViewer, verify your Apple Silicon GPU is listed in the **Direct3D 11** tab with feature levels **11.0–11.4** and **10.0–10.1**. *(Note: `dxdiag` or D3D9 operations will correctly fallback to standard `wined3d`, logging `wined3d_guess_card_vendor "Apple"`. This is expected).*

## Variants

### Xcode + Clang Only (`xcode_old.nix`)

An older alternative predating the MinGW switch. Uses Xcode's system clang for both Unix and PE compilation. Not kept in sync with flake.nix and missing several features added since (GStreamer, FFmpeg, etc.). Kept for reference only.

```bash
cp xcode_old.nix flake.nix
```
