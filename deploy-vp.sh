#!/usr/bin/env bash
set -euo pipefail

# Edit these two paths, or override them in the environment when invoking this
# script. CIV5_USER_DIR contains MODS, Text, and cache; CIV5_GAME_DIR contains
# Assets/DLC.
DEFAULT_CIV5_USER_DIR="/mnt/Windows/SteamLibrary/steamapps/compatdata/8930/pfx/drive_c/users/steamuser/Documents/My Games/Sid Meier's Civilization 5"
DEFAULT_CIV5_GAME_DIR="/mnt/Windows/SteamLibrary/steamapps/common/Sid Meier's Civilization V"
CIV5_USER_DIR="${CIV5_USER_DIR:-$DEFAULT_CIV5_USER_DIR}"
CIV5_GAME_DIR="${CIV5_GAME_DIR:-$DEFAULT_CIV5_GAME_DIR}"

# Optional components. The custom DLL built here is the standard VP DLL, so the
# 43-civ component is deliberately rejected instead of silently replacing it.
ENABLE_SQUADS="${ENABLE_SQUADS:-0}"
ENABLE_43_CIVS="${ENABLE_43_CIVS:-0}"
CLEAR_CACHE="${CLEAR_CACHE:-1}"
VP_FAST_BUILD="${VP_FAST_BUILD:-0}"
VP_BUILD_MODE="${VP_BUILD_MODE:-direct}"
VP_BUILD_BACKEND="${VP_BUILD_BACKEND:-msvc}"
VP_SKIP_BUILD="${VP_SKIP_BUILD:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODS_DIR="$CIV5_USER_DIR/MODS"
TEXT_DIR="$CIV5_USER_DIR/Text"
CACHE_DIR="$CIV5_USER_DIR/cache"
DLC_DIR="$CIV5_GAME_DIR/Assets/DLC"
BUILD_LINK="$SCRIPT_DIR/result-vp-deploy"
VP_BUILD_DIR="${VP_BUILD_DIR:-$SCRIPT_DIR/msvc-build/Release}"
VP_BUILD_OUTPUT_DIR="${VP_BUILD_OUTPUT_DIR:-$SCRIPT_DIR/BuildOutput/Release}"

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_source() {
	[[ -e "$SCRIPT_DIR/$1" ]] || fail "missing source: $SCRIPT_DIR/$1"
}

validate_destination() {
	local path="$1"
	local label="$2"
	local expected_name="$3"
	[[ -n "$path" && "$path" != "/" && "$path" != "$HOME" ]] || fail "$label is unsafe: $path"
	[[ "$path" == *"$expected_name"* ]] || fail "$label does not look like a Civilization V path: $path"
	[[ -d "$path" ]] || fail "$label does not exist: $path (set CIV5_USER_DIR/CIV5_GAME_DIR to the active Steam prefix)"
}

verify_dll_bindings() {
	local dll="$1"
	local binding
	[[ -f "$dll" ]] || fail "installed DLL is missing: $dll"
	cmp -s -- "$DLL" "$dll" || fail "installed DLL differs from the build artifact: $dll"

	for binding in \
		GetExtraVotesForMember \
		SetExtraVotesForMember \
		SetHostMember \
		SetTurnsUntilSession
	do
		LC_ALL=C grep -a -F -q -- "$binding" "$dll" \
			|| fail "installed DLL is missing World Congress binding $binding: $dll"
	done

	printf 'Verified custom DLL: %s\n' "$dll"
	sha256sum -- "$dll"
}

replace_directory() {
	local source="$1"
	local destination_parent="$2"
	local name
	local destination
	local staging
	local backup_root
	local backup
	name="$(basename -- "$source")"
	destination="$destination_parent/$name"
	staging="$destination_parent/.vp-deploy-new-$name-$$"
	backup_root="$destination_parent.vp-deploy-backups"
	backup="$backup_root/$name-$(date +%Y%m%d-%H%M%S)-$$"

	printf 'Installing %s\n' "$destination"
	mkdir -p -- "$destination_parent"
	[[ ! -e "$staging" ]] || fail "staging path already exists: $staging"
	cp -a -- "$source" "$staging"

	if [[ -e "$destination" ]]; then
		mkdir -p -- "$backup_root"
		mv -- "$destination" "$backup"
	fi

	if ! mv -- "$staging" "$destination"; then
		if [[ -e "$backup" && ! -e "$destination" ]]; then
			mv -- "$backup" "$destination"
		fi
		fail "could not install $destination"
	fi

	if [[ -e "$backup" ]] && ! rm -rf -- "$backup"; then
		printf 'warning: old installation could not be deleted and remains at %s\n' "$backup" >&2
	fi
}

find_nix() {
	if command -v nix >/dev/null 2>&1; then
		command -v nix
	elif [[ -x /run/current-system/sw/bin/nix ]]; then
		printf '%s\n' /run/current-system/sw/bin/nix
	else
		fail "nix was not found; install Nix or add it to PATH"
	fi
}

build_dll() {
	local mode="$VP_BUILD_MODE"
	local driver
	local -a build_args

	case "$mode" in
		auto)
			if command -v vp-build >/dev/null 2>&1 || {
				command -v python3 >/dev/null 2>&1 &&
				[[ -n "${VP_SDK_ROOT:-}" && -n "${VP_MSVC_ROOT:-}" ]] &&
				command -v wine >/dev/null 2>&1;
			}; then
				mode=direct
			else
				mode=nix
			fi
			;;
		direct|nix)
			;;
		*)
			fail "VP_BUILD_MODE must be auto, direct, or nix (got: $VP_BUILD_MODE)"
			;;
	esac

	if [[ "$mode" == "direct" ]]; then
		if command -v vp-build >/dev/null 2>&1; then
			driver="$(command -v vp-build)"
		else
			driver="$(command -v python3 || true)"
			[[ -n "$driver" ]] || fail "python3 is required for direct builds"
			[[ -n "${VP_SDK_ROOT:-}" && -n "${VP_MSVC_ROOT:-}" ]] || fail "direct builds require VP_SDK_ROOT and VP_MSVC_ROOT"
			command -v wine >/dev/null 2>&1 || fail "direct MSVC builds require wine"
			build_args+=("$SCRIPT_DIR/nix/build-vp.py")
		fi

		build_args+=(
			--backend "$VP_BUILD_BACKEND"
			--config release
			--build-dir "$VP_BUILD_DIR"
			--output-dir "$VP_BUILD_OUTPUT_DIR"
		)
		if [[ "$VP_FAST_BUILD" == "1" ]]; then
			build_args+=(--fast)
		fi
		if [[ -n "${VP_BUILD_JOBS:-}" ]]; then
			build_args+=(--jobs "$VP_BUILD_JOBS")
		fi

		printf 'Building release DLL directly in %s...\n' "$VP_BUILD_DIR"
		(
			cd -- "$SCRIPT_DIR"
			"$driver" "${build_args[@]}"
		)
		DLL="$VP_BUILD_OUTPUT_DIR/CvGameCore_Expansion2.dll"
		PDB="$VP_BUILD_OUTPUT_DIR/CvGameCore_Expansion2.pdb"
		return
	fi

	local nix_bin
	local build_package="default"
	nix_bin="$(find_nix)"
	if [[ "$VP_FAST_BUILD" == "1" ]]; then
		build_package="fast"
	fi
	printf 'Building %s release DLL with Nix...\n' "$build_package"
	"$nix_bin" --extra-experimental-features "nix-command flakes" \
		build "$SCRIPT_DIR#$build_package" --out-link "$BUILD_LINK"
	DLL="$BUILD_LINK/CvGameCore_Expansion2.dll"
	PDB="$BUILD_LINK/CvGameCore_Expansion2.pdb"
}

validate_destination "$CIV5_USER_DIR" "CIV5_USER_DIR" "Sid Meier's Civilization 5"
validate_destination "$CIV5_GAME_DIR" "CIV5_GAME_DIR" "Sid Meier's Civilization V"

for source in \
	"(1) Community Patch" \
	"(2) Vox Populi" \
	"(3a) VP - EUI Compatibility Files" \
	"InGame Editor+ (v 47)" \
	"VPUI" \
	"UI_bc1" \
	"VPUI Text/VPUI_tips_en_us.xml"
do
	require_source "$source"
done

if [[ "$ENABLE_SQUADS" == "1" ]]; then
	require_source "(4a) Squads for VP"
fi

if [[ "$ENABLE_43_CIVS" == "1" ]]; then
	fail "the 43-civ component contains a different DLL and would remove the IGE Congress bindings; build a custom 43-civ DLL before enabling it"
fi

case "$VP_SKIP_BUILD" in
	0|1) ;;
	*) fail "VP_SKIP_BUILD must be 0 or 1 (got: $VP_SKIP_BUILD)" ;;
esac

cat <<EOF
This will $(if [[ "$VP_SKIP_BUILD" == "1" ]]; then printf 'deploy the existing release DLL and'; else printf 'build the release DLL and'; fi) replace these installed directories:
  $MODS_DIR/(1) Community Patch
  $MODS_DIR/(2) Vox Populi
  $MODS_DIR/(3a) VP - EUI Compatibility Files
  $MODS_DIR/InGame Editor+ (v 47)
  $DLC_DIR/VPUI
  $DLC_DIR/UI_bc1

It will also install VPUI_tips_en_us.xml under:
  $TEXT_DIR
EOF

if [[ "$ENABLE_SQUADS" == "1" ]]; then
	printf '  Squads enabled: %s\n' "$MODS_DIR/(4a) Squads for VP"
fi
if [[ "$CLEAR_CACHE" == "1" ]]; then
	printf '  Cache removal: %s\n' "$CACHE_DIR"
fi

if [[ "${ASSUME_YES:-0}" != "1" ]]; then
	read -r -p "Continue? [y/N] " answer
	[[ "$answer" == "y" || "$answer" == "Y" ]] || exit 0
fi

if [[ "$VP_SKIP_BUILD" == "1" ]]; then
	DLL="${VP_DLL:-$VP_BUILD_OUTPUT_DIR/CvGameCore_Expansion2.dll}"
	PDB="${VP_PDB:-$VP_BUILD_OUTPUT_DIR/CvGameCore_Expansion2.pdb}"
	printf 'Using existing release DLL: %s\n' "$DLL"
else
	build_dll
fi

[[ -f "$DLL" ]] || fail "release DLL is missing: $DLL"
[[ -f "$PDB" ]] || fail "matching release debug symbols are missing: $PDB"

# Retain the exact DLL and symbols outside MODS so subsequent builds cannot
# replace the evidence needed to investigate a crash from this installation.
DLL_SHA256="$(sha256sum -- "$DLL")"
DLL_SHA256="${DLL_SHA256%% *}"
SYMBOLS_DIR="$CIV5_USER_DIR/vp-build-artifacts/$DLL_SHA256"
mkdir -p -- "$SYMBOLS_DIR"
cp -f -- "$DLL" "$PDB" "$SYMBOLS_DIR/"
if [[ -f "$BUILD_LINK/build-info.json" ]]; then
	cp -f -- "$BUILD_LINK/build-info.json" "$SYMBOLS_DIR/"
fi
printf 'Build artifact SHA-256: %s\nMatching DLL and PDB retained in: %s\n' "$DLL_SHA256" "$SYMBOLS_DIR"

replace_directory "$SCRIPT_DIR/(1) Community Patch" "$MODS_DIR"
replace_directory "$SCRIPT_DIR/(2) Vox Populi" "$MODS_DIR"
replace_directory "$SCRIPT_DIR/(3a) VP - EUI Compatibility Files" "$MODS_DIR"
replace_directory "$SCRIPT_DIR/InGame Editor+ (v 47)" "$MODS_DIR"

# The manual VP installation instructions require these bundled Lua folders to
# be absent from components 1 and 2.
rm -rf -- "$MODS_DIR/(1) Community Patch/LUA"
rm -rf -- "$MODS_DIR/(2) Vox Populi/LUA"

# Install the freshly built DLL after copying component 1 so it cannot be
# overwritten by the repository's prebuilt DLL.
INSTALLED_DLL="$MODS_DIR/(1) Community Patch/CvGameCore_Expansion2.dll"
cp -f -- "$DLL" "$INSTALLED_DLL"
verify_dll_bindings "$INSTALLED_DLL"

mkdir -p -- "$TEXT_DIR"
cp -f -- "$SCRIPT_DIR/VPUI Text/VPUI_tips_en_us.xml" "$TEXT_DIR/VPUI_tips_en_us.xml"

replace_directory "$SCRIPT_DIR/VPUI" "$DLC_DIR"
replace_directory "$SCRIPT_DIR/UI_bc1" "$DLC_DIR"

if [[ "$ENABLE_SQUADS" == "1" ]]; then
	replace_directory "$SCRIPT_DIR/(4a) Squads for VP" "$MODS_DIR"
fi

if [[ "$CLEAR_CACHE" == "1" && -e "$CACHE_DIR" ]]; then
	printf 'Removing %s\n' "$CACHE_DIR"
	old_cache="$CIV5_USER_DIR/.vp-deploy-old-cache-$(date +%Y%m%d-%H%M%S)-$$"
	mv -- "$CACHE_DIR" "$old_cache"
	if ! rm -rf -- "$old_cache"; then
		printf 'warning: old cache could not be deleted and remains at %s\n' "$old_cache" >&2
	fi
fi

cat <<EOF
Deployment complete.

Installed custom DLL:
  $MODS_DIR/(1) Community Patch/CvGameCore_Expansion2.dll

Matching DLL and debug symbols:
  $SYMBOLS_DIR

Start Civilization V through Mods and enable the Community Patch, Vox Populi,
EUI compatibility files, and InGame Editor+.
EOF
