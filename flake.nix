{
  description = "a fun tiny operating system";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.systems.url = "github:nix-systems/default";
  inputs.zig.url = "github:mitchellh/zig-overlay";

  outputs = inputs: let
    forEachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
    pkgs = forEachSystem(system: import inputs.nixpkgs {
      inherit system;
      overlays = [inputs.zig.overlays.default];
    });
  in {
    devShells.default = forEachSystem(system: {
      default = pkgs.${system}.mkShellNoCC {
        buildInputs = with pkgs.${system}; [
          zig
          zls
          gcc
          qemu_full
          pkg-config
          gnumake
          git
          curl
        ];

        OVMF_FD = "${pkgs.OVMF.fd}/FV/OVMF.fd";
        LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath buildInputs}";
      };
    });
  };
}
