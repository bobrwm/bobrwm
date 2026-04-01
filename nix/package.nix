{
  lib,
  stdenv,
  callPackage,
  zig,
}:
let
  zigDeps = callPackage ./deps.nix {};
in
stdenv.mkDerivation {
  pname = "bobrwm";
  version = "0.1.0";

  # Limit source to build-essential files to minimise rebuilds.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.intersection (lib.fileset.fromSource (lib.sources.cleanSource ../.)) (
      lib.fileset.unions [
        ../src
        ../res
        ../build.zig
        ../build.zig.zon
      ]
    );
  };

  nativeBuildInputs = [zig];

  dontConfigure = true;
  dontInstall = true;

  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-cache
    zig build -Doptimize=ReleaseSafe --system ${zigDeps} --prefix $out
  '';
}
