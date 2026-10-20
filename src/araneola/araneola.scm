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

;;; Commentary:
;;;
;;; The crawl itself: a breadth-first walk over a frontier queue.
;;;
;;; Version 1 recursed once per link, which meant a deep site could exhaust
;;; the stack, and any exception raised by a child page unwound through every
;;; ancestor.  This version keeps an explicit queue instead, so:
;;;
;;; - memory is bounded by the frontier, not by the recursion depth;
;;; - one page failing cannot end the crawl (`fetch-url' never raises);
;;; - a page is marked visited *before* it is fetched, so two parents linking
;;;   to the same page cannot both fetch it;
;;; - limits (`max-urls', `max-depth') are checked in one place;
;;; - a page that asks not to be indexed (meta robots or an X-Robots-Tag
;;;   header) is crawled for links but kept out of the sitemap, and a page
;;;   that declares a canonical URL is listed once, under that URL;
;;; - `exclude' and `include' regular expressions are matched against the
;;;   canonical URL before a page is queued, so a site's `/search' or
;;;   pagination traps cost no requests at all;
;;; - robots.txt is consulted per host, and a slow host's Crawl-delay is
;;;   folded into the politeness delay.
;;;
;;; Code:

(define-module (araneola araneola)
  #:declarative? #t
  #:use-module (ice-9 match)
  #:use-module (ice-9 q)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (web uri)
  #:use-module (araneola html)
  #:use-module (araneola http)
  #:use-module (araneola robots)
  #:use-module (araneola sitemap)
  #:use-module (araneola url)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:re-export (extract-links-from-sxml
               resolve-uri
               normalize-url
               is-interesting-url?)
  #:export (visited-urls
            araneola-crawl
            crawl-origin))

;;; The set of URLs already handled.  Exposed as a parameter so a caller can
;;; inspect the result, or hand in a warm table to continue a previous run.
(define visited-urls
  (make-parameter (make-hash-table)))

(define* (crawl-origin url)
  "The scheme://host[:port] of URL, used as the robots.txt scope."
  (let ((uri (catch #t
               (lambda () (string->uri-reference url))
               (lambda _ #f))))
    (and uri (uri-host uri)
         (catch #t
           (lambda ()
             (uri->string (build-uri (uri-scheme uri)
                                     #:host (uri-host uri)
                                     #:port (uri-port uri))))
           (lambda _ #f)))))

(define (host-key url)
  (or (crawl-origin url) url))

(define (monotonic-seconds)
  (let ((now (gettimeofday)))
    (+ (car now) (/ (cdr now) 1000000.0))))

(define (sleep-for seconds)
  (when (and seconds (> seconds 0))
    (usleep (inexact->exact (round (* 1000000 seconds))))))

(define (record-error! table kind)
  (hash-set! table kind (+ 1 (or (hash-ref table kind) 0))))

(define (compile-patterns patterns)
  "PATTERNS as compiled regular expressions.

Strings that do not compile are dropped with a warning rather than ending
the crawl: a typo in an exclusion rule should not cost a whole run."
  (filter-map (lambda (pattern)
                (cond
                 ((regexp? pattern) pattern)
                 ((and (string? pattern) (not (string-null? pattern)))
                  (or (catch #t
                        (lambda () (make-regexp pattern))
                        (lambda _ #f))
                      (begin
                        (log-warning (scriba-auto-logger)
                                     "Ignoring unusable filter pattern: ~a"
                                     pattern)
                        #f)))
                 (else #f)))
              patterns))

(define (matches-pattern? patterns url)
  (any (lambda (pattern) (regexp-exec pattern url)) patterns))

(define* (araneola-crawl #:key
                         (parent-domain #f)
                         (url #f)
                         (sleep-seconds 0)
                         (max-urls 0)
                         (max-depth #f)
                         (exclude '())
                         (include '())
                         (user-agent default-user-agent)
                         (timeout default-timeout)
                         (retries default-retries)
                         (respect-robots? #t)
                         (allow-subdomains? #f)
                         (writer #f)
                         (progress-every 50)
                         (logger (scriba-auto-logger)))
  "Crawl the site seeded at URL, appending every page to WRITER.

EXCLUDE and INCLUDE are regular expressions (strings or compiled regexps)
matched against canonical URLs; a URL must match no EXCLUDE pattern and, when
INCLUDE is non-empty, at least one INCLUDE pattern, before it is queued.  The
seed page itself is always crawled, so `--include' narrows a crawl instead of
being able to cancel it outright.

Returns an alist of counters: `fetched', `attempted', `errors',
`skipped-robots', `noindex', `filtered', `redirects', `bytes', `visited',
`error-kinds', `duration' and `stopped-by' (`done', `max-urls',
`invalid-seed')."
  (let* ((started (monotonic-seconds))
         (seed (canonical-url (or url parent-domain "")))
         (frontier (make-q))
         (visited (visited-urls))
         (queued (make-hash-table))
         ;; URLs already published, so that a redirect target linked from two
         ;; pages (or a page reached by two spellings) appears once.
         (written (make-hash-table))
         (robots-cache (make-hash-table))
         (error-kinds (make-hash-table))
         (excluded-patterns (compile-patterns exclude))
         (included-patterns (compile-patterns include))
         (state (list (cons 'fetched 0) (cons 'attempted 0) (cons 'errors 0)
                      (cons 'skipped 0) (cons 'redirects 0) (cons 'bytes 0)
                      (cons 'noindex 0) (cons 'filtered 0)
                      (cons 'last-request 0) (cons 'depth 0))))
    (define (get key) (or (assq-ref state key) 0))
    (define (set!* key value) (set! state (assq-set! state key value)))
    (define (bump! key . args)
      (set!* key (+ (get key) (if (pair? args) (car args) 1))))

    ;; Each host's robots.txt is fetched once and remembered as
    ;; (rules crawl-delay), so a site with 10,000 pages still costs one read.
    (define (robots-entry url)
      (let* ((key (host-key url))
             (cached (hash-ref robots-cache key)))
        (or cached
            (let* ((robots (fetch-robots (or (crawl-origin url) url)
                                         #:user-agent user-agent
                                         #:timeout timeout
                                         #:logger logger))
                   (rules (robots-for robots user-agent))
                   (entry (list rules (robots-crawl-delay rules))))
              (hash-set! robots-cache key entry)
              entry))))

    (define (allowed? url)
      (robots-allowed? (car (robots-entry url))
                       (or (url-path+query url) "/")))

    (define (delay-for url)
      (max (or sleep-seconds 0) (or (cadr (robots-entry url)) 0)))

    (define (wait-for-slot! seconds)
      (let* ((delay (or seconds 0))
             (elapsed (- (monotonic-seconds) (get 'last-request))))
        (when (and (> delay 0) (< elapsed delay))
          (sleep-for (- delay elapsed))))
      (set!* 'last-request (monotonic-seconds)))

    (define (enqueue! url depth)
      (cond
       ((or (hash-ref visited url) (hash-ref queued url)) #f)
       ((and (pair? excluded-patterns) (matches-pattern? excluded-patterns url))
        (bump! 'filtered)
        (log-debug logger "Excluded by pattern: ~a" url))
       ((and (pair? included-patterns)
             (not (matches-pattern? included-patterns url)))
        (bump! 'filtered)
        (log-debug logger "Not matched by an include pattern: ~a" url))
       (else
        (hash-set! queued url #t)
        (enq! frontier (cons url depth)))))

    (define (can-descend? depth)
      (or (not max-depth) (< depth max-depth)))

    (define (process-page! current depth)
      (if (and respect-robots? (not (allowed? current)))
          (begin
            (bump! 'skipped)
            (log-debug logger "robots.txt disallows ~a" current))
          (begin
            (wait-for-slot! (delay-for current))
            (handle-response! current depth
                             (fetch-url current
                                        #:user-agent user-agent
                                        #:timeout timeout
                                        #:retries retries
                                        #:logger logger)))))

    (define (handle-response! current depth response)
      (let ((error (assq-ref response 'error))
            (final (or (assq-ref response 'url) current))
            (body (assq-ref response 'body))
            (content-type (assq-ref response 'content-type))
            (lastmod (assq-ref response 'last-modified))
            (redirects (or (assq-ref response 'redirects) 0)))
        (cond
         (error
          (bump! 'errors)
          (record-error! error-kinds error)
          (log-debug logger "Giving up on ~a (~a)" current error))
         (else
          (bump! 'fetched)
          ;; The final URL is what a search engine should index, and must not
          ;; be fetched again when another page links to it directly.
          (when (> redirects 0)
            (bump! 'redirects redirects)
            (hash-set! visited final #t))
          (when body
            (bump! 'bytes (string-length body)))
          ;; The page is parsed once, whatever the depth: even when its links
          ;; are not followed, its noindex and canonical hints still decide
          ;; what the sitemap says about it.
          (let* ((html? (and body (html-content-type? content-type)))
                 (analysis (and html?
                                (page-analysis #:url final
                                               #:html body
                                               #:allow-subdomains?
                                               allow-subdomains?)))
                 (canonical (and analysis (assq-ref analysis 'canonical)))
                 (noindex? (or (noindex-content?
                                (assq-ref response 'robots-tag))
                               (and analysis (assq-ref analysis 'noindex))))
                 ;; A canonical URL is what a search engine should index, and
                 ;; two spellings of a page share it, so it replaces the URL
                 ;; that was actually fetched.
                 (listed (or canonical final)))
            (when noindex?
              (bump! 'noindex)
              (log-debug logger "~a asks not to be indexed; not listed" final))
            (when (and writer (not noindex?) (not (hash-ref written listed)))
              (hash-set! written listed #t)
              (sitemap-add! writer listed lastmod))
            (when (and analysis (can-descend? depth))
              (let ((links (assq-ref analysis 'links)))
                (for-each (lambda (link) (enqueue! link (+ depth 1))) links)
                (log-debug logger "~a: ~a new links" final (length links)))))
          (when (and (> progress-every 0)
                     (= 0 (modulo (get 'fetched) progress-every)))
            (log-info logger "Crawled ~a pages (~a queued)"
                      (get 'fetched) (q-length frontier)))))))

    (define (finish reason)
      (list (cons 'fetched (get 'fetched))
            (cons 'attempted (get 'attempted))
            (cons 'errors (get 'errors))
            (cons 'skipped-robots (get 'skipped))
            (cons 'noindex (get 'noindex))
            (cons 'filtered (get 'filtered))
            (cons 'redirects (get 'redirects))
            (cons 'bytes (get 'bytes))
            (cons 'visited (hash-count (lambda (key value) #t) visited))
            (cons 'error-kinds (hash-map->list cons error-kinds))
            (cons 'duration (- (monotonic-seconds) started))
            (cons 'stopped-by reason)))

    (if (not seed)
        (begin
          (log-error logger "Not a usable http(s) URL: ~a" (or url parent-domain))
          (finish 'invalid-seed))
        (begin
          (log-info logger "Crawling ~a" seed)
          ;; The seed is queued directly: it is what the user asked for, and
          ;; an include pattern that does not match it must not turn a crawl
          ;; into a no-op.
          (hash-set! queued seed #t)
          (enq! frontier (cons seed 0))
          (let loop ()
            (cond
             ((q-empty? frontier) (finish 'done))
             ((and (> max-urls 0) (>= (get 'attempted) max-urls))
              (finish 'max-urls))
             (else
              (let* ((item (deq! frontier))
                     (current (car item))
                     (depth (cdr item)))
                (hash-set! queued current #t)
                (unless (hash-ref visited current)
                  (hash-set! visited current #t)
                  (bump! 'attempted)
                  (when (> depth (get 'depth))
                    (set!* 'depth depth)
                    (log-debug logger "Depth ~a reached at ~a" depth current))
                  (process-page! current depth))
                (loop)))))))))
