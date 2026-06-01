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
  #:use-module (srfi srfi-1) ;Fixed: Imported only once
  #:use-module (srfi srfi-11) ;Added for let-values
  #:use-module (srfi srfi-13)
  #:use-module (sxml simple)
  #:use-module (ice-9 getopt-long)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (htmlprag)
  #:use-module (srfi srfi-19)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (main))

(define visited-urls
  (make-parameter (make-hash-table)))

(define (normalize-url parent-domain path)
  "Ensures correct joining of domain and paths to prevent double slashes."
  (let ((clean-domain (string-trim-right parent-domain #\/))
        (clean-path (string-trim path #\/)))
    (string-append clean-domain "/" clean-path)))

(define* (fetch-html #:key url)
  "Fetches the URL and returns the body as a UTF-8 string, or #f on failure."
  (let ((s (scriba-auto-logger))
        (initial-uri (if (string? url)
                         (string->uri url) url)))
    (with-log-context `((url unquote url))
                      (log-info s "Fetching HTML"))

    (define (do-fetch current-uri redirects-left)
      (if (<= redirects-left 0)
          (throw 'http-error "Maximum redirect depth exceeded" current-uri)
          (let-values (((response body)
                        (http-get current-uri
                                  #:headers '((User-Agent . "Araneola/1.0 (contact: jjbigorra@gmail.com)")))))
                      (let ((status (response-code response)))
                        (cond
                          ((or (= status 301)
                               (= status 302))
                           (let* ((location (response-location response))
                                  (l (uri->string location)))
                             (log-info s "Redirecting (~a) to ~a" status l)
                             (do-fetch l
                                       (- redirects-left 1))))
                          ((>= status 400)
                           (throw 'http-error status current-uri response))
                          (else (let* ((raw-lm (response-last-modified
                                                response #f))
                                       (last-modified (and raw-lm
                                                           (date->string
                                                            raw-lm "~Y-~m-~d"))))
                                  (unless (= status 200)
                                    (with-log-context `((status ,status))
                                                      (log-info s
                                                       "Received HTTP status")))
                                  `((body unquote
                                          (if (bytevector? body)
                                              (utf8->string body) body))
                                    (last-modified unquote last-modified)))))))))

    (catch #t
           (lambda ()
             (do-fetch initial-uri 5))
           (lambda (key . args)
             (if (eq? key
                      'http-error)
                 (begin
                   (with-log-context `((error unquote key)
                                       (details unquote args)
                                       (url unquote url))
                                     (log-error s "Failed to fetch URL")) #f)
                 (apply throw key args))))))

(define* (is-interesting-url? #:key parent-domain url)
  "Validates if the fully qualified URL belongs to the target domain."
  (cond
    ((string-contains url "../")
     #f)
    ((or (equal? "" url)
         (equal? "/" url)
         (equal? parent-domain url))
     #f)
    ((string-prefix? parent-domain url)
     #t)
    (else #f)))

(define* (extract-links #:key parent-domain url sxml)
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

(define* (araneola-crawl #:key parent-domain url
                         (sleep-seconds 0))
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
                                           (extract-links #:parent-domain
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

(define (write-sitemap sxml filename)
  "Takes a SXML tree and writes a valid sitemap.xml."
  (let* ((s (scriba-auto-logger))
         (out-port (open-output-file filename)))
    (with-log-context `((filename unquote filename))
                      (log-info s "Writing sitemap to file")
                      (sxml->xml sxml out-port)
                      (close-port out-port)
                      (log-success s "Wrote sitemap to file"))))

(define (make-sitemap)
  "Generates a valid sitemap SXML structure from the visited-urls parameter."
  (let* ((xs (hash-map->list (lambda (k v)
                               (acons 'url k v))
                             (visited-urls)))
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
      (with-log-context `((total-link-count unquote (hash-count (const #t)
                                                         (visited-urls))))
                        (log-info s "Links found"))
      (write-sitemap (make-sitemap) "sitemap.xml")
      (log-info s "Araneola is stopping"))))
