{
  description = "Example: consume omnara-nix via its overlay";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Point this at wherever you host omnara-nix:
    omnara.url = "github:rksm/omnara-nix";
  };

  outputs =
    { self, nixpkgs, flake-utils, omnara }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ omnara.overlays.default ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [ pkgs.omnara ];
        };
      }
    );
}
