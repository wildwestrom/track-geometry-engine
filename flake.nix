{
  description = "very minimal flake";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        legacyPackages = pkgs;
        devShell = pkgs.mkShell {
          packages = [
            # Build tools
            pkgs.gnuplot

            # C
            pkgs.clang-tools
            pkgs.pkg-config
            pkgs.stdenv.cc

            # Lean
            pkgs.elan

            # Graphics
            pkgs.libGL
            pkgs.glfw

            # X11 dependencies
            pkgs.libx11
            pkgs.libx11.dev
            pkgs.libxcursor
            pkgs.libxi
            pkgs.libxinerama
            pkgs.libxrandr

            # Wayland dependencies
            pkgs.wayland
            pkgs.wayland-scanner
            pkgs.libxkbcommon
          ];

          # Audio dependencies
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.alsa-lib ];
        };
      }
    );
}
