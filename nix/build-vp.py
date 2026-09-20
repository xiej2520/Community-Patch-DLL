#!/usr/bin/env python3
"""Build the 32-bit, MSVC-ABI Vox Populi DLL from a POSIX host."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


CORE_DLL = "CvGameCore_Expansion2"
CORE_DIR = Path("CvGameCoreDLL_Expansion2")
PROJECT = CORE_DIR / "VoxPopuli.vcxproj"
PCH_SOURCE = CORE_DIR / "_precompile.cpp"
PCH_HEADER = "CvGameCoreDLLPCH.h"
DEF_FILE = CORE_DIR / "CvGameCoreDLL.def"

INCLUDE_DIRS = (
    CORE_DIR,
    Path("CvWorldBuilderMap/include"),
    Path("CvGameCoreDLLUtil/include"),
    Path("CvLocalization/include"),
    Path("CvGameDatabase/include"),
    Path("FirePlace/include"),
    Path("FirePlace/include/FireWorks"),
    Path("ThirdPartyLibs/Lua51/include"),
)

CLANG_LIBRARIES = (
    Path("CvWorldBuilderMap/lib/CvWorldBuilderMapWin32.obj"),
    Path("CvGameCoreDLLUtil/lib/CvGameCoreDLLUtilWin32.lib"),
    Path("CvLocalization/lib/CvLocalizationWin32.lib"),
    Path("CvGameDatabase/lib/CvGameDatabaseWin32.lib"),
    Path("FirePlace/lib/FireWorksWin32.obj"),
    Path("FirePlace/lib/FLuaWin32.lib"),
    Path("ThirdPartyLibs/Lua51/lib/lua51_Win32.lib"),
)

MSVC_LIBRARIES = (
    Path("CvWorldBuilderMap/lib/CvWorldBuilderMapWin32.lib"),
    Path("CvGameCoreDLLUtil/lib/CvGameCoreDLLUtilWin32.lib"),
    Path("CvLocalization/lib/CvLocalizationWin32.lib"),
    Path("CvGameDatabase/lib/CvGameDatabaseWin32.lib"),
    Path("FirePlace/lib/FireWorksWin32.lib"),
    Path("FirePlace/lib/FLuaWin32.lib"),
    Path("ThirdPartyLibs/Lua51/lib/lua51_Win32.lib"),
)

WINDOWS_LIBRARIES = (
    "winmm.lib",
    "kernel32.lib",
    "user32.lib",
    "gdi32.lib",
    "winspool.lib",
    "comdlg32.lib",
    "advapi32.lib",
    "shell32.lib",
    "ole32.lib",
    "oleaut32.lib",
    "uuid.lib",
    "odbc32.lib",
    "odbccp32.lib",
    "msvcrt.lib",
)

MSVC_WINDOWS_LIBRARIES = ("winmm.lib", "advapi32.lib")

COMMON_DEFINES = (
    "FXS_IS_DLL",
    "WIN32",
    "_WINDOWS",
    "_USRDLL",
    "EXTERNAL_PAUSING",
    "CVGAMECOREDLL_EXPORTS",
    "FINAL_RELEASE",
    "_CRT_SECURE_NO_WARNINGS",
    "_WINDLL",
)

WARNING_SUPPRESSIONS = (
    "invalid-offsetof",
    "invalid-token-paste",
    "tautological-constant-out-of-range-compare",
    "comment",
    "c++11-narrowing",
    "nonportable-include-path",
)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def find_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        fail(f"{name} is not on PATH; enter the flake development shell")
    return path


def find_optional_tool(name: str, requested: str | None = None) -> str:
    if requested:
        return requested
    return find_tool(name)


def windows_path(path: Path) -> str:
    """Convert an absolute POSIX path using Wine's default Z: drive.

    A fresh prefix maps Z: to the POSIX root. Calling winepath for every
    compiler argument starts a separate Wine process and can block while the
    prefix/server is being initialized, especially inside a Nix build. The
    direct mapping is deterministic and works for both /build/source and
    /nix/store paths.
    """
    absolute = path if path.is_absolute() else path.resolve()
    return "Z:" + str(absolute).replace("/", "\\")


def msvc_directories(root: Path) -> tuple[Path, Path, Path, Path]:
    candidates = (root, root / "VC")
    for vc in candidates:
        directories = (vc / "bin", vc / "include", vc / "lib")
        if all(path.is_dir() for path in directories) and (vc / "bin/cl.exe").is_file():
            return vc / "bin", vc / "include", vc / "lib", vc
    fail(
        "VP_MSVC_ROOT must point to the VS2008 VC directory or its parent; "
        "expected bin/cl.exe, include/, and lib/"
    )


def tool_version(command: list[str]) -> str:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    output = (result.stdout + result.stderr).strip()
    return output[:4000]


def source_files(repo: Path) -> list[Path]:
    namespace = {"ms": "http://schemas.microsoft.com/developer/msbuild/2003"}
    root = ET.parse(repo / PROJECT).getroot()
    sources = []
    for node in root.findall(".//ms:ClCompile", namespace):
        include = node.get("Include")
        if not include or include == "_precompile.cpp":
            continue
        sources.append(CORE_DIR / Path(include.replace("\\", "/")))
    if not sources:
        fail(f"no C++ sources found in {PROJECT}")
    return sources


def sdk_directories(sdk: Path) -> tuple[Path, Path, Path, Path]:
    directories = (
        sdk / "Include",
        sdk / "Lib",
        sdk / "VC/include",
        sdk / "VC/lib",
    )
    missing = [str(path) for path in directories if not path.is_dir()]
    if missing:
        fail("incomplete VP_SDK_ROOT; missing " + ", ".join(missing))
    return directories


def run(command: list[str], *, cwd: Path, log: Path) -> None:
    print(f"Running {log.relative_to(log.parents[1])}", flush=True)
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(
        "$ " + subprocess.list2cmdline(command) + "\n" + result.stdout + result.stderr,
        encoding="utf-8",
    )
    if result.returncode:
        # Nix removes a failed derivation's output directory, so diagnostics
        # written only to the per-command log would otherwise be lost.
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        fail(f"command failed; see {log}")
    print(f"Finished {log.relative_to(log.parents[1])}", flush=True)


def compile_one(
    compiler: list[str],
    path_converter,
    repo: Path,
    source: Path,
    output: Path,
    common_args: list[str],
    pch: Path | None,
    log: Path,
) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [*compiler, *common_args]
    if pch is not None:
        command.extend([f'/Yu{PCH_HEADER}', f'/Fp{path_converter(pch)}'])
    command.extend([path_converter(source), f'/Fo{path_converter(output)}'])
    run(command, cwd=repo, log=log)
    return output


def write_version(repo: Path, explicit_version: str | None) -> None:
    if explicit_version is None:
        describe = subprocess.run(
            ["git", "describe", "--tags", "--always", "--dirty"],
            cwd=repo,
            text=True,
            capture_output=True,
        )
        version = describe.stdout.strip() if describe.returncode == 0 else "Unknown"
    else:
        version = explicit_version
    version = version.replace("\\", "\\\\").replace('"', '\\"')
    (repo / "commit_id.inc").write_text(
        f'const char CURRENT_GAMECORE_VERSION[] = "{version}"; '
        "// autogenerated, do not commit this file!\n",
        encoding="utf-8",
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_provenance(
    output_dir: Path,
    *,
    configuration: str,
    backend: str,
    version: str,
    compiler: list[str],
    linker: list[str],
    compiler_version: str,
    linker_version: str,
    compile_args: list[str],
    link_args: list[str],
    dll: Path,
    pdb: Path,
) -> None:
    info = {
        "schema": 1,
        "configuration": configuration.lower(),
        "backend": backend,
        "target": "i686-pc-windows-msvc",
        "source_version": version,
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "compiler": {
            "command": compiler,
            "version": compiler_version,
            "flags": compile_args,
        },
        "linker": {
            "command": linker,
            "version": linker_version,
            "flags": link_args,
        },
        "artifacts": {
            "dll": {
                "name": dll.name,
                "size": dll.stat().st_size,
                "sha256": sha256(dll),
            },
            "pdb": {
                "name": pdb.name,
                "size": pdb.stat().st_size,
                "sha256": sha256(pdb),
            },
        },
    }
    (output_dir / "build-info.json").write_text(
        json.dumps(info, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", choices=("debug", "release"), default="debug")
    parser.add_argument("--fast", action="store_true", help="skip whole-program optimization in the MSVC Release build")
    parser.add_argument(
        "--backend",
        choices=("clang", "msvc"),
        default=os.environ.get("VP_BUILD_BACKEND", "msvc"),
        help="clang-cl/lld-link or the real v90 cl.exe/link.exe under Wine",
    )
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    parser.add_argument("--sdk-root", type=Path, default=os.environ.get("VP_SDK_ROOT"))
    parser.add_argument("--msvc-root", type=Path, default=os.environ.get("VP_MSVC_ROOT"))
    parser.add_argument("--wine", default=os.environ.get("VP_WINE"))
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--version", help="version embedded in the DLL (defaults to git describe)")
    args = parser.parse_args()

    if args.sdk_root is None:
        fail("set VP_SDK_ROOT or pass --sdk-root (nix develop does this automatically)")
    if args.jobs < 1:
        fail("--jobs must be positive")
    if args.fast and (args.backend != "msvc" or args.config != "release"):
        fail("--fast applies only to an MSVC Release build")

    repo = Path.cwd().resolve()
    if not (repo / PROJECT).is_file():
        fail(f"run this command from the repository root ({PROJECT} was not found)")

    configuration = args.config.capitalize()
    default_prefix = "msvc" if args.backend == "msvc" else "clang"
    build_dir = (args.build_dir or repo / f"{default_prefix}-build" / configuration).resolve()
    output_dir = (args.output_dir or repo / ("BuildOutput" if args.backend == "msvc" else "clang-output") / configuration).resolve()
    build_dir.mkdir(parents=True, exist_ok=True)
    output_dir.mkdir(parents=True, exist_ok=True)

    sdk_include, sdk_lib, vc_include, vc_lib = sdk_directories(args.sdk_root.resolve())
    if args.backend == "msvc":
        if args.msvc_root is None:
            fail(
                "the MSVC backend requires VP_MSVC_ROOT or --msvc-root; "
                "this must be a locally installed VS2008 SP1 VC directory"
            )
        wine = find_optional_tool("wine", args.wine)
        msvc_bin, msvc_include, msvc_lib, msvc_root = msvc_directories(args.msvc_root.resolve())
        cl_path = msvc_bin / "cl.exe"
        link_path = msvc_bin / "link.exe"
        if not link_path.is_file():
            fail(f"MSVC linker not found: {link_path}")
        path_converter = windows_path
        compiler = [wine, path_converter(cl_path)]
        linker = [wine, path_converter(link_path)]
        compiler_display = [str(cl_path)]
        linker_display = [str(link_path)]
    else:
        clang = find_tool("clang-cl")
        lld = find_tool("lld-link")
        path_converter = str
        compiler = [clang]
        linker = [lld]
        compiler_display = [clang]
        linker_display = [lld]
    write_version(repo, args.version)

    defines = list(COMMON_DEFINES)
    if args.config == "release":
        defines.extend(("STRONG_ASSUMPTIONS", "NDEBUG", "VPRELEASE_ERRORMSG"))
        optimization = ["/Ox", "/Ob2", "/Zo", "-flto"] if args.backend == "clang" else ["/Ox", "/Ob2", "/Zm365"]
        if args.backend == "msvc" and not args.fast:
            optimization.append("/GL")
        elif args.backend == "msvc":
            optimization = ["/Ox", "/Ob2", "/Zm500"]
    else:
        defines.append("VPDEBUG")
        optimization = ["/Od", "/Oy-"]

    if args.backend == "msvc":
        if args.config != "release":
            optimization = ["/Od", "/Oy-", "/Zm400"]
        common_args = [
            "/nologo", "/c", "/MD", "/GS", "/EHsc", "/fp:precise", "/W3",
            "/Zc:wchar_t", "/Z7", *optimization,
            *(f"/D{value}" for value in defines),
            *(f"/I{path_converter(repo / path)}" for path in INCLUDE_DIRS),
            f"/I{path_converter(msvc_include)}",
            f"/I{path_converter(sdk_include)}",
        ]
    else:
        common_args = [
            "--target=i686-pc-windows-msvc", "-m32", "-msse3",
            "/c", "/MD", "/GS", "/EHsc", "/fp:precise", "/Zc:wchar_t",
            "/Zi", "/FS", *optimization,
            *(f"/D{value}" for value in defines),
            *(f"/I{repo / path}" for path in INCLUDE_DIRS),
            f"/I{vc_include}", f"/I{sdk_include}",
            *(f"-Wno-{warning}" for warning in WARNING_SUPPRESSIONS),
        ]

    print(f"Building {configuration} DLL with {args.jobs} jobs using {args.backend}")
    helper_obj = build_dir / "clang.obj"
    if args.backend == "clang":
        compile_one(
            compiler,
            path_converter,
            repo,
            Path("clang.cpp"),
            helper_obj,
            common_args,
            None,
            output_dir / "logs/clang.log",
        )

    sources = source_files(repo)
    pch = build_dir / "CvGameCoreDLLPCH.pch"
    pch_obj = build_dir / "_precompile.obj"
    run(
        [
            *compiler,
            *common_args,
            f"/Yc{PCH_HEADER}",
            f"/Fp{path_converter(pch)}",
            path_converter(PCH_SOURCE),
            f"/Fo{path_converter(pch_obj)}",
        ],
        cwd=repo,
        log=output_dir / "logs/_precompile.log",
    )

    objects: list[Path] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = []
        for source in sources:
            output = (build_dir / source).with_suffix(".obj")
            log = (output_dir / "logs" / source).with_suffix(".log")
            futures.append(
                executor.submit(
                    compile_one,
                    compiler,
                    path_converter,
                    repo,
                    source,
                    output,
                    common_args,
                    pch,
                    log,
                )
            )
        for future in concurrent.futures.as_completed(futures):
            try:
                objects.append(future.result())
            except BaseException:
                for pending in futures:
                    pending.cancel()
                raise

    dll = output_dir / f"{CORE_DLL}.dll"
    pdb = output_dir / f"{CORE_DLL}.pdb"
    manifest_resource = None
    if args.backend == "msvc":
        # SDK mt.exe crashes under Wine when updating a PE image. Embed the
        # equivalent VC90 runtime manifest as resource ID 2 at link time.
        manifest = build_dir / f"{CORE_DLL}.dll.manifest"
        manifest.write_text(
            "<?xml version='1.0' encoding='UTF-8' standalone='yes'?>\n"
            "<assembly xmlns='urn:schemas-microsoft-com:asm.v1' manifestVersion='1.0'>\n"
            "  <trustInfo xmlns='urn:schemas-microsoft-com:asm.v3'>\n"
            "    <security><requestedPrivileges>"
            "<requestedExecutionLevel level='asInvoker' uiAccess='false' />"
            "</requestedPrivileges></security>\n"
            "  </trustInfo>\n"
            "  <dependency><dependentAssembly>\n"
            "    <assemblyIdentity type='win32' name='Microsoft.VC90.CRT' "
            "version='9.0.21022.8' processorArchitecture='x86' "
            "publicKeyToken='1fc8b3b9a1e18e3b' />\n"
            "  </dependentAssembly></dependency>\n"
            "</assembly>\n",
            encoding="utf-8",
        )
        resource_script = build_dir / "manifest.rc"
        resource_script.write_text(
            f'2 24 "{path_converter(manifest).replace(chr(92), chr(92) * 2)}"\n',
            encoding="ascii",
        )
        manifest_resource = build_dir / "manifest.res"
        rc_path = args.sdk_root / "Bin/RC.Exe"
        if not rc_path.is_file():
            fail(f"Windows SDK resource compiler was not found: {rc_path}")
        run(
            [wine, path_converter(rc_path), "/nologo", f"/fo{path_converter(manifest_resource)}", path_converter(resource_script)],
            cwd=repo,
            log=output_dir / "logs/manifest-resource.log",
        )
    link_flags = [
        "/MACHINE:x86",
        "/DLL",
        "/DEBUG",
        "/DYNAMICBASE",
        "/NXCOMPAT",
        "/SUBSYSTEM:WINDOWS",
        "/MANIFEST:NO" if args.backend == "msvc" else "/MANIFEST:EMBED",
        f"/DEF:{path_converter(repo / DEF_FILE)}",
        f"/OUT:{path_converter(dll)}",
        f"/PDB:{path_converter(pdb)}",
        f"/LIBPATH:{path_converter(msvc_lib if args.backend == 'msvc' else vc_lib)}",
        f"/LIBPATH:{path_converter(sdk_lib)}",
    ]
    if args.backend == "clang":
        link_flags.append("/FORCE:MULTIPLE")
    if args.config == "release":
        link_flags.extend(("/OPT:REF", "/OPT:ICF"))
        if not args.fast:
            link_flags.append("/LTCG")
        link_flags.append("/INCREMENTAL:NO")
    elif args.backend == "msvc":
        link_flags.append("/INCREMENTAL")
    libraries = MSVC_LIBRARIES if args.backend == "msvc" else CLANG_LIBRARIES
    link_flags.extend(path_converter(repo / library) for library in libraries)
    link_flags.extend(MSVC_WINDOWS_LIBRARIES if args.backend == "msvc" else WINDOWS_LIBRARIES)
    if args.backend == "clang":
        link_flags.append(path_converter(helper_obj))
    link_flags.append(path_converter(pch_obj))
    if manifest_resource is not None:
        link_flags.append(path_converter(manifest_resource))
    link_flags.extend(path_converter(path) for path in sorted(objects))
    response = output_dir / "link.rsp"
    response.write_text("\n".join(link_flags) + "\n", encoding="utf-8")
    link_command = [*linker, f"@{path_converter(response)}"]
    run(link_command, cwd=repo, log=output_dir / "build.log")
    version = args.version or "Unknown"
    if args.version is None:
        describe = subprocess.run(["git", "describe", "--tags", "--always", "--dirty"], cwd=repo, text=True, capture_output=True)
        if describe.returncode == 0:
            version = describe.stdout.strip()
    write_provenance(
        output_dir,
        configuration=configuration,
        backend=args.backend,
        version=version,
        compiler=compiler_display,
        linker=linker_display,
        compiler_version=tool_version(compiler),
        linker_version=tool_version(linker),
        compile_args=common_args,
        link_args=link_flags,
        dll=dll,
        pdb=pdb,
    )
    print(f"Built {dll}")
    print(f"Debug symbols: {pdb}")
    print(f"Build provenance: {output_dir / 'build-info.json'}")


if __name__ == "__main__":
    main()
