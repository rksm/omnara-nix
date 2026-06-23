{
  lib,
  stdenv,
  fetchurl,
  unzip,
  makeWrapper,
  autoPatchelfHook,
  # Runtime tools placed on omnara's PATH (see postFixup).
  git,
  cloudflared,
}:

let
  # The current Omnara CLI is a self-contained, frozen (Node-based) binary
  # distributed only from releases.omnara.com/latest. There is NO version-pinned
  # URL upstream -- `/latest` mutates in place -- so the hashes below pin a
  # specific build by content. When upstream ships a new build the hash will no
  # longer match (and the old artifact 404s); run ./scripts/update-omnara.sh to
  # re-pin. See README "Reproducibility caveat".
  version = "0.25.14";

  base = "https://releases.omnara.com/latest";

  sources = {
    aarch64-darwin = {
      url = "${base}/omnara-darwin-arm64.zip";
      hash = "sha256-FyjIjgIv2mT3bzYXl+DL46TeIh85+cMx7QAiVGFH228=";
    };
    x86_64-darwin = {
      url = "${base}/omnara-darwin-x64.zip";
      hash = "sha256-DUe+UrQpPgo8xXddoHjIAdXhABSFSQpKS3ai4AzE0vw=";
    };
    x86_64-linux = {
      url = "${base}/omnara-linux-x64";
      hash = "sha256-opHl8BbAcb5v3dEtZDkKrdgAOuCg1Tt6OTnh5GYxx8Q=";
    };
    aarch64-linux = {
      url = "${base}/omnara-linux-arm64";
      hash = "sha256-CDO1oMSaUaCJ9mGTJQHYksDP07/a/nnufHL9dBL37sw=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "omnara: no upstream artifact for ${stdenv.hostPlatform.system}");

  src = fetchurl { inherit (source) url hash; };
in
stdenv.mkDerivation {
  pname = "omnara";
  inherit version src;

  nativeBuildInputs =
    [ makeWrapper ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ unzip ]
    # Patch the frozen ELF to use the store's dynamic linker on Linux.
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
  ];

  dontConfigure = true;
  dontBuild = true;

  # Do not strip: it would invalidate the macOS code signature and serves no
  # purpose for an already-built, self-contained binary.
  dontStrip = true;

  # The Linux artifact is a bare binary (no archive); the macOS artifact is a
  # zipped, code-signed .app bundle. fetchurl gives us the file directly.
  unpackPhase = ''
    runHook preUnpack
    case "$src" in
      *.zip) unzip -q "$src" -d unpacked ;;
      *)     cp "$src" omnara ;;
    esac
    runHook postUnpack
  '';

  # Tools omnara shells out to at runtime (wired onto PATH via the wrapper):
  #   git         - omnara tracks work per git repository/branch
  #   cloudflared - exposes the daemon/sessions over a Cloudflare tunnel
  # The Claude Code / Codex agents expect `claude` / `codex` already on PATH.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec

    if [ -f omnara ]; then
      # Linux: a bare frozen binary (autoPatchelfHook fixes its interpreter).
      install -Dm755 omnara $out/libexec/omnara
      real=$out/libexec/omnara
    else
      # macOS: keep the WHOLE signed .app bundle intact. The executable's
      # Developer ID + hardened-runtime signature only validates with its
      # bundle context (Info.plist, _CodeSignature); extracting the bare
      # binary makes AMFI SIGKILL it. We must not strip/modify anything inside.
      app="$(find unpacked -maxdepth 2 -name '*.app' -type d | head -1)"
      if [ -z "$app" ]; then
        echo "omnara: no .app bundle found in artifact" >&2
        find unpacked -maxdepth 2 >&2
        exit 1
      fi
      cp -R "$app" $out/libexec/Omnara.app
      real=$out/libexec/Omnara.app/Contents/MacOS/omnara
      chmod +x "$real"
    fi

    # OMNARA_NO_UPDATE: the binary lives in the read-only Nix store, so its
    # self-updater can't work -- disable it by default (override by exporting
    # OMNARA_NO_UPDATE yourself; use Nix to update instead).
    makeWrapper "$real" $out/bin/omnara \
      --set-default OMNARA_NO_UPDATE 1 \
      --prefix PATH : ${lib.makeBinPath [ git cloudflared ]}

    runHook postInstall
  '';

  # Linux-only: on macOS the Nix build sandbox both restricts the signed binary
  # and the frozen binary perturbs the .app at first run, so we verify the
  # macOS build by running it after install instead (see README).
  doInstallCheck = stdenv.hostPlatform.isLinux;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME=$(mktemp -d)
    OMNARA_NO_UPDATE=1 $out/bin/omnara --version
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "Omnara CLI/daemon - control and remote-drive AI agent sessions";
    homepage = "https://omnara.com";
    downloadPage = "https://github.com/omnara-ai/omnara";
    license = licenses.asl20;
    mainProgram = "omnara";
    platforms = builtins.attrNames sources;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
