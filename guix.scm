;; araneola: guile glyph generator

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; araneola is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; araneola is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with araneola.  If not, see <https://www.gnu.org/licenses/>.

(use-modules (guix gexp)
             (guix packages)
             (guix git-download)
             ((guix licenses)
              #:prefix license:)
             (guix build-system guile)
             ((guix build utils)
              #:select (with-directory-excursion ))
             (gnu packages)
             (gnu packages bash)
             (gnu packages guile)
             (gnu packages tls)
             (gnu packages guile-xyz)
             ;; The release the channel in channels.scm pins, imported with a
             ;; prefix so it cannot be confused with Guix's older copy.
             ((jointhefreeworld packages guile)
              #:prefix jtf:))

(define %source-dir
  (dirname (current-filename)))

(define-public araneola
  (package
    (name "araneola")
    (version "dev")
    (source
     (local-file %source-dir
                 #:recursive? #t
                 #:select? (git-predicate %source-dir)))
    (arguments
     (list
      #:source-directory "src"
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'build 'install-program-files
            (lambda _
              (let ((bin (string-append #$output "/bin"))
                    (share (string-append #$output "/share")))
                (install-file "resources/help.txt"
                              (string-append share "/resources"))
                (install-file "scripts/araneola" bin)
                (install-file "scripts/log.bash"
                              (string-append share "/scripts/"))
                (chmod (string-append bin "/araneola") #o755))))

          (add-after 'install-program-files 'wrap-executable
            (lambda _
              (wrap-program (string-append #$output "/bin/araneola")
                `("GUILE_LOAD_PATH" ":" prefix
                  (,(getenv "GUILE_LOAD_PATH")))
                `("GUILE_LOAD_COMPILED_PATH" ":" prefix
                  (,(getenv "GUILE_LOAD_COMPILED_PATH")))))))))
    (build-system guile-build-system)
    (propagated-inputs (list jtf:guile-scriba))
    (native-inputs (list guile-3.0))
    (inputs (list guile-3.0 bash-minimal guile-lib guile-gnutls))
    (synopsis "")
    (description "")
    (home-page "https://codeberg.org/jjba23/araneola")
    (license license:agpl3+)))

araneola
