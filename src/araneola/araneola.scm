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
  #:use-module (araneola http)
  #:use-module (araneola sitemap)
  #:use-module (srfi srfi-19)
  #:use-module (scriba scriba)
  #:use-module (scriba auto)
  #:export (extract-links-from-sxml normalize-url
                                    resolve-uri
                                    is-interesting-url?
                                    araneola-crawl
                                    visited-urls
                                    execute-fetch-loop
                                    sitemap-port))

(define visited-urls
  (make-parameter (make-hash-table)))

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

(define (resolve-uri base relative)
  "Safely resolve absolute, relative, host-relative, or protocol-relative URIs against a base URI."
  (cond
    ((uri-scheme relative)
     relative) ;Already an absolute URI
    ((uri-host relative)
     ;; Protocol-relative URI (e.g., //example.com/path)
     (build-uri (uri-scheme base)
                #:userinfo (uri-userinfo relative)
                #:host (uri-host relative)
                #:port (uri-port relative)
                #:path (uri-path relative)
                #:query (uri-query relative)
                #:fragment (uri-fragment relative)))
    ((string-prefix? "/"
                     (uri-path relative))
     ;; Host-relative URI (e.g., /path/to/resource)
     (build-uri (uri-scheme base)
                #:userinfo (uri-userinfo base)
                #:host (uri-host base)
                #:port (uri-port base)
                #:path (uri-path relative)
                #:query (uri-query relative)
                #:fragment (uri-fragment relative)))
    (else
     ;; Path-relative URI (e.g., sub/path or ../path)
     (let* ((base-path (uri-path base))
            (last-slash (string-rindex base-path #\/))
            (dir (if last-slash
                     (substring base-path 0
                                (+ last-slash 1)) "/"))
            (new-path (string-append dir
                                     (uri-path relative))))
       (build-uri (uri-scheme base)
                  #:userinfo (uri-userinfo base)
                  #:host (uri-host base)
                  #:port (uri-port base)
                  #:path new-path
                  #:query (uri-query relative)
                  #:fragment (uri-fragment relative))))))

(define (normalize-url parent-domain path)
  "Ensures correct joining of domain and paths to prevent double slashes."
  (let ((clean-domain (string-trim-right parent-domain #\/))
        (clean-path (string-trim path #\/)))
    (string-append clean-domain "/" clean-path)))

(define* (araneola-crawl #:key parent-domain url
                         (sleep-seconds 0))
  (let ((v-urls (visited-urls))
        (s (scriba-auto-logger))
        (continuation-proc (lambda ()
                             (execute-fetch-loop url 5))))
    
    (unless (hash-ref v-urls url)
      (let ((d (fetch-body #:url url
                           #:continuation-proc continuation-proc)))
        (when d
          (let ((last-mod (assq-ref d
                                    'last-modified)))
            ;; Update internal state cache
            (hash-set! v-urls url
                       `((visited . #t) (last-modified unquote last-mod)))

            ;; Stream content if the port exists
            (when (sitemap-port)
              (write-sitemap-item (sitemap-port) url last-mod)))

          (when (assq-ref d
                          'body)
            (let* ((sxml (html->sxml (assq-ref d
                                               'body)))
                   (links (reverse (filter (lambda (l)
                                             (not (hash-ref v-urls l)))
                                           (extract-links-from-sxml
                                            #:parent-domain parent-domain
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

(define (execute-fetch-loop current-uri redirects-left)
  "Recursively fetches URIs, resolving redirects up to a specified depth limit."
  (let ((uri (if (string? current-uri)
                 (string->uri current-uri) current-uri))
        (s (scriba-auto-logger)))
    (if (<= redirects-left 0)
        (throw 'http-error "Maximum redirect depth exceeded" uri)
        (let-values (((response body)
                      (http-get uri
                                #:headers '((User-Agent . "Araneola/1.0 (contact: jjbigorra@gmail.com)")))))
                    (let ((status (response-code response)))
                      (cond
                        ((or (= status 301)
                             (= status 302))
                         (let* ((location (response-location response))
                                (resolved-uri (resolve-uri uri location))
                                (l (uri->string resolved-uri)))
                           (log-info s "Redirecting (~a) to ~a" status l)
                           (execute-fetch-loop resolved-uri
                                               (- redirects-left 1))))
                        ((>= status 400)
                         (throw 'http-error status uri response))
                        (else (parse-http-response response body))))))))

(define sitemap-port
  (make-parameter #f))
