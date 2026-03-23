{
  description = "WPS Office and related software packaged as Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "loongarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in {
    packages = forAllSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        config = { allowUnfree = true; };
      };
      
      linuxSystems = [ "x86_64-linux" "aarch64-linux" "loongarch64-linux" ];
    in
      (pkgs.lib.optionalAttrs (pkgs.lib.elem system linuxSystems) {
        wps365-cn = pkgs.callPackage ./pkgs/wps365-cn {};
      })
      // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
        wpsoffice-xa = pkgs.callPackage ./pkgs/wpsoffice-xa {};
      }
      // pkgs.lib.optionalAttrs (pkgs.lib.elem system [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ]) {
        wpsoffice-cn = pkgs.callPackage ./pkgs/wpsoffice-cn {};
      }
      // {
        default = if (pkgs.lib.elem system linuxSystems) then
          pkgs.callPackage ./pkgs/wps365-cn {}
        else if (pkgs.lib.elem system [ "x86_64-darwin" "aarch64-darwin" ]) then
          pkgs.callPackage ./pkgs/wpsoffice-cn {}
        else
          null;
      }
    );
  };
}
