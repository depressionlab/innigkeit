{
  description = "a fun tiny operating system";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  inputs.zig.url = "github:silversquirl/zig-flake";
  inputs.zig.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, zig, ... }:
    let forAllSystems = f: builtins.mapAttrs (
      system: pkgs: f pkgs zig.packages.${system}.zig_0_16_0
    ) nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems(pkgs: zig: {
      default = pkgs.mkShellNoCC {
        packages = [
          zig
          zig.zls
          pkgs.gcc
          pkgs.qemu_full
          pkgs.pkg-config
          pkgs.gnumake
          pkgs.gitMinimal
          pkgs.curl
          pkgs.ninja
        ];
      };
    });

    packages = forAllSystems(pkgs: zig: {
      default = zig.makePackage {
        pname = "innigkeit";
        version = "0.1.0";
        src = ./.;
        zigReleaseMode = "fast";
      };
    });
  };
}
