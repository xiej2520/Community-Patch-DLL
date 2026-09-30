# Community Patch DLL agent guide

## Scope and project

This checkout is the source for the Civilization V Community Patch DLL and the
Vox Populi mod suite. The Community Patch supplies the shared GameCore DLL,
bug fixes, AI work, performance improvements, and modding APIs; Vox Populi adds
the larger balance and gameplay overhaul.

Before making a substantial change, read:

- `README.md` for product/component boundaries.
- `DEVELOPMENT.md` and `docs/build-toolchain.md` for building and debugging.
- `CvGameCoreDLL_Expansion2/GAMECORE_OVERVIEW.md` for architecture and the
  determinism, Lua-thread, and serialization hazards.
- `docs/db.md` for database access from Lua.

Upstream context lives at
<https://github.com/LoneGazebo/Community-Patch-DLL> and the active community,
design discussions, release threads, and modding guides live at
<https://forums.civfanatics.com/forums/community-patch-project.497/>. Treat the
checked-out source and project files as authoritative for the current revision.

## Repository map

- `CvGameCoreDLL_Expansion2/`: core game rules, AI, pathfinding, networking,
  serialization, engine interfaces, and `Lua/` bindings. Start with the class
  matching the game object (`CvGame`, `CvPlayer`, `CvCity`, `CvUnit`, etc.).
- `CvGameCoreDLLUtil/`, `CvGameDatabase/`, `CvLocalization/`,
  `CvWorldBuilderMap/`, `FirePlace/`, `ThirdPartyLibs/`: SDK support headers and
  prebuilt libraries used by the DLL. Avoid changing third-party/vendor code
  unless the task specifically requires it.
- `(1) Community Patch/`: standalone base mod, DLL, core database changes,
  Lua, mapscripts, and modding kit.
- `(2) Vox Populi/`: the gameplay/balance overhaul layered on component 1.
- `(3a) VP - EUI Compatibility Files/`: optional EUI integration.
- `(3b) 43 Civs Community Patch/`: alternate DLL packaging for larger games.
- `(4a) Squads for VP/` and `(5) Modpack Maker for VP/`: optional components.
- `UI_bc1/`, `VPUI/`, and `VPUI Text/`: UI implementations and text assets.
- `LuaCATS/`, `.luarc.json`, and `.luacheckrc`: Civ V Lua 5.1 editor/linter
  declarations and globals.
- `scripts/generate_modinfo.py`: generates `.modinfo` manifests from the
  `.civ5proj` source projects. `scripts/release.py` and the top-level release
  instruction files are maintainer release tooling, not routine validation.
- `flake.nix`, `flake.lock`, and `nix/build-vp.py`: reproducible NixOS/Linux
  MSVC-ABI cross-toolchain. See `docs/nix-build.md`.
- `.github/workflows/build_vp.yml`: canonical CI build matrix. The cppcheck
  workflow is manual and advisory (`continue-on-error`).

## Non-negotiable compatibility rules

- The DLL is 32-bit Win32 code built for the Visual C++ 2008 SP1 (`v90`) ABI.
  Keep C++ compatible with C++03/TR1 and nearby code; do not introduce modern
  C++ language/library features just because a current Clang accepts them.
- Multiplayer peers simulate AI locally. Game-state logic must be deterministic:
  do not depend on addresses, pointer-key iteration order, wall-clock time,
  platform-dependent iteration, or unsynchronized randomness. Use established
  game RNG and ordering patterns.
- UI Lua runs separately from gamecore logic. A Lua hook reached from the UI
  must not mutate synchronized game state. Follow the existing event/hook path
  for the same kind of operation.
- Save serialization is order- and schema-sensitive. If adding/changing state,
  find the owning `Read`/`Write` visitor pair, preserve identical field order,
  and explicitly assess old-save compatibility. Database layout changes can
  also invalidate saves; call this out in the handoff/PR.
- SQL/XML execution order is the order of `ModActions` in the component's
  `.civ5proj`, not filename order. New files must be included in the correct
  project and action position. Define tables/columns/types before consuming
  them, and keep CP-only data in component 1 rather than component 2.
- Keep Lua 5.1 compatibility and use the engine APIs/globals declared in
  `.luacheckrc` and `LuaCATS/`.
- Do not edit `(2) Vox Populi/Mapscripts/EMP`; it is explicitly excluded by
  `.gitignore`. Preserve each tracked file's existing line endings. Do not
  mass-convert files based on `.gitattributes`; Linux/Jujutsu checkouts use the
  repository's native LF unless a file already uses CRLF.
- Never commit credentials, local Civ paths, build output, logs, dumps, or IDE
  state. Expected generated directories include `BuildOutput/`, `BuildTemp/`,
  `Build/`, `clang-build/`, and `clang-output/`.

## Change workflow

1. Use `rg` to locate the existing implementation, database definition, Lua
   exposure, and callers. Prefer extending an established pattern over adding
   a parallel mechanism.
2. Keep patches narrow across layers. When a database field is added, trace its
   complete path: schema/load order, C++ info cache, game logic, serialization
   if applicable, Lua exposure, UI/text, and component manifest.
3. Follow local formatting and naming. This is a long-lived SDK-derived codebase
   with intentional inconsistencies; do not perform drive-by modernization or
   mass whitespace cleanup.
4. If adding/removing a DLL `.cpp`, update every active source list: the Visual
   Studio project/filter files and the hard-coded `CPP` lists in both
   `build_vp_clang.py` and `build_vp_clang_sdk.py`.
5. Treat each `.civ5proj` as the source of truth for mod metadata, file inclusion,
   and load actions. Regenerate the tracked `.modinfo` when its project/content
   changes; do not hand-edit only the generated manifest.
6. Use `jj status` and `jj diff` for version-control inspection. Do not discard
   unrelated working-copy changes, rewrite history, run release tooling, create
   tags, or push unless explicitly asked.
7. If `jj diff` unexpectedly reports whole-file replacements, check line endings
   before reviewing or committing the change.

## Validation

Validate the smallest relevant surface first, then report anything this
environment could not run.

- Manifest/project check without touching tracked manifests (works on Windows
  and POSIX; text files are hashed with CRLF line endings, and recorded MD5s
  that differ only by line endings are kept):

  ```text
  python scripts/generate_modinfo.py "(1) Community Patch" --output-dir C:\Temp\vp-modinfo
  ```

  Substitute the changed component. The generator also reports project entries
  whose source files are missing.
- Lua, when `luacheck` is available: run `luacheck` on the changed Lua files;
  the repository configuration knows Civ V engine globals.
- SQL/XML database changes: a plain SQLite syntax check is not enough. Civ V
  stops executing a SQL file at its first failing statement, so one bad column
  or table name silently skips the rest of that file. Many VP files also create
  `TEMP TABLE Helper` and drop it only at the end, so an early failure leaks the
  table and makes every later file's `CREATE TEMP TABLE Helper` fail as well.
  - Before using a column, confirm it exists in the real schema: grep the base
    definitions and CP's `ALTER TABLE`/`CREATE TABLE` changes (for example
    `(1) Community Patch/Database Changes/Units/UnitTableChanges.sql`). Do not
    infer a column from a DLL getter or Lua method name; e.g. `Units` has no
    `CargoSpace` column, and capacity comes from `PROMOTION_CARGO_*`.
  - Offline check: copy `Civ5DebugDatabase.db` (and, for `Language_*` changes,
    the localization database) from `My Games/Sid Meier's Civilization 5/cache`
    after starting a game with the mods enabled, before `deploy-vp.sh` deletes
    that folder. Then run
    `python scripts/validate_sql.py --db <copy> "(2) Vox Populi"`. It compiles
    each project's `UpdateDatabase` files in load order against that schema,
    stops a file at its first error like the game does, and reports leaked
    `TEMP` tables. It does not catch constraint/data errors or syntax that is too
    new for the game's SQLite, so still read `Database.log` before claiming
    success.
  - Authoritative check: set `LoggingEnabled = 1` in `config.ini`, start a game
    with the changed components, and read `Logs/Database.log` before anything
    else. Any `no such column`, `no such table`, `already exists`, constraint, or
    `Failed Validation` line from mod files is a blocker. Known harmless noise:
    `ContentPackage.LocalizedText`, `ArtDefine_StrategicView` uniqueness, and
    `ArtDefine_Landmarks.LayoutHandler` references. Civ rewrites the logs on
    every launch, so copy them before restarting.
- DLL on a configured Windows host:
  `python build_vp_clang.py --config debug` and
  `python build_vp_clang.py --config release`. This requires VS2008 SP1 via
  `VS90COMNTOOLS`. Also build `VoxPopuli_vs2013.sln` for `Win32` in both Debug
  and Release with the v90 toolset (VS2008 SP1 plus VS2010 SP1 integration).
  CI uses `build_vp_clang_sdk.py` with Windows SDK 7.0; that script is primarily
  for the CI environment.
- DLL on NixOS/Linux: enter `nix develop`, then run `vp-build --config debug`
  and `vp-build --config release`. Sandboxed equivalents are `nix build
  .#debug` and `nix build`. See `docs/nix-build.md`.
- C++ changes must compile without new warnings under both Clang and MSVC.
  The default Linux cross-build runs the v90 MSVC compiler/linker under Wine
  and uses the Windows Release LTO settings. The optional clang comparison
  build is `nix build .#clang-release`.
- There is no conventional automated gameplay/unit-test suite. For gameplay,
  AI, database, UI, networking, or serialization changes, do focused in-game
  testing with Civ V 1.0.3.279, all expansions/DLC, and the appropriate mod
  components. Check `Database.log`, `Lua.log`, relevant AI logs, and minidumps.
  Test loading a pre-change save when compatibility is claimed; test multiplayer
  or deterministic autoplay when synchronized state or AI decisions changed.
- The 43-civ DLL is a separate build selected in
  `CvGameCoreDLLUtil/include/CustomModsGlobal.h`. Do not leave a local maximum-
  civ define toggled accidentally, and test that variant when the change touches
  player/team limits or fixed-size arrays.

In the final handoff, summarize affected layers, validation performed, validation
not possible, and any save-game, multiplayer, performance, or 43-civ risk.
