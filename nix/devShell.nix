{
  mkShell,
  zig,
  zls,
  zigdoc,
  ziglint,
  nushell,
}:
mkShell {
  buildInputs = [
    zig
    zls
    zigdoc
    ziglint
    nushell
  ];
}
