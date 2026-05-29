{
  lib,
  stdenv,
  fetchurl,
  python3Packages,
  autoPatchelfHook,
  # Runtime tools placed on omnara's PATH (see makeWrapperArgs below).
  git,
  cloudflared,
}:

let
  version = "1.7.0";

  # Per-platform wheels from the GitHub release. The omnara wheel is pure
  # Python (no compiled extension modules); it is only platform-specific
  # because it bundles a prebuilt `codex` helper binary under
  # omnara/_bin/codex/<platform>/codex. The cp313 ABI tag therefore requires
  # building against CPython 3.13 (nixpkgs `python3`).
  #
  # No aarch64-linux or musl wheel is published upstream, so those systems are
  # intentionally unsupported.
  wheels = {
    aarch64-darwin = {
      file = "omnara-1.7.0-cp313-cp313-macosx_11_0_arm64.whl";
      hash = "sha256-/z8h2+dXDw+5WMXGQptreriIrCbK/UqRk0lFYL889yM=";
    };
    x86_64-darwin = {
      file = "omnara-1.7.0-cp313-cp313-macosx_10_13_x86_64.whl";
      hash = "sha256-QdV6B/bcKdVGaLC7yyo43DIrtVUd53pxZmy7KiUQHjk=";
    };
    x86_64-linux = {
      file = "omnara-1.7.0-cp313-cp313-manylinux_2_28_x86_64.whl";
      hash = "sha256-bVl/SMX/lO9/fV/uB2YMh9kxI5H4z5pi0bmKZzbtvKg=";
    };
  };

  wheel =
    wheels.${stdenv.hostPlatform.system}
      or (throw "omnara: no upstream wheel for ${stdenv.hostPlatform.system}");

  src = fetchurl {
    url = "https://github.com/omnara-ai/omnara/releases/download/v${version}/${wheel.file}";
    inherit (wheel) hash;
  };

  # claude-code-sdk is a runtime dependency of omnara but is not yet packaged in
  # nixpkgs. It is pure Python (anyio + mcp), so we wrap its wheel here.
  claude-code-sdk = python3Packages.buildPythonPackage rec {
    pname = "claude-code-sdk";
    version = "0.0.25";
    format = "wheel";

    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/f5/41/c934058080f3233bbc95bc9abac5e0191bf336ad5f69a33b5f54a4737e88/claude_code_sdk-${version}-py3-none-any.whl";
      hash = "sha256-PWpO+VgYLzEdYFB3bSZ12bOWUKLbIhxYKgpRVkctzuM=";
    };

    propagatedBuildInputs = with python3Packages; [
      anyio
      mcp
    ];

    pythonImportsCheck = [ "claude_code_sdk" ];
    doCheck = false;

    meta = with lib; {
      description = "Python SDK for Claude Code";
      homepage = "https://github.com/anthropics/claude-code-sdk-python";
      license = licenses.mit;
    };
  };
in
python3Packages.buildPythonApplication {
  pname = "omnara";
  inherit version src;
  format = "wheel";

  nativeBuildInputs = lib.optionals stdenv.isLinux [
    # Patch the bundled `codex` ELF helper to find store libraries on Linux.
    autoPatchelfHook
  ];

  buildInputs = lib.optionals stdenv.isLinux [
    stdenv.cc.cc.lib
  ];

  # The bundled `codex` helper is only used for the optional Codex agent; if
  # autoPatchelf can't resolve every one of its libs, don't fail the whole
  # build over it.
  autoPatchelfIgnoreMissingDeps = stdenv.isLinux;

  # Stripping would invalidate the code signature of the bundled `codex`
  # Mach-O on macOS (and is pointless for the rest, which is Python bytecode).
  dontStrip = true;

  propagatedBuildInputs = with python3Packages; [
    requests
    urllib3
    aiohttp
    certifi
    websocket-client
    fastmcp
    fastapi
    uvicorn
    pydantic
    claude-code-sdk
  ];

  # Tools omnara shells out to at runtime:
  #   git         - omnara operates inside git repositories
  #   cloudflared - exposes local agent sessions over a Cloudflare tunnel
  # (The Codex agent uses the bundled _bin/codex; the Claude Code agent expects
  #  `claude` to already be on your PATH, which it is in a Claude Code session.)
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      git
      cloudflared
    ])
  ];

  pythonImportsCheck = [ "omnara" ];
  doCheck = false;

  meta = with lib; {
    description = "Omnara CLI/daemon - control and remote-drive AI agent sessions";
    homepage = "https://github.com/omnara-ai/omnara";
    license = licenses.asl20;
    mainProgram = "omnara";
    platforms = builtins.attrNames wheels;
    sourceProvenance = with sourceTypes; [
      binaryBytecode # the omnara wheel
      binaryNativeCode # the bundled codex helper
    ];
  };
}
