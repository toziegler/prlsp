{
  description = "prlsp - GitHub PR Review LSP Server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
      });
    in {
      packages = forAllSystems ({ pkgs, ... }:
        let
          prlsp-go = pkgs.buildGoModule {
            pname = "prlsp-go";
            version = "0.1.0";
            src = ./go;
            vendorHash = null;
          };
        in {
          default = prlsp-go;
          prlsp-go = prlsp-go;
        });

      apps = forAllSystems ({ pkgs, ... }: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/prlsp-go";
        };
      });

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          packages = [
            pkgs.go
            pkgs.gh
            pkgs.git
            self.packages.${pkgs.system}.default
          ];
        };
      });
    };
}
