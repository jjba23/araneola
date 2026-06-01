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

(define-module (araneola main)
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
  #:use-module (araneola sitemap)
  #:use-module (araneola araneola)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (main))




(define* (main #:key (args (command-line)))
  (let* ((option-spec '((resources (single-char #\r)
                                   (value #t))
                        (url (single-char #\u)
                             (value #t)
                             (required? #t))))
         (options (getopt-long args option-spec))
         (s (scriba-auto-logger))
         (raw-url (option-ref options
                              'url #f))
         (url (cond
                ((string-prefix? "https://" raw-url)
                 raw-url)
                ((string-prefix? "http://" raw-url)
                 raw-url)
                (else (string-append "https://" raw-url)))))

    (with-log-context `((url unquote url))
                      (log-info s "Araneola is starting"))

    ;; Open the connection stream before crawling begins
    (let ((out-port (open-output-file "sitemap.xml")))
      ;; Write XML Header
      (write-sitemap-header out-port)

      (parameterize ((visited-urls (make-hash-table))
                     (sitemap-port out-port))
        (araneola-crawl #:parent-domain url
                        #:url url)

        (with-log-context `((total-link-count unquote
                                              (hash-count (const #t)
                                                          (visited-urls))))
                          (log-info s "Crawl complete. Closing stream.")))

      (write-sitemap-footer out-port)
      (close-port out-port))

    (log-info s "Araneola is stopping")))
