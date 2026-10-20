;; araneola

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; araneola is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Lesser General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; araneola is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; Lesser GNU General Public License for more details.

;; You should have received a copy of the Lesser GNU General Public License
;; along with araneola.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;;
;;; URL plumbing for araneola.
;;;
;;; Crawling is only as correct as the URLs it walks, so this module owns
;;; every decision about what a URL *is*:
;;;
;;; - `resolve-uri' implements RFC 3986 section 5 reference resolution
;;;   (absolute, protocol-relative, host-relative, path-relative, query-only
;;;   and dot-segment containing references).
;;; - `canonical-url' produces the single string used as the crawl identity
;;;   of a page (fragments dropped, host and scheme lower-cased, default
;;;   ports dropped).  Two spellings of the same page collapse to one key.
;;; - `is-interesting-url?' decides whether a link stays inside the crawl
;;;   scope.  It compares hosts instead of string prefixes, so a link to
;;;   "https://example.com.evil.test/" is not mistaken for a same-site link.
;;;
;;; Code:

(define-module (araneola url)
  #:declarative? #t
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (web uri)
  #:export (resolve-uri
            normalize-url
            remove-dot-segments
            canonical-url
            supported-scheme?
            effective-port
            same-site?
            is-interesting-url?
            url-host
            url-path+query))

(define %default-ports
  '(("http" . 80) ("https" . 443)))

(define (default-port scheme)
  (and scheme (assoc-ref %default-ports scheme)))

(define* (to-uri value)
  "Coerce VALUE (a string or a URI) to a URI, or #f when it is not a
valid URI reference.  Never raises.

Relative references are legal here: `string->uri-reference' is used rather
than `string->uri', which rejects anything without a scheme."
  (cond
   ((string? value)
    (and (not (string-null? (string-trim value)))
         (catch #t
           (lambda () (string->uri-reference value))
           (lambda _ #f))))
   ((uri? value) value)
   ;; Some other parts of Guile hand out URI records that its own `uri?'
   ;; predicate does not recognise; fall back on the accessors before giving
   ;; up, and treat anything unusable as absent instead of raising.
   (else (catch #t (lambda () (and (uri-path value) value)) (lambda _ #f)))))

(define (supported-scheme? uri)
  "True when URI is an http or https URI."
  (let ((scheme (and uri (uri-scheme uri))))
    (and scheme (member (string-downcase (symbol->string scheme))
                        '("http" "https")) #t)))

(define (effective-port uri)
  "The port URI really talks to, taking the scheme default into account."
  (or (and uri (uri-port uri))
      (and uri (default-port (and (uri-scheme uri)
                                  (string-downcase
                                   (symbol->string (uri-scheme uri))))))))

(define (remove-dot-segments path)
  "Remove \".\" and \"..\" segments from PATH (RFC 3986 section 5.2.4)."
  (if (or (not path) (string-null? path))
      path
      (let* ((absolute? (string-prefix? "/" path))
             (trailing-slash? (or (string-suffix? "/" path)
                                  (string-suffix? "/." path)
                                  (string-suffix? "/.." path)
                                  (equal? path ".")
                                  (equal? path "..")))
             (segments (string-split path #\/)))
        (define (join out)
          (let ((body (string-join (reverse out) "/")))
            (cond
             ((and absolute? (string-null? body)) "/")
             (absolute? (string-append "/" body (if trailing-slash? "/" "")))
             ((string-null? body) "")
             (else (string-append body (if trailing-slash? "/" ""))))))
        (let loop ((rest segments) (out '()))
          (match rest
            (() (join out))
            (((or "" ".") tail ...) (loop tail out))
            ((".." tail ...)
             (loop tail (if (and (pair? out) (not (equal? (car out) "..")))
                            (cdr out)
                            out)))
            ((head tail ...) (loop tail (cons head out))))))))

(define* (build-from base #:key host path query fragment)
  (build-uri (uri-scheme base)
             #:userinfo (uri-userinfo base)
             #:host host
             #:port (uri-port base)
             #:path path
             #:query query
             #:fragment fragment))

(define* (resolve-uri base relative)
  "Resolve RELATIVE against BASE, following RFC 3986 section 5.
Both arguments may be strings or URIs.  Returns a URI, or #f when either
argument cannot be parsed (callers must never see an exception)."
  (let ((b (to-uri base))
        (r (to-uri relative)))
    (cond
     ((not r) #f)
     ((uri-scheme r) r)
     ((not b) #f)
     ((uri-host r)
      ;; Protocol-relative reference, e.g. "//example.com/path".
      (build-uri (uri-scheme b)
                 #:userinfo (uri-userinfo r)
                 #:host (uri-host r)
                 #:port (uri-port r)
                 #:path (or (uri-path r) "/")
                 #:query (uri-query r)
                 #:fragment (uri-fragment r)))
     ((or (not (uri-path r)) (string-null? (uri-path r)))
      ;; Query-only or fragment-only reference: keep the base path.
      (build-from b
                  #:host (uri-host b)
                  #:path (or (uri-path b) "/")
                  #:query (uri-query r)
                  #:fragment (uri-fragment r)))
     ((string-prefix? "/" (uri-path r))
      ;; Host-relative reference.
      (build-from b
                  #:host (uri-host b)
                  #:path (remove-dot-segments (uri-path r))
                  #:query (uri-query r)
                  #:fragment (uri-fragment r)))
     (else
      ;; Path-relative reference: merge with the base directory.
      (let* ((base-path (or (uri-path b) "/"))
             (slash (string-rindex base-path #\/))
             (dir (if slash (substring base-path 0 (+ slash 1)) "/")))
        (build-from b
                    #:host (uri-host b)
                    #:path (remove-dot-segments (string-append dir (uri-path r)))
                    #:query (uri-query r)
                    #:fragment (uri-fragment r)))))))

(define (normalize-url parent-domain path)
  "Join PARENT-DOMAIN and PATH without doubling or losing slashes.

Kept for backwards compatibility; prefer `canonical-url' for new code."
  (let ((clean-domain (string-trim-right parent-domain #\/))
        (clean-path (string-trim path #\/)))
    (if (string-null? clean-path)
        (string-append clean-domain "/")
        (string-append clean-domain "/" clean-path))))

(define* (canonical-url value)
  "The canonical identity of VALUE: a string, or #f when VALUE is not a
crawlable http(s) URL.

Drops the fragment (it never changes what the server returns), lower-cases
scheme and host, drops the default port for the scheme, maps an empty path
to \"/\" and drops empty queries.  Anything that cannot be parsed is #f."
  (let ((uri (to-uri value)))
    (and uri
         (supported-scheme? uri)
         (uri-host uri)
         (let* ((scheme (string-downcase (symbol->string (uri-scheme uri))))
                (host (string-downcase (uri-host uri)))
                (port (uri-port uri))
                (path (remove-dot-segments
                       (let ((p (uri-path uri)))
                         (if (or (not p) (string-null? p)) "/" p))))
                (query (uri-query uri))
                (canonical (build-uri (string->symbol scheme)
                                      #:host host
                                      #:port (and port
                                                  (not (= port (default-port scheme)))
                                                  port)
                                      #:path path
                                      #:query (and query
                                                   (not (string-null? query))
                                                   query))))
           (catch #t
             (lambda () (uri->string canonical))
             (lambda _ #f))))))

(define (url-host value)
  (let ((uri (to-uri value)))
    (and uri (uri-host uri) (string-downcase (uri-host uri)))))

(define (url-path+query value)
  "The path (and query, when present) of VALUE, used for robots.txt checks."
  (let ((uri (to-uri value)))
    (and uri
         (let ((path (let ((p (uri-path uri)))
                       (if (or (not p) (string-null? p)) "/" p)))
               (query (uri-query uri)))
           (if (and query (not (string-null? query)))
               (string-append path "?" query)
               path)))))

(define* (same-site? origin host #:key (allow-subdomains? #f))
  "True when HOST belongs to the site ORIGIN names.

With ALLOW-SUBDOMAINS? a host that ends in \".origin\" also matches; a host
that merely *starts* with the origin (\"example.com.evil.test\") never does."
  (let ((origin-host (url-host origin))
        (candidate (and host (string-downcase host))))
    (and origin-host
         candidate
         (or (string=? origin-host candidate)
             (and allow-subdomains?
                  (> (string-length candidate) (string-length origin-host))
                  (string-suffix? (string-append "." origin-host) candidate))))))

(define* (is-interesting-url? #:key parent-domain url
                              (allow-subdomains? #f))
  "True when URL is a crawlable page on the same site as PARENT-DOMAIN.

PARENT-DOMAIN may be a full URL (\"https://example.com\") or a bare host."
  (let* ((origin (if (string-contains parent-domain "://")
                     parent-domain
                     (string-append "https://" parent-domain)))
         (origin-host (url-host origin))
         (uri (to-uri url)))
    (and origin-host
         uri
         (supported-scheme? uri)
         (uri-host uri)
         (same-site? origin (url-host url) #:allow-subdomains? allow-subdomains?)
         (equal? (effective-port (to-uri origin)) (effective-port uri)))))
