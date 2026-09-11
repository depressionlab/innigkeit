{
  description = "a fun tiny operating system";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  inputs.systems.url = "github:nix-systems/default";
  inputs.systems.inputs.nixpkgs.follows = "nixpkgs";
  inputs.zig.url = "github:mitchellh/zig-overlay";
  inputs.zig.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    inputs:
    let
      forEachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
      pkgs = forEachSystem (
        system:
        import inputs.nixpkgs {
          inherit system;
          overlays = [ inputs.zig.overlays.default ];
        }
      );
    in
    {
      devShells = forEachSystem (system: {
        default = pkgs.${system}.mkShellNoCC (rec {
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

          LD_LIBRARY_PATH = "${pkgs.${system}.lib.makeLibraryPath buildInputs}";
        });
      });
    };
}
