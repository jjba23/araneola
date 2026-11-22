;; araneola - high-performance web crawler and sitemap generator
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; The channels this project is built against.  Guix itself is pinned to a
;; commit, and so is the jointhefreeworld channel: the collection's packages -
;; scriba and guile-dokgen among them - come from there rather than from the
;; copies Guix carries, which lag behind the releases.
;;
;; manifest.scm and guix.scm import the channel's modules with a `jtf:' prefix,
;; so which release a build gets is written down instead of left to import
;; order.
;;
;; Both pins are moved together: the channel's packages are written against
;; the Guix revision above, and a package that a newer Guix moved would fail
;; to evaluate against an older one.
;;
;;; Code:

(list (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix.git")
        (branch "master")
        (commit "5cea8de04500ba7904e02ee7b53178fb06856e13")
        (introduction
         (make-channel-introduction "9edb3f66fd807b096b48283debdcddccfea34bad"
          (openpgp-fingerprint
           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
        (name 'jointhefreeworld)
        (url "https://github.com/jjba23/guix-jointhefreeworld")
        (branch "trunk")
        ;; The release this project is built against: guile-dokgen 0.11.0 and
        ;; the rest of the collection, at the same revision.
        (commit "fafafe4e22b43dc89037facf8bd4c8977c4c7146")
        (introduction
         (make-channel-introduction
          "b0ac3f05075d7959860fc9e1db5871acddea3986"
          (openpgp-fingerprint
           "83BC 6E1C 8726 B8C2 97F8  D16E 24F4 6738 CE11 4AF6")))))
