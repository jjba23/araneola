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

(define-module (araneola araneola)
  #:declarative? #t
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (sxml simple)
  #:use-module (ice-9 getopt-long)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (htmlprag)
  #:use-module (srfi srfi-19)
  #:use-module (scriba scriba)
  #:export (extract-links-from-sxml))

(define* (extract-links-from-sxml #:key parent-domain url sxml)
  "Recursively walks the SXML tree and extracts all interesting 'href' values."
  (let loop
    ((tree sxml)
     (acc '()))
    (match tree
      (((quote a) ((quote @) attrs ...) . body) (let* ((href-pair (assq 'href
                                                                        attrs))
                                                       (raw-href (and
                                                                  href-pair
                                                                  (cadr
                                                                   href-pair)))
                                                       (href-val (and raw-href
                                                                  (cond
                                                                    ((string-prefix?
                                                                      "//"
                                                                      raw-href)
                                                                     (string-append
                                                                      "https:"
                                                                      raw-href))
                                                                    ((string-prefix?
                                                                      "/"
                                                                      raw-href)
                                                                     (normalize-url
                                                                      parent-domain
                                                                      raw-href))
                                                                    (else
                                                                     raw-href)))))
                                                  (if (and href-val
                                                           (is-interesting-url?
                                                            #:parent-domain
                                                            parent-domain
                                                            #:url href-val))
                                                      (loop body
                                                            (cons href-val acc))
                                                      (loop body acc))))
      ((tag ((quote @) attrs ...) . body) (loop body acc))
      ((head . tail) (loop tail
                           (loop head acc)))
      (_ acc))))
