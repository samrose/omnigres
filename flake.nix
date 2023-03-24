{
  inputs = {
    nixpkgs_master.url = "github:NixOS/nixpkgs";
    nixpkgs.url = "nixpkgs/nixos-22.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs_master, nixpkgs, flake-utils }:
  flake-utils.lib.eachDefaultSystem
  (system:
      let cmake = nixpkgs_master.legacyPackages.${system}.cmake; in
      let clang-tools = nixpkgs_master.legacyPackages.${system}.clang-tools_15; in
      let pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShell = pkgs.mkShell { buildInputs = [ pkgs.pkgsStatic.openssl pkgs.pkgconfig cmake pkgs.flex pkgs.readline
                                                  pkgs.zlib clang-tools pkgs.python]; };
        packages = rec {
        omnigres = pkgs.stdenv.mkDerivation  {
          pname = "omnigres";
          version = "0.1.0";
          src = ./. ;

          buildInputs = [ pkgs.pkgsStatic.openssl pkgs.pkgconfig cmake pkgs.flex pkgs.readline
                                                  pkgs.zlib clang-tools pkgs.python]; 

          # Build and install the package
          installPhase = ''
            mkdir -p "$out"
            mkdir -p build
            cd build
            cmake -DCMAKE_BUILD_TYPE="Release" -DPG=15.2 $out/omni
            make -j all
            make package
          '';
          };

        default = omnigres;


        }; 
        
        }


      );
    
}
