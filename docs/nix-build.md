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
optimization. It is not code-generation-equivalent to the normal Release
build.

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
and linker are then run through Wine with a temporary or user-selected Wine
prefix. The archives are downloaded only when the corresponding Nix store
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

## Release optimization and link time

The normal MSVC Release build follows the project's VC9 settings:

- `/MD` runtime;
- `/Ox`, `/Ob2`, and `/Zm365`-compatible optimization settings;
- `/GL` during compilation;
- `/LTCG`, `/OPT:REF`, and `/OPT:ICF` during linking.

The MSVC link step is the slow part and can take several minutes. The pinned
VS2008 linker does not support the newer `/LTCG:INCREMENTAL` option, and
`/INCREMENTAL` cannot be combined with `/LTCG`. The supported way to shorten an
iteration is therefore the `fast` package or `--fast`, followed by a normal
Release build for the artifact that will be deployed.

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

The deployment script defaults to `VP_BUILD_MODE=direct`, using the persistent
direct `vp-build` driver. To use it from a Nix development shell:

```sh
nix develop
ASSUME_YES=1 VP_BUILD_MODE=direct ./deploy-vp.sh
```

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
8. removes the Proton cache when `CLEAR_CACHE=1`.

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
  Release whole-program optimization is expected to spend several minutes in
  the linker.
- **The game cannot see the deployed mod:** confirm that the game is running
  through Proton and that the mod was copied under that prefix's
  `drive_c/users/steamuser/Documents/.../MODS`, not only to the native Linux
  `~/.local/share/Aspyr` tree.
- **The game loads stale data:** close the game, remove the active prefix's
  `cache` directory, and redeploy.

This build produces only the DLL and PDB. Lua, SQL, XML, art, DLC, and other
mod files remain source assets and are installed by `deploy-vp.sh`.
