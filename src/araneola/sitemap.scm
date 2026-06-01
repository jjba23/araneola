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
  #:use-module (sxml simple)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (write-sitemap-header write-sitemap-item write-sitemap-footer))

(define (write-sitemap-header port)
  "Writes the initial XML declaration and opens the root urlset element."
  (display "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" port)
  (display "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">
"
           port)
  (force-output port))

(define (write-sitemap-item port url lastmod)
  "Appends a single isolated <url> element to the sitemap stream instantly."
  (let ((item-sxml `(url (loc ,url)
                         ,@(if lastmod
                               `((lastmod ,lastmod))
                               '()))))
    (display "  " port)
    (sxml->xml item-sxml port)
    (newline port)
    (force-output port)))

(define (write-sitemap-footer port)
  "Closes the root urlset element."
  (display "</urlset>\n" port)
  (force-output port))
