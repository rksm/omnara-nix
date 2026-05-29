# Home Manager module for running the Omnara daemon as a user service.
#
# Exposed from the flake as `homeManagerModules.default`. It closes over the
# flake's `self` only to default `services.omnara.package` to the package this
# flake builds (so consumers don't have to add the overlay).
#
# macOS -> launchd user agent; Linux -> systemd user service.
self:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.omnara;
  system = pkgs.stdenv.hostPlatform.system;
  defaultPackage = self.packages.${system}.omnara or null;
  binPath = lib.makeBinPath ([ cfg.package ] ++ cfg.path);
in
{
  options.services.omnara = {
    enable = lib.mkEnableOption "the Omnara daemon as a user service (runs `omnara daemon run-service`)";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "omnara.packages.\${system}.omnara";
      description = "The omnara package to run.";
    };

    command = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "daemon" "run-service" ];
      example = [ "daemon" "run-service" "--sandbox-mode" ];
      description = ''
        Arguments passed to `omnara`. Defaults to `daemon run-service`, the
        foreground daemon entry point that launchd/systemd supervises (the same
        command the upstream installer's service runs). Don't use
        `daemon start`/`stop` here -- those are user-facing wrappers that manage
        a separately-launched daemon.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { OMNARA_BASE_URL = "https://api.example.com"; };
      description = ''
        Extra environment variables for the service.

        Do NOT put secrets such as API keys here: they would be written to the
        world-readable Nix store. Authenticate once with `omnara --auth` (which
        stores credentials under ~/.omnara) or inject secrets via a secrets
        manager.
      '';
    };

    path = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.nodejs ]";
      description = ''
        Extra packages placed on the service's PATH, e.g. the `claude` CLI
        needed by the Claude Code agent. `git` and `cloudflared` are already
        wired in by the package wrapper.
      '';
    };

    logFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.omnara/logs/daemon.log";
      description = "Log file path (used by launchd on macOS). On Linux, logs go to the systemd journal.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "services.omnara: no omnara package for ${system}; set services.omnara.package explicitly.";
      }
    ];

    # macOS: launchd needs the log directory to exist up front.
    home.activation = lib.mkIf pkgs.stdenv.isDarwin {
      omnaraLogDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p $VERBOSE_ARG "$(dirname ${lib.escapeShellArg cfg.logFile})"
      '';
    };

    launchd.agents.omnara = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      config = {
        ProgramArguments = [ "${cfg.package}/bin/omnara" ] ++ cfg.command;
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = cfg.logFile;
        StandardErrorPath = cfg.logFile;
        WorkingDirectory = config.home.homeDirectory;
        EnvironmentVariables = { OMNARA_NO_UPDATE = "1"; } // cfg.environment // {
          PATH = "${binPath}:/usr/bin:/bin";
        };
      };
    };

    systemd.user.services.omnara = lib.mkIf pkgs.stdenv.isLinux {
      Unit = {
        Description = "Omnara daemon";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        ExecStart = "${cfg.package}/bin/omnara ${lib.escapeShellArgs cfg.command}";
        Restart = "on-failure";
        RestartSec = 5;
        Environment =
          # OMNARA_NO_UPDATE first so a user-provided value in `environment` wins.
          [ "PATH=${binPath}:/run/current-system/sw/bin" "OMNARA_NO_UPDATE=1" ]
          ++ lib.mapAttrsToList (n: v: "${n}=${v}") cfg.environment;
      };
    };
  };
}
