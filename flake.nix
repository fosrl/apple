{
  description = "Official Pangolin macOS VPN client";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = {flake-parts, ...} @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-darwin" "aarch64-darwin"];

      perSystem = {pkgs, ...}: {
        devShells.default = pkgs.mkShellNoCC {
          name = "pangolin-apple-shell";
          packages = let
            go = pkgs.go.overrideAttrs (o: {
              patches = [
                ./PangolinGo/goruntime-boottime-over-monotonic.diff
              ];
            });
          in [
            go
            pkgs.golangci-lint
          ];
        };
      };
    };
}
