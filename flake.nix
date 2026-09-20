{
  description = "Nix toolchain for the Civilization V Community Patch DLL";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    llvm = pkgs.llvmPackages_20;

    # Windows SDK 7.0 contains both the VC9 SP1 C/C++ headers and the Win32
    # SDK headers/import libraries. The SHA-256 below was independently checked
    # against Microsoft's published SHA-1 (8695f5e6810d84153181695da78850988a923f4e).
    sdkIso = pkgs.fetchurl {
      urls = [
        "https://ftp.zx.net.nz/pub/dev/WinSDK/win7-7.0-dn35sp1/GRMSDK_EN_DVD.iso"
        "https://web.archive.org/web/20161230154527id_/http://download.microsoft.com/download/2/E/9/2E911956-F90F-4BFB-8231-E292A7B6F287/GRMSDK_EN_DVD.iso"
      ];
      hash = "sha256-ZXOfsIdMwX6mli2M55FTZMcWH6EG7RvxyReSTBisY8o=";
    };

    # The Windows SDK supplies the headers and import libraries, but not the
    # v90 compiler. Visual C++ 2008 Express SP1 is the redistributable
    # Microsoft compiler package; its MSI payload is extracted below and run
    # under Wine. The archive is fetched by Nix and remains outside the repo.
    vs2008Iso = pkgs.fetchurl {
      urls = [
        "https://download.microsoft.com/download/E/8/E/E8EEB394-7F42-4963-A2D8-29559B738298/VS2008ExpressWithSP1ENUX1504728.iso"
        "https://web.archive.org/web/20250618154620id_/https://download.microsoft.com/download/E/8/E/E8EEB394-7F42-4963-A2D8-29559B738298/VS2008ExpressWithSP1ENUX1504728.iso"
      ];
      hash = "sha256-bTte7fpGGWnF1kWHG1MALRYqLiOEhpANL99xd01T+5E=";
    };

    windowsSdk = pkgs.runCommand "vp-windows-sdk-7.0-vc9" {
      nativeBuildInputs = [pkgs.p7zip pkgs.msitools pkgs.python3];
      preferLocalBuild = true;
    } ''
      mkdir -p iso extracted "$out/Include" "$out/Lib" "$out/VC/include" "$out/VC/lib"
      7z x -bd -y ${sdkIso} -oiso >/dev/null

      for msi in \
        iso/Setup/WinSDK/WinSDK_x86.msi \
        iso/Setup/WinSDKBuild/WinSDKBuild_x86.msi \
        iso/Setup/WinSDKInterop/WinSDKInterop_x86.msi \
        iso/Setup/WinSDKTools/WinSDKTools_x86.msi \
        iso/Setup/WinSDKWin32Tools/WinSDKWin32Tools_x86.msi \
        iso/Setup/vc_stdx86/vc_stdx86.msi
      do
        test -f "$msi"
        msiextract -C extracted "$msi" >/dev/null
      done

      sdkInclude=$(find extracted -type d -path '*/Microsoft SDKs/Windows/v7.0/Include' -print -quit)
      sdkLib=$(find extracted -type d -path '*/Microsoft SDKs/Windows/v7.0/Lib' -print -quit)
      # msiextract preserves MSI's short-name:long-name directory token as
      # the literal directory "VC:Vc7" instead of choosing its long name.
      vcInclude=$(find extracted -type d -path '*/Microsoft Visual Studio 9.0/VC:Vc7/include' -print -quit)
      vcLib=$(find extracted -type d -path '*/Microsoft Visual Studio 9.0/VC:Vc7/lib' -print -quit)

      test -n "$sdkInclude" && test -n "$sdkLib"
      test -n "$vcInclude" && test -n "$vcLib"
      cp -a "$sdkInclude/." "$out/Include/"
      cp -a "$sdkLib/." "$out/Lib/"
      cp -a "$vcInclude/." "$out/VC/include/"
      cp -a "$vcLib/." "$out/VC/lib/"

      # Windows paths are case-insensitive. Microsoft headers use includes such
      # as codeanalysis\sourceannotations.h while the installed directory is
      # named CodeAnalysis; import-library casing varies in the same way.
      python3 - "$out" <<'PY'
      import os
      import re
      import sys

      for top in ("Include", "Lib", "VC/include", "VC/lib"):
          for root, directories, files in os.walk(os.path.join(sys.argv[1], top)):
              if top.endswith("include") or top == "Include":
                  for name in files:
                      path = os.path.join(root, name)
                      with open(path, "rb") as stream:
                          contents = stream.read()
                      normalized = re.sub(
                          rb'(^\s*#\s*include\s*[<"])([^>"]+)([>"])',
                          lambda match: match.group(1) + match.group(2).lower() + match.group(3),
                          contents,
                          flags=re.MULTILINE,
                      )
                      if normalized != contents:
                          with open(path, "wb") as stream:
                              stream.write(normalized)
              for name in directories + files:
                  stem, suffix = os.path.splitext(name)
                  aliases = {
                      name.lower(),
                      name.upper(),
                      stem + suffix.lower(),
                      stem + suffix.upper(),
                      stem.lower() + suffix.lower(),
                      stem.upper() + suffix.lower(),
                  }
                  for alias_name in aliases:
                      alias = os.path.join(root, alias_name)
                      if alias_name != name and not os.path.lexists(alias):
                          os.symlink(name, alias)
      PY

      sdkBin=$(find extracted -type d -path '*/Microsoft SDKs/Windows/v7.0/Bin' -print -quit)
      mkdir -p "$out/Bin"
      test -n "$sdkBin"
      cp -a "$sdkBin/." "$out/Bin/"
    '';

    msvcToolchain = pkgs.runCommand "vp-msvc-v90-sp1" {
      nativeBuildInputs = [pkgs.p7zip pkgs.msitools];
      preferLocalBuild = true;
    } ''
      mkdir -p iso extracted "$out/bin" "$out/include" "$out/lib"
      7z e -bd -y ${vs2008Iso} VCExpress/Ixpvc.exe -oiso >/dev/null
      7z e -bd -y iso/Ixpvc.exe vs_setup.msi vs_setup.cab -oiso >/dev/null
      msiextract -C extracted iso/vs_setup.msi >/dev/null

      vc=$(find extracted -type d -path '*/Microsoft Visual Studio 9.0/VC:Vc7' -print -quit)
      ide=$(find extracted -type d -path '*/Microsoft Visual Studio 9.0/Common7/IDE' -print -quit)
      test -n "$vc" && test -n "$ide"
      test -f "$vc/bin/cl.exe" && test -f "$vc/bin/link.exe"
      cp -a "$vc/bin/." "$out/bin/"
      cp -a "$vc/include/." "$out/include/"
      cp -a "$vc/lib/." "$out/lib/"
      cp -a "$ide/mspdb80.dll" "$ide/mspdbcore.dll" "$ide/mspdbsrv.exe" "$ide/msobj80.dll" "$out/bin/"
      crt=$(find extracted -type d -path '*/Microsoft Visual Studio 9.0/VC:Vc7/redist/x86/Microsoft.VC90.CRT' -print -quit)
      test -n "$crt"
      cp -a "$crt/." "$out/bin/"
    '';

    vpBuild = pkgs.writeShellApplication {
      name = "vp-build";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gitMinimal
        pkgs.python3
        pkgs.wineWow64Packages.stable
        llvm.clang-unwrapped
        llvm.lld
      ];
      text = ''
        repo="''${VP_REPO_ROOT:-$PWD}"
        export VP_SDK_ROOT="''${VP_SDK_ROOT:-${windowsSdk}}"
        export VP_MSVC_ROOT="''${VP_MSVC_ROOT:-${msvcToolchain}}"
        export WINEPREFIX="''${WINEPREFIX:-''${TMPDIR:-/tmp}/vp-wine-prefix}"
        export XDG_CACHE_HOME="$WINEPREFIX/xdg-cache"
        export XDG_CONFIG_HOME="$WINEPREFIX/xdg-config"
        export XDG_DATA_HOME="$WINEPREFIX/xdg-data"
        export XDG_RUNTIME_DIR="$WINEPREFIX/xdg-runtime"
        export WINEDEBUG=-all
        export PYTHONUNBUFFERED=1
        mkdir -p "$WINEPREFIX" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
        exec python3 "$repo/nix/build-vp.py" "$@"
      '';
    };

    version = self.shortRev or self.dirtyShortRev or "dirty";

    makeDll = configuration: backend: fast:
      pkgs.stdenvNoCC.mkDerivation {
        pname = "vox-populi-dll-${configuration}${if fast then "-fast" else ""}";
        inherit version;
        src = self;
        nativeBuildInputs = [vpBuild];
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          vp-build \
            --backend ${backend} \
            --config ${configuration} \
            ${if fast then "--fast" else ""} \
            --jobs "$NIX_BUILD_CORES" \
            --build-dir "$TMPDIR/vp-build" \
            --output-dir "$out" \
            --version "${version}"
          runHook postBuild
        '';
        dontInstall = true;
      };
  in {
    packages.${system} = {
      default = makeDll "release" "msvc" false;
      fast = makeDll "release" "msvc" true;
      debug = makeDll "debug" "msvc" false;
      clang-release = makeDll "release" "clang" false;
      clang-debug = makeDll "debug" "clang" false;
      toolchain = windowsSdk;
      msvc-toolchain = msvcToolchain;
      vp-build = vpBuild;
    };

    apps.${system} = {
      default = {
        type = "app";
        program = "${vpBuild}/bin/vp-build";
        meta.description = "Build the Vox Populi DLL from the repository working tree";
      };
      build = {
        type = "app";
        program = "${vpBuild}/bin/vp-build";
        meta.description = "Build the Vox Populi DLL from the repository working tree";
      };
    };

    checks.${system}.build-script = pkgs.runCommand "vp-build-script-check" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      cp ${./nix/build-vp.py} build-vp.py
      python3 -m py_compile build-vp.py
      touch "$out"
    '';

    devShells.${system}.default = pkgs.mkShellNoCC {
      packages = [
        vpBuild
        pkgs.lua-language-server
        pkgs.lua51Packages.luacheck
        pkgs.jujutsu
      ];
      VP_SDK_ROOT = windowsSdk;
      shellHook = ''
        echo "Vox Populi Windows build toolchain"
        echo "  MSVC v90 build:  vp-build --backend msvc --config release"
        echo "  Clang ABI build: vp-build --backend clang --config release"
      '';
    };
  };
}
