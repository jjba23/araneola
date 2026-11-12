;; araneola - high-performance web crawler and sitemap generator
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;
;; The channels this project is built against.  Guix itself is pinned to a
;; commit, and so is the jointhefreeworld channel: the collection's packages -
;; scriba among them - come from there rather than from the copies Guix
;; carries, which lag behind the releases.  The channel carries scriba 0.5.1.
;;
;; manifest.scm and guix.scm import the channel's modules with a `jtf:' prefix,
;; so which release a build gets is written down instead of left to import
;; order.
;;
;;; Code:

(list (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix.git")
        (branch "master")
        (commit "3b4e87350015c5e5223bcfd5043837e63fd6d635")
        (introduction
         (make-channel-introduction "9edb3f66fd807b096b48283debdcddccfea34bad"
          (openpgp-fingerprint
           "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
      (channel
        (name 'jointhefreeworld)
        (url "https://codeberg.org/jjba23/guix-jointhefreeworld")
        (branch "trunk")
        ;; The release this project is built against: scriba 0.5.1, and the
        ;; rest of the collection, at the same revision.
        (commit "872c1e2ee0cee99e49472bfbfaf3a7e5975b1c2d")
        (introduction
         (make-channel-introduction
          "b0ac3f05075d7959860fc9e1db5871acddea3986"
          (openpgp-fingerprint
           "83BC 6E1C 8726 B8C2 97F8  D16E 24F4 6738 CE11 4AF6")))))
