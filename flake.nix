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
          packages = with pkgs; [
            # C
            clang-tools
            pkg-config
            stdenv.cc

            # Lean
            openssl
            elan

            # Graphics
            libGL
            glfw

            # X11 dependencies
            libx11
            libx11.dev
            libxcursor
            libxi
            libxinerama
            libxrandr

            # Wayland dependencies
            wayland
            wayland-scanner
            libxkbcommon

            # Lua and Teal
            (lua.withPackages (ps: [ ps.tl ps.teal-language-server ]))
          ];

          # Audio dependencies
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.alsa-lib ];
        };
      }
    );
}
