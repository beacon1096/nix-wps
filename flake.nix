{
  description = "WPS Office and related software packaged as Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = [ "x86_64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      wps365-cn = pkgs.callPackage ./pkgs/wps365-cn {};
      default = self.packages.${system}.wps365-cn;
    });
  };
}
