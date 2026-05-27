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
             (gnu packages guile-xyz))

(define-public guile-scriba
  (package
    (name "guile-scriba")
    (version "0.0.8")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://codeberg.org/jjba23/scriba.git")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0bz8i2nkq0bvizsj2g15x8m11zb0gbfs36dfnilj7v19czzswbln"))))
    (propagated-inputs (list guile-json-4))
    (build-system guile-build-system)
    (native-inputs (list guile-3.0))
    (arguments
     (list
      #:source-directory "src"))
    (home-page "https://codeberg.org/jjba23/scriba")
    (synopsis "Structured logging framework for Guile Scheme")
    (description
     "Scriba is a structured logging library for GNU Guile that prioritizes
flexibility and observability.  It provides modular log routing, formatting,
and filtering, allowing developers to generate human-readable console logs
during development and machine-readable JSON logs for production environments.
Key features include an auto-logger configured via environment variables,
dynamically scoped log contexts using Scheme parameters, ahead-of-time log
level filtering, and minimal runtime overhead achieved through memoization
and compile-time macros.")
    (license license:lgpl3+)))

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
    (native-inputs (list guile-3.0))
    (inputs (list guile-3.0 bash-minimal guile-scriba guile-lib guile-gnutls))
    (synopsis "")
    (description "")
    (home-page "https://codeberg.org/jjba23/araneola")
    (license license:agpl3+)))

araneola
