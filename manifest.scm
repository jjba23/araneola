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
             ;; The channel pinned in channels.scm carries the release the
             ;; collection is built against; the prefix keeps it apart from the
             ;; older copies Guix itself carries.
             ((jointhefreeworld packages guile)
              #:prefix jtf:)
             ((guix licenses)
              #:prefix license:))

(packages->manifest (list guile-3.0
                          watchexec
                          guile-documenta
                          texinfo
                          guile-lib
                          guile-gnutls
                          ;; scriba logs through (scriba json), which needs it.
                          guile-json-4
                          jtf:guile-scriba
                          guile-ares-rs))
