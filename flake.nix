{
  description = "bobrwm — tiling window manager for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls-overlay.url = "github:zigtools/zls";
    zigdoc-nix.url = "github:uzaaft/zigdoc-nix";
    ziglint-nix.url = "github:uzaaft/ziglint-nix";
  };

  outputs = {
    self,
    nixpkgs,
    zig-overlay,
    zls-overlay,
    zigdoc-nix,
    ziglint-nix,
    ...
  }: let
    allSystems = ["aarch64-darwin"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs allSystems (system:
        f {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit system;
        });
  in {
    packages = forAllSystems ({
      pkgs,
      system,
    }: {
      default = pkgs.callPackage ./nix/package.nix {
        zig = zig-overlay.packages.${system}."0.15.1";
      };
    });

    overlays.default = final: _prev: {
      bobrwm = self.packages.${final.system}.default;
    };

    darwinModules.default = import ./nix/darwin-module.nix self;

    devShells = forAllSystems ({
      pkgs,
      system,
    }: {
      default = pkgs.callPackage ./nix/devShell.nix {
        zig = zig-overlay.packages.${system}."0.15.1";
        zls = zls-overlay.packages.${system}.zls;
        zigdoc = zigdoc-nix.packages.${system}.default;
        ziglint = ziglint-nix.packages.${system}.default;
        inherit (pkgs) nushell;
      };
    });
  };
}
