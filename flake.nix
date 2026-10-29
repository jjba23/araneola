# araneola - high-performance web crawler and sitemap generator
#
# SPDX-License-Identifier: MIT
# Copyright © Josep Bigorra <jjbigorra@gmail.com>

{
  description = "Araneola - web crawler and sitemap generator in GNU Guile";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # guile-scriba has no package in nixpkgs yet, so the branch of this fork
    # that adds one is an input and the overlay below reads the package from
    # it.  Drop the input and the overlay together, once that branch is merged
    # and nixos-unstable carries guile-scriba.
    guile-scriba-src = {
      url = "github:jjba23/nixpkgs/guile-scriba-init";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, guile-scriba-src }:
    let
      # The launcher is a bash script that shells out to util-linux and
      # coreutils, so the package is as portable as those are.
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [
          (final: prev: {
            guile-scriba = final.callPackage
              "${guile-scriba-src}/pkgs/by-name/gu/guile-scriba/package.nix" { };
          })
        ];
      };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          araneola = pkgs.callPackage ./default.nix { };
          default = self.packages.${system}.araneola;
        });

      apps = forAllSystems (system: {
        araneola = {
          type = "app";
          program = "${self.packages.${system}.araneola}/bin/araneola";
        };
        default = self.apps.${system}.araneola;
      });

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.araneola ];
            packages = with pkgs; [
              guile
              guile-scriba
              guile-lib
              guile-gnutls
            ];
            shellHook = ''
              export GUILE_LOAD_PATH="$PWD/src''${GUILE_LOAD_PATH:+:$GUILE_LOAD_PATH}"
            '';
          };
        });
    };
}
