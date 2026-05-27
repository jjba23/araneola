;; ggg: guile glyph generator

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; ggg is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ggg is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with ggg.  If not, see <https://www.gnu.org/licenses/>.

(use-modules (guix packages)
             (gnu)
             (guix utils)
             (guix git-download)
             (guix download)
             (gnu packages admin)
             (gnu packages guile)
             (gnu packages nss)
             (gnu packages gnupg)
             (gnu packages guile-xyz)
             (gnu packages pkg-config)
             (guix build-system guile)
             (gnu packages linux)
             (gnu packages compression)
             (gnu packages texinfo)
             (gnu packages autotools)
             (gnu packages rust-apps)
             (gnu packages tls)
             ((guix licenses)
              #:prefix license:))

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

(packages->manifest (list guile-3.0
                          watchexec
                          guile-documenta
                          texinfo
                          guile-lib
                          guile-gnutls
                          guile-scriba
                          guile-ares-rs))
