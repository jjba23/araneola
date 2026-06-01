;; araneola

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; araneola is free software: you can redistribute it and/or modify
;; it under the terms of the Lesser GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; araneola is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; Lesser GNU General Public License for more details.

;; You should have received a copy of the Lesser GNU General Public License
;; along with araneola.  If not, see <https://www.gnu.org/licenses/>.

;; araneola: guile glyph generator
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

(define-module (araneola sitemap)
  #:declarative? #t
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (sxml simple)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (write-sitemap links->sitemap))

(define (write-sitemap sxml filename)
  "Takes a SXML tree and writes a valid sitemap.xml."
  (let* ((s (scriba-auto-logger))
         (out-port (open-output-file filename)))
    (with-log-context `((filename unquote filename))
                      (log-info s "Writing sitemap to file")
                      (sxml->xml sxml out-port)
                      (close-port out-port)
                      (log-success s "Wrote sitemap to file"))))

(define (links->sitemap xs)
  "Generates a valid sitemap SXML structure from the visited-urls parameter."
  (let* ((xs (hash-map->list (lambda (k v)
                               (acons 'url k v)) xs))
         (sitemap-sxml `(*TOP* (*PI* xml "version=\"1.0\" encoding=\"UTF-8\"")
                               (urlset (@ (xmlns
                                           "http://www.sitemaps.org/schemas/sitemap/0.9"))
                                       ,@(map (lambda (x)
                                                (let ((url (assq-ref x
                                                                     'url))
                                                      (lastmod (assq-ref x
                                                                         'last-modified)))
                                                  `(url (loc ,url)
                                                        ,@(if lastmod
                                                              `((lastmod ,lastmod))
                                                              '())))) xs)))))
    sitemap-sxml))
