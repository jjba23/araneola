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
  #:use-module (araneola uri)
  #:use-module (araneola http)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (main))

(define visited-urls
  (make-parameter (make-hash-table)))

(define (execute-fetch-loop current-uri redirects-left logger)
  "Recursively fetches URIs, resolving redirects up to a specified depth limit."
  (let ((uri (if (string? current-uri) (string->uri current-uri) current-uri)))
    (if (<= redirects-left 0)
        (throw 'http-error "Maximum redirect depth exceeded" uri)
        (let-values (((response body)
                      (http-get uri #:headers '((User-Agent . "Araneola/1.0 (contact: jjbigorra@gmail.com)")))))
          (let ((status (response-code response)))
            (cond
              ((or (= status 301) (= status 302))
               (let* ((location (response-location response))
                      (resolved-uri (resolve-uri uri location))
                      (l (uri->string resolved-uri)))
                 (log-info logger "Redirecting (~a) to ~a" status l)
                 (execute-fetch-loop resolved-uri (- redirects-left 1) logger)))
              ((>= status 400)
               (throw 'http-error status uri response))
              (else
               (parse-http-response response body logger))))))))



(define* (araneola-crawl #:key parent-domain url
                         (sleep-seconds 1))
  (let ((v-urls (visited-urls))
        (s (scriba-auto-logger)))

    (unless (hash-ref v-urls url)
      (let ((d (fetch-html #:url url)))
        (when d
          (hash-set! v-urls url
                     `((visited . #t) (last-modified unquote
                                                     (assq-ref d
                                                               'last-modified))))
          (when (assq-ref d
                          'body)
            (let* ((sxml (html->sxml (assq-ref d
                                               'body)))
                   (links (reverse (filter (lambda (l)
                                             (not (hash-ref v-urls l)))
                                           (extract-links-from-sxml #:parent-domain
                                                          parent-domain
                                                          #:url url
                                                          #:sxml sxml)))))
              (with-log-context `((link-count unquote
                                              (length links))
                                  (links unquote links))
                                (if (nil? links)
                                    (log-debug s "No links found")
                                    (log-info s "Found links")))

              (for-each (lambda (link)
                          (sleep sleep-seconds)
                          (araneola-crawl #:parent-domain parent-domain
                                          #:url link)) links))))))))

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

    (parameterize ((visited-urls (make-hash-table)))
      (araneola-crawl #:parent-domain url
                      #:url url)
      (with-log-context `((total-link-count unquote
                                            (hash-count (const #t)
                                                        (visited-urls))))
                        (log-info s "Links found"))
      (write-sitemap (links->sitemap (visited-urls)) "sitemap.xml")
      (log-info s "Araneola is stopping"))))
