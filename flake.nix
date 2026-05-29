{
  description = "Omnara CLI/daemon packaged as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Used only to verify the Home Manager module (see checks); the module
    # itself does not depend on this input.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, flake-utils, home-manager }:
    {
      overlays.default = final: prev: {
        omnara = final.callPackage ./default.nix { };
      };

      # Home Manager module: `services.omnara.enable = true;` runs the Omnara
      # server as a launchd (macOS) / systemd (Linux) user service.
      homeManagerModules.default = import ./modules/home-manager.nix self;
      homeManagerModules.omnara = self.homeManagerModules.default;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
      in
      {
        packages.default = pkgs.omnara;
        packages.omnara = pkgs.omnara;

        # `nix run .` -> runs the omnara CLI.
        apps.default = {
          type = "app";
          program = "${pkgs.omnara}/bin/omnara";
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.omnara ];
        };

        # Evaluate + build a Home Manager config that enables the service, so
        # the module is verified by `nix flake check`.
        checks.homeManagerService =
          (home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              self.homeManagerModules.default
              {
                home.username = "omnara-test";
                home.homeDirectory =
                  if pkgs.stdenv.isDarwin then "/Users/omnara-test" else "/home/omnara-test";
                home.stateVersion = "24.11";
                # We follow nixpkgs-unstable into home-manager for this check,
                # so the HM/nixpkgs release tags don't line up. Harmless here.
                home.enableNixpkgsReleaseCheck = false;
                services.omnara.enable = true;
              }
            ];
          }).activationPackage;
      }
    );
}
