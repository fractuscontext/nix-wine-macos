<!--
SPDX-FileCopyrightText: 2026 Claire Tam <claire2026t@posteo.net>

SPDX-License-Identifier: GPL-3.0-only
-->

<!-- markdownlint-disable MD013 -->
# Safer, Reproducible Wine Build for macOS

Similar to [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds), but safer and more transparent.

Most community builds are manually uploaded, meaning a compromised machine or broken Xcode version produces an undetectable supply chain risk.

## What's working

- [x] GnuTLS is working
- [x] MoltenVK is configured correctly
- [x] DXMT (v0.80) is bundled by default instead of wined3d
- [ ] OpenGL 4.2+ support (Not yet)

## How to Build

You can either 1) fetch the sources used by this repo (e.g., `crossover`, `stable`, or `master`):

```bash
# Enter the hermetic build environment
nix develop

# Fetch source pins (downloads tarballs/git commits safely into the Nix store)
wine-fetch

# Extract the specific flavor you want to build (e.g., crossover)
wine-extract crossover
```

Or 2) bring your source code if needed:

```bash
# Wipe the default extracted sources first
rm -rf sources

# Put your preferred source tree into `sources/wine`, e.g. Wine 11.11
git clone --depth 1 --branch "wine-11.11" --single-branch https://gitlab.winehq.org/wine/wine.git sources/wine
```

Then, compile using:

```bash
nix develop --command build-macos all
```

> [!TIP]
> We are using Clang here, so it will spit out x86_64 binaries even if you are building on an Apple Silicon (AArch64) machine.

Everything will then appear in `./output/wow64` and be fully portable.

## Debugging

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

### Validating Msync

```bash
WINEMSYNC=1 WINEDEBUG="+msync" ./output/wow64/usr/local/bin/wine winecfg
# Expected output: msync: up and running.
```

### `kernel32.dll` Panic (GStreamer Deadlock)

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

Run clock again; if it opens, that means GStreamer's dependencies are either missing from the bundle or deadlocking via host library conflicts. See [WineHQ #51086](https://bugs.winehq.org/show_bug.cgi?id=51086).

### Debugging GnuTLS

Run Wine with module debugging enabled to catch exactly where `dlopen` fails to load GnuTLS.

```bash
WINEDEBUG=+module ./output/wow64/usr/local/bin/wine iexplore.exe "https://google.com" 2>&1 | grep -E "(dlopen|gnutls)"
```

*Look for the following error in the output:*

```text
0244:err:winediag:process_attach Failed to load libgnutls, secure connections will not be available.
```

Check the runtime directory to see if the libraries are present and correctly linked to Wine's crypto modules.

```bash
# 1. Move into the runtime directory
cd ./output/wow64/usr/local/lib/wine/x86_64-unix

# 2. Check what GnuTLS files actually exist in the bundle
ls -l | grep gnutls

# 3. Check Wine's core crypto libraries for GnuTLS linkage
# (Note: Use these rather than avicap32.so, which is primarily for webcams)
otool -L bcrypt.so | grep gnutls
otool -L crypt32.so | grep gnutls

# 4. Inspect standard dylib linkage and relative loader paths
otool -L avicap32.so
```

To test if macOS `dyld` can successfully load the library without Wine's overhead, we use Python's `ctypes`.

**Important:** Relying solely on `arch -x86_64 python3` on the host is incorrect. You must load a Nix shell with the proper architecture specifics and the `nixpkgs-26.05-darwin` channel.

```bash
# 1. Enter the appropriate Nix shell with x86_64 architecture and the correct channel
nix shell --system x86_64-darwin nixpkgs/nixpkgs-26.05-darwin#python3

# 2. Test if the libraries load cleanly inside the Nix environment
python3 -c "import ctypes; ctypes.cdll.LoadLibrary('./libgnutls.30.dylib')" || \
python3 -c "import ctypes; ctypes.cdll.LoadLibrary('./libgnutls.dylib')"
```

### Validating MoltenVK

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

### Running with DXMT

Download the [DxCapsViewer](https://github.com/microsoft/DxCapsViewer) release `.exe` for testing.

```bash
WINE="./output/wow64/usr/local/bin/wine"
export WINEPREFIX="$HOME/.wine"
export WINEDLLOVERRIDES="dxgi,d3d11,d3d10core=b"
export WINEDEBUG=+loaddll
export MTL_HUD_ENABLED=1

"$WINE" /path/to/dxcapsviewer.exe 2>&1 | grep -iE "err:module|winemetal|d3d11|dxgi"
```

> [!TIP]
> DXMT 0.8 only supports DirectX 10 / 11. D3D9 operations will correctly fallback to standard `wined3d`, logging `wined3d_guess_card_vendor "Apple"`. This is expected.
