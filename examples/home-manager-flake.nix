{
  description = "Example: a standalone Home Manager config that runs the Omnara daemon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Point this at wherever you host omnara-nix:
    omnara.url = "github:rksm/omnara-nix";
  };

  outputs =
    { nixpkgs, home-manager, omnara, ... }:
    let
      # Adjust to your machine.
      system = "aarch64-darwin"; # or "x86_64-linux", "x86_64-darwin"
      username = "alice";
      homeDirectory = if nixpkgs.legacyPackages.${system}.stdenv.isDarwin then "/Users/${username}" else "/home/${username}";

      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # Build with:   home-manager switch --flake .#alice
      # (or:          nix run home-manager -- switch --flake .#alice )
      homeConfigurations.${username} = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          # 1. Bring in the Omnara service module.
          omnara.homeManagerModules.default

          # 2. Your home configuration.
          {
            home = {
              inherit username homeDirectory;
              stateVersion = "24.11";
            };

            # Run `omnara daemon run-service` as a launchd (macOS) / systemd
            # (Linux) user service that auto-starts on login.
            services.omnara = {
              enable = true;

              # Defaults to [ "daemon" "run-service" ]. For example:
              # command = [ "daemon" "run-service" "--sandbox-mode" ];

              # Extra tools on the service PATH (git + cloudflared are already
              # provided by the package). E.g. if your agent needs node:
              # path = [ pkgs.nodejs ];

              # Non-secret env only -- the Nix store is world-readable.
              # Authenticate with `omnara --auth` (stored under ~/.omnara).
              # environment = { OMNARA_BASE_URL = "https://api.example.com"; };
            };

            # The omnara CLI itself, available in your shell.
            home.packages = [ omnara.packages.${system}.omnara ];
          }
        ];
      };
    };
}
