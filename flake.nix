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
      zig = zig-overlay.packages.${system}."0.16.0";
    in {
      default = pkgs.stdenv.mkDerivation {
        name = "bobrwm";
        src = ./.;
        nativeBuildInputs = [zig];
        SDKROOT = pkgs.apple-sdk.sdkroot;

        buildPhase = ''
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-cache
          zig build -Doptimize=ReleaseSafe --prefix $out
        '';

        # The build installs Bobrwm.app; expose the client and the swipe
        # companion on PATH the way the Homebrew cask's binary stanza does.
        # Bobrwm itself is deliberately not linked: it needs to run from
        # inside the bundle to pick up its CFBundleIdentifier.
        installPhase = ''
          mkdir -p $out/bin
          ln -s $out/Bobrwm.app/Contents/MacOS/bobrwm-cli $out/bin/bobrwm
          ln -s $out/Bobrwm.app/Contents/MacOS/bobrwm-swipe $out/bin/bobrwm-swipe
        '';
      };
    });

    devShells = forAllSystems ({
      pkgs,
      system,
    }: let
      zig = zig-overlay.packages.${system}."0.16.0";
      zls = zls-overlay.packages.${system}.zls;
      zigdoc = zigdoc-nix.packages.${system}.default;
      ziglint = ziglint-nix.packages.${system}.default;
    in {
      default = pkgs.mkShell {
        SDKROOT = pkgs.apple-sdk.sdkroot;
        buildInputs = [
          zig
        ];
        packages = [
          zls
          zigdoc
          ziglint
          pkgs.nushell
        ];
      };
    });
  };
}
