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
    }: let
      zig = zig-overlay.packages.${system}."0.15.1";
    in {
      default = pkgs.stdenv.mkDerivation {
        name = "bobrwm";
        src = ./.;
        nativeBuildInputs = [zig];

        buildPhase = ''
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-cache
          zig build -Doptimize=ReleaseSafe --prefix $out
        '';

        dontInstall = true;
      };
    });

    devShells = forAllSystems ({
      pkgs,
      system,
    }: let
      zig = zig-overlay.packages.${system}."0.15.1";
      zls = zls-overlay.packages.${system}.zls;
      zigdoc = zigdoc-nix.packages.${system}.default;
      ziglint = ziglint-nix.packages.${system}.default;
    in {
      default = pkgs.mkShell {
        buildInputs = [
          zig
          zls
          zigdoc
          ziglint
        ];
      };
    });
  };
}
