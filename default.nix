# araneola

# Copyright © Josep Bigorra <jjbigorra@gmail.com>

# araneola is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# araneola is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with araneola.  If not, see <https://www.gnu.org/licenses/>.

# The package of this checkout as it stands.  It is the same derivation as the
# `araneola' package in nixpkgs -- same phases, same layout under $out -- so
# that a change which breaks this build breaks that one for the same reason.
# What differs is the source: this file builds the working tree, while nixpkgs
# pins a released tag and its hash.  Keep `version' in step with the tag you
# release, because nothing here can read it from the library.

{ lib
, stdenv
, guile
, makeWrapper
, bash
, coreutils
, util-linux
, guile-scriba
, guile-lib
, guile-gnutls
}:

stdenv.mkDerivation {
  pname = "araneola";
  version = "0.0.2";

  src = ./.;

  nativeBuildInputs = [
    guile
    makeWrapper
  ];

  buildInputs = [ guile ];

  propagatedBuildInputs = [
    guile-scriba
    guile-lib
    guile-gnutls
  ];

  buildPhase = ''
    runHook preBuild

    siteDir=$out/${guile.siteDir}
    install -d "$siteDir"
    cp -R src/. "$siteDir"/

    export GUILE_AUTO_COMPILE=0
    export GUILE_LOAD_PATH="$siteDir''${GUILE_LOAD_PATH:+:$GUILE_LOAD_PATH}"

    find src -name '*.scm' | while IFS= read -r file; do
      rel="''${file#src/}"
      guild compile -o "$siteDir/''${rel%.scm}.go" "$file"
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 scripts/araneola $out/bin/araneola
    install -Dm644 scripts/log.bash $out/share/scripts/log.bash
    install -Dm644 resources/help.txt $out/share/resources/help.txt

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/araneola \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          util-linux
          guile
        ]
      } \
      --prefix GUILE_LOAD_PATH : "$out/${guile.siteDir}:${
        lib.makeSearchPath "share/guile/site/3.0" [
          guile-scriba
          guile-lib
          guile-gnutls
        ]
      }" \
      --prefix GUILE_LOAD_COMPILED_PATH : "$out/${guile.siteDir}:${
        lib.makeSearchPath "share/guile/site/3.0" [
          guile-scriba
          guile-lib
          guile-gnutls
        ]
      }"
  '';

  meta = with lib; {
    description = "Web crawler and sitemap generator written in GNU Guile";
    homepage = "https://codeberg.org/jjba23/araneola";
    license = licenses.agpl3Plus;
    mainProgram = "araneola";
    platforms = platforms.linux;
  };
}
