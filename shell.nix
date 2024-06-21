with import <nixpkgs> { };
mkShell {
  NIX_LD_LIBRARY_PATH = lib.makeLibraryPath [
    stdenv.cc.cc
    liburing.dev
  ];
  LD_LIBRARY_PATH = lib.makeLibraryPath [
    stdenv.cc.cc
    liburing.dev
  ];
  NIX_LD = lib.fileContents "${stdenv.cc}/nix-support/dynamic-linker";
  buildInputs = [
    stdenv.cc.cc
    liburing.dev
  ];
  INCLUDE = "${liburing.dev}/include";
}
