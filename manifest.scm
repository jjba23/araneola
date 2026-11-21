;; araneola - high-performance web crawler and sitemap generator
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

(use-modules (guix packages)
             (gnu)
             (gnu packages)
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
                          ;; guile-dokgen comes from the jointhefreeworld
                          ;; channel, which is why channels.scm pins it: the
                          ;; name is resolved against the channels the
                          ;; manifest is read with.
                          (specification->package "guile-dokgen")
                          ;; The highest Texinfo, not the bare `texinfo'
                          ;; binding (6.8): dokgen's stylesheet and script
                          ;; target the definition structure 7.x emits.
                          (specification->package "texinfo")
                          guile-lib
                          guile-gnutls
                          ;; scriba logs through (scriba json), which needs it.
                          guile-json-4
                          jtf:guile-scriba
                          guile-ares-rs))
