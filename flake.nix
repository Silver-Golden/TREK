{
  description = "TREK self-hosted travel planner";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
        trek = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      });

      nixosModules.default = import ./nix/module.nix;
      nixosModules.trek = self.nixosModules.default;
    };
}
