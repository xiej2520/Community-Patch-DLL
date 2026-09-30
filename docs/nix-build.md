# Linux build and deployment

This repository can build the Civilization V game-core DLL on an x86-64
Linux host. The output is a **32-bit Windows PE DLL**, intended to be loaded by
the Windows build of Civilization V running through Steam Proton/Wine. This
does not produce a native Linux `.so` and does not replace the native Linux
client's game core.

The supported build uses the original Visual C++ 2008 SP1 compiler and linker
under Wine. This preserves the VC9 ABI expected by Civilization V and by the
prebuilt SDK libraries. A Clang/lld backend is available for comparison, but
the deployed release artifact should use the MSVC backend unless a separate
compatibility test has been completed.

## Prerequisites

- x86-64 Linux;
- Nix with flakes enabled;
- network access for the first toolchain evaluation;
- a checkout of this repository;
- Civilization V installed through Steam, normally using Proton.

Run build commands from the repository root. The flake supplies Python, Wine,
the VC9 compiler and linker, the Windows SDK, LLVM, and the development tools;
do not install a different MinGW C++ toolchain for this build.

## Quick start

Set the two Civilization V paths once, either by editing the defaults at the top
of `deploy-vp.sh` or by exporting them (see
[Deploy to a Proton installation](#deploy-to-a-proton-installation)):

```sh
export CIV5_USER_DIR=".../compatdata/8930/pfx/drive_c/users/steamuser/Documents/My Games/Sid Meier's Civilization 5"
export CIV5_GAME_DIR=".../steamapps/common/Sid Meier's Civilization V"
```

Then, from the repository root:

```sh
nix develop                                    # shell with vp-build, Wine, VC9 and the SDK

VP_FAST_BUILD=1 ASSUME_YES=1 ./deploy-vp.sh    # test build without /GL and /LTCG (about 1 minute), then install
ASSUME_YES=1 ./deploy-vp.sh                    # full Release build (about 4 minutes), then install
VP_SKIP_BUILD=1 ASSUME_YES=1 ./deploy-vp.sh    # only Lua/SQL/XML changed: reinstall the mods, reuse the last DLL
```

Use the fast build while testing changes and the full Release build for any DLL
that will be kept or shared. Both write `BuildOutput/Release/`, so
`VP_SKIP_BUILD=1` reinstalls whichever was built last; `build-info.json` records
the flags (a full Release build lists `/GL`).

To build without installing, run `vp-build` in the same shell:

```sh
vp-build --config release --fast    # BuildOutput/Release, fast
vp-build --config release           # BuildOutput/Release, full whole-program optimization
vp-build --config debug             # BuildOutput/Debug
```

The first run downloads and extracts the legacy toolchain into the Nix store and
creates a Wine prefix in `~/.cache/vp-wine-prefix`; later runs reuse both. After
deploying, start Civilization V through Mods, enable the components, and check
`Logs/Database.log` and `Lua.log` (see the Validation section of `AGENTS.md`).

## Build with the supported backend

Enter the reproducible development shell:

```sh
nix develop
```

Build Debug and Release artifacts directly into the checkout:

```sh
vp-build --backend msvc --config debug
vp-build --backend msvc --config release
```

The results are:

```text
BuildOutput/Debug/CvGameCore_Expansion2.dll
BuildOutput/Debug/CvGameCore_Expansion2.pdb
BuildOutput/Debug/build-info.json
BuildOutput/Release/CvGameCore_Expansion2.dll
BuildOutput/Release/CvGameCore_Expansion2.pdb
BuildOutput/Release/build-info.json
```

For a clean Nix artifact, use the package targets instead:

```sh
nix build .#debug
nix build .#default       # MSVC Release
nix build .#fast          # MSVC Release without /GL and /LTCG
```

The default package writes a `result` symlink to a Nix-store directory. The
fast package is useful for iteration because it retains the VC9 compiler,
headers, runtime, and Release defines while omitting whole-program
optimization; it builds in about a minute instead of about four. It is not
code-generation-equivalent to the normal Release build.

The driver also works without entering the shell:

```sh
nix run .#build -- --backend msvc --config debug
nix run .#build -- --backend msvc --config release --fast
```

Use `--jobs N` to limit the number of parallel compiler processes. The driver
reads the C++ source list from `CvGameCoreDLL_Expansion2/VoxPopuli.vcxproj`,
builds the precompiled header, compiles translation units in parallel, and
invokes the VC9 linker for the final PE32 DLL.

## What Nix provides

`flake.nix` pins nixpkgs and fetches two legacy Microsoft inputs:

- Windows SDK 7.0, including the Win32 headers, import libraries, resource
  compiler, and VC9 headers/libraries needed by the project;
- Visual C++ 2008 Express SP1, including `cl.exe`, `link.exe`, the VC9 CRT,
  and the supporting debug-PDB binaries.

Nix extracts these archives into content-addressed store paths. The compiler
and linker are then run through Wine. Outside the Nix sandbox, `vp-build` reuses
one prefix at `${XDG_CACHE_HOME:-~/.cache}/vp-wine-prefix` (about 540 MB) unless
`WINEPREFIX` is set; sandboxed package builds use a prefix in their temporary
directory. The archives are downloaded only when the corresponding Nix store
paths are absent; subsequent builds reuse the store contents. No downloaded
SDK or compiler files are copied into the repository.

The build driver records the host, compiler, linker, flags, and SHA-256 hashes
of the DLL and PDB in `build-info.json`. This makes it possible to identify
exactly which artifact was deployed when investigating a crash.

## Build directories and logs

The direct `vp-build` workflow uses persistent directories so intermediate
files and diagnostics remain available:

```text
msvc-build/<Debug|Release>/
BuildOutput/<Debug|Release>/logs/
```

The per-source logs are in `BuildOutput/<Config>/logs/`. The linker command and
its complete output are in `BuildOutput/<Config>/build.log`.

The driver currently parallelizes compilation but does not implement its own
timestamp-based incremental compiler. A repeated `vp-build` invocation may
therefore recompile translation units. Nix package builds are clean derivation
builds. The intermediate directories are ignored by version control.

Each step prints its wall time, and the build ends with a timing summary
(precompiled header, compile wall time with the slowest sources, manifest
resource, link). Set `VP_LINK_TIME=1` to also pass the linker's `/TIME` switch,
which writes per-pass timings to `build.log`.

To measure or experiment with the link alone, relink the objects of a previous
build that used the same compile flags:

```sh
VP_LINK_TIME=1 vp-build --config release --fast --link-only
vp-build --config release --fast --link-only --link-flag /OPT:NOICF
```

`--link-only` refuses to run if the objects were compiled with different flags.
`--link-flag` appends a linker option and is intended only for measurements.

## Release optimization and link time

The normal MSVC Release build follows the project's VC9 settings:

- `/MD` runtime;
- `/Ox`, `/Ob2`, and `/Zm365`-compatible optimization settings;
- `/GL` during compilation;
- `/LTCG`, `/OPT:REF`, and `/OPT:ICF` during linking.

The whole-program link is the slow part: VC9 performs code generation for the
entire DLL in a single thread during `/LTCG`. On a 16-core machine a full
Release build takes about four minutes, of which roughly 200 seconds is that
link step; a `--fast` link takes about 11 seconds. The pinned VS2008 linker does
not support the newer `/LTCG:INCREMENTAL` option, and `/INCREMENTAL` cannot be
combined with `/LTCG`. The supported way to shorten an iteration is therefore
the `fast` package, `--fast`, or `VP_FAST_BUILD=1 ./deploy-vp.sh`, followed by a
normal Release build for the artifact that will be kept or shared.

`CvWorldBuilderMapWin32.lib` and `FireWorksWin32.lib` contain `/GL` objects, so
even a `--fast` link prints "restarting link with /LTCG". That restart costs only
a few seconds. Do not replace them with the plain `.obj` archives used by the
clang build: those require CRT helpers (`__ftol3`, `__ltod3`) that VC9 does not
provide.

`link.exe` starts `mspdbsrv.exe`, which keeps running until an idle timeout of
about ten minutes. The driver therefore writes command output directly to the
log files instead of reading pipes; reading pipes to end-of-file would wait for
that server and add roughly ten minutes to every link.

Do not switch the supported build to MinGW. Its C++ ABI and standard library
are not compatible with the Civ V executable or the VC9 libraries. The
optional `clang-release` and `clang-debug` packages use `clang-cl` and
`lld-link` with a Windows target and are useful for comparison, but they are
not the canonical MSVC-code-generation artifact.

## Deploy to a Proton installation

`deploy-vp.sh` builds the normal Release package and installs the matching
mod/DLC files. Edit the two defaults near the top of the script, or override
them in the environment:

```sh
export CIV5_USER_DIR="$HOME/.local/share/Steam/steamapps/compatdata/8930/pfx/drive_c/users/steamuser/Documents/My Games/Sid Meier's Civilization 5"
export CIV5_GAME_DIR="$HOME/.local/share/Steam/steamapps/common/Sid Meier's Civilization V"
ASSUME_YES=1 ./deploy-vp.sh
```

If the DLL is already built and only the mod files or their generated
`.modinfo` hashes changed, deploy without compiling again:

```sh
VP_SKIP_BUILD=1 ASSUME_YES=1 ./deploy-vp.sh
```

This uses `BuildOutput/Release/CvGameCore_Expansion2.dll` and its matching PDB.
Override them with `VP_DLL=/path/to/CvGameCore_Expansion2.dll` and
`VP_PDB=/path/to/CvGameCore_Expansion2.pdb` when needed.

For a Windows-mounted Steam library, set the variables to the corresponding
`/mnt/.../compatdata/8930/...` paths instead. The user directory must contain
`MODS`, `Text`, and optionally `cache`; the game directory must contain
`Assets/DLC`.

The deployment script defaults to `VP_BUILD_MODE=direct`, which runs the
`vp-build` driver found on `PATH` with persistent build directories. Run it from
the Nix development shell, which provides `vp-build`:

```sh
nix develop
ASSUME_YES=1 ./deploy-vp.sh
```

Outside that shell, use `VP_BUILD_MODE=nix` (a clean `nix build` of the package)
or `VP_BUILD_MODE=auto` (direct when the toolchain is available, otherwise Nix).

A completely non-Nix invocation requires a local Wine-accessible VC9 toolchain
and Windows SDK:

```sh
VP_BUILD_MODE=direct \
VP_SDK_ROOT=/path/to/windows-sdk \
VP_MSVC_ROOT=/path/to/vc9 \
ASSUME_YES=1 ./deploy-vp.sh
```

The direct path keeps intermediates in `msvc-build/Release` and outputs in
`BuildOutput/Release`. The current driver preserves those directories and
logs, but still recompiles translation units on each invocation; it does not
pretend to provide timestamp-based incremental compilation. Use
`VP_BUILD_MODE=nix` to force the clean reproducible package build.

The deployment script then:

1. runs the direct driver, or `nix build .#default` (or `.#fast` when `VP_FAST_BUILD=1`);
2. retains the exact DLL, PDB, and build provenance under
   `CIV5_USER_DIR/vp-build-artifacts/<dll-sha256>/`;
3. installs the `(1) Community Patch`, `(2) Vox Populi`, `(3a) VP - EUI
   Compatibility Files`, and InGame Editor+ directories;
4. removes the bundled `LUA` directories from components 1 and 2;
5. copies the newly built DLL over the component-1 DLL and verifies its World
   Congress exports;
6. installs `VPUI_tips_en_us.xml`, `VPUI`, and `UI_bc1`;
7. optionally installs Squads; and
8. removes the game's `cache` directory (the default; set `CLEAR_CACHE=0` to keep it).

The script intentionally rejects `ENABLE_43_CIVS=1`: the checked-in 43-civ
component contains a different DLL and would overwrite the custom standard
DLL, including its InGame Editor World Congress bindings. A custom 43-civ
build needs to be produced and deployed separately.

To enable the optional Squads component:

```sh
ENABLE_SQUADS=1 ASSUME_YES=1 ./deploy-vp.sh
```

The script stages replacements and keeps an old installation temporarily as a
rollback backup while each directory is replaced. It validates the destination
paths before copying, so do not bypass those checks by pointing the variables
at a broad directory.

## Verifying a deployment

After deployment, compare the installed DLL with the artifact retained by the
script:

```sh
sha256sum \
  "$CIV5_USER_DIR/MODS/(1) Community Patch/CvGameCore_Expansion2.dll" \
  "$CIV5_USER_DIR/vp-build-artifacts/<dll-sha256>/CvGameCore_Expansion2.dll"
```

The two hashes must match. If the InGame Editor reports that the DLL does not
have the corresponding World Congress version, first check that Civilization V
is using the same Proton prefix named by `CIV5_USER_DIR`, then check this hash
before changing any mod files.

## Troubleshooting

- **`nix: command not found`:** install Nix or expose the host Nix client in
  `PATH`. A Nix daemon socket alone is not enough.
- **The first build is slow:** the legacy SDK and VS2008 archives are being
  fetched and extracted. Later evaluations reuse the Nix store.
- **A compile error occurs:** inspect the matching file under
  `BuildOutput/<Config>/logs/`.
- **The link fails or appears stuck:** inspect `BuildOutput/<Config>/build.log`.
  A full Release link normally takes about three and a half minutes and a
  `--fast` link about ten seconds; the timing summary at the end of the build
  shows each step. A link that takes roughly ten minutes longer than that means
  something is again waiting for `mspdbsrv.exe` (see
  [Release optimization and link time](#release-optimization-and-link-time)).
- **The game cannot see the deployed mod:** confirm that the game is running
  through Proton and that the mod was copied under that prefix's
  `drive_c/users/steamuser/Documents/.../MODS`, not only to the native Linux
  `~/.local/share/Aspyr` tree.
- **The game loads stale data:** close the game, remove the active prefix's
  `cache` directory, and redeploy.

This build produces only the DLL and PDB. Lua, SQL, XML, art, DLC, and other
mod files remain source assets and are installed by `deploy-vp.sh`.
