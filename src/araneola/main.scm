;; araneola - high-performance web crawler and sitemap generator
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;;
;;; The command line front end.
;;;
;;; Everything here is about failing well: bad options exit 2 with a message
;;; instead of a Guile backtrace, a crawl that cannot run leaves the previous
;;; sitemap untouched, and `main' returns an exit status rather than calling
;;; `exit' itself so it stays callable from a REPL or a test.
;;;
;;; Code:

(define-module (araneola main)
  #:declarative? #t
  #:use-module (ice-9 format)
  #:use-module (ice-9 getopt-long)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (web uri)
  #:use-module (araneola araneola)
  #:use-module (araneola http)
  #:use-module (araneola sitemap)
  #:use-module (araneola url)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (main
            option-spec
            take-filter-options
            usage))

(define option-spec
  '((url (single-char #\u) (value #t))
    (output (single-char #\o) (value #t))
    (max-urls (value #t))
    (max-depth (value #t))
    (exclude (value #t))
    (include (value #t))
    (delay (single-char #\d) (value #t))
    (timeout (single-char #\t) (value #t))
    (retries (value #t))
    (user-agent (value #t))
    (sitemap-base-url (value #t))
    (include-subdomains)
    (no-robots)
    (no-split)
    (verbose (single-char #\v))
    (help (single-char #\h))
    ;; Accepted for compatibility with the installed wrapper, which passes the
    ;; directory holding help.txt.
    (resources (single-char #\r) (value #t))))

(define (usage)
  (display
   "USAGE: araneola --url URL [OPTIONS]

  -u, --url URL               seed URL to crawl (required)
  -o, --output PATH           sitemap to write (default: sitemap.xml)
      --max-urls N            stop after N pages (0 means no limit)
      --max-depth N           only follow links N levels deep
      --exclude REGEX         never crawl URLs matching REGEX (repeatable)
      --include REGEX         only crawl URLs matching REGEX (repeatable)
  -d, --delay SECONDS         minimum pause between requests (default: 0)
  -t, --timeout SECONDS       per-request timeout (default: 30)
      --retries N             retries for transient failures (default: 2)
      --user-agent UA         User-Agent header to announce
      --sitemap-base-url URL  public location of the sitemap directory
      --include-subdomains    follow links to subdomains
      --no-robots             ignore robots.txt
      --no-split              never write a sitemap index
  -v, --verbose               log every fetched URL
  -h, --help                  show this help\n")
  (newline))

(define (describe-error key args)
  "A human sentence for an exception caught with `catch'.

Guile passes the exception message along with its format template, so the
templates (the arguments containing `~') are dropped."
  (let ((texts (remove (lambda (text)
                         (or (string-null? text)
                             (string-contains text "~")))
                       (filter string? args))))
    (if (pair? texts)
        (string-join texts " ")
        (symbol->string key))))

(define (die message)
  (format (current-error-port) "araneola: ~a~%" message)
  (format (current-error-port) "Try 'araneola --help' for more information.~%")
  2)

(define (take-filter-options args)
  "Remove --exclude and --include from ARGS.

ARGS is a full argument vector, program name first, which is kept so that
`getopt-long' still has it.  Returns four values: the remaining arguments,
the exclude patterns, the include patterns, and whether an option was left
without a value.

`getopt-long' keeps only the last value of a repeated option, and these two
options are meant to be repeated, so they are collected here first.  Both
--option VALUE and --option=VALUE are accepted."
  (define (named? arg name)
    (or (string=? arg name)
        (string-prefix? (string-append name "=") arg)))
  (let loop ((rest args) (kept '()) (excludes '()) (includes '()) (bad? #f))
    (if (null? rest)
        (values (reverse kept) (reverse excludes) (reverse includes) bad?)
        (let ((arg (car rest)))
          (cond
           ;; Everything after -- is not ours to interpret.
           ((string=? arg "--")
            (values (append (reverse kept) rest)
                    (reverse excludes) (reverse includes) bad?))
           ((named? arg "--exclude")
            (if (string=? arg "--exclude")
                (if (null? (cdr rest))
                    (loop '() kept excludes includes #t)
                    (loop (cddr rest) kept (cons (cadr rest) excludes)
                          includes bad?))
                (loop (cdr rest) kept (cons (substring arg 10) excludes)
                      includes bad?)))
           ((named? arg "--include")
            (if (string=? arg "--include")
                (if (null? (cdr rest))
                    (loop '() kept excludes includes #t)
                    (loop (cddr rest) kept excludes
                          (cons (cadr rest) includes) bad?))
                (loop (cdr rest) kept excludes (cons (substring arg 10) includes)
                      bad?)))
           (else (loop (cdr rest) (cons arg kept) excludes includes bad?)))))))

(define (valid-pattern? pattern)
  (catch #t
    (lambda () (make-regexp pattern) #t)
    (lambda _ #f)))

(define (option->number options key default)
  "The numeric value of KEY in OPTIONS, DEFAULT when absent, or #f when the
value is not a number.  Never raises."
  (let ((raw (option-ref options key #f)))
    (cond
     ((not raw) default)
     ((string->number raw) => values)
     (else #f))))

(define (seed->url raw)
  "RAW with a scheme added when it is missing, canonicalised."
  (let ((with-scheme (if (string-contains raw "://")
                         raw
                         (string-append "https://" raw))))
    (canonical-url with-scheme)))

(define* (main #:key (args (command-line)))
  "Run araneola.  Returns the process exit status: 0 on success, 1 when the
crawl produced nothing, 2 for a usage problem.

ARGS is a full argument vector, program name first."
  (call-with-values (lambda () (take-filter-options args))
    (lambda (rest excludes includes bad?)
      (let ((options (catch #t
                       (lambda () (getopt-long rest option-spec))
                       (lambda (key . args)
                         (if (eq? key 'quit)
                             #f
                             (begin
                               (format (current-error-port) "araneola: ~a~%"
                                       (if (pair? args) (car args) key))
                               #f))))))
        (cond
         ((not options)
          (format (current-error-port)
                  "Try 'araneola --help' for more information.~%")
          2)
         ((option-ref options 'help #f)
          (usage)
          0)
         (bad? (die "--exclude and --include need a pattern"))
         (else
          (let ((url (option-ref options 'url #f)))
            (cond
             ((not url) (die "the --url option is required"))
             ;; A pattern that does not compile is a typo the user wants to
             ;; hear about now, not halfway through a crawl.
             ((find (lambda (pattern) (not (valid-pattern? pattern)))
                    (append excludes includes))
              => (lambda (pattern)
                   (die (format #f "not a usable regular expression: ~a"
                                pattern))))
             (else (run options url excludes includes))))))))))

(define (run options url excludes includes)
  (let* ((verbose? (option-ref options 'verbose #f))
         ;; SCRIBA reads its level from the environment when a logger is first
         ;; created, so set it before touching the logger.
         (_ (when verbose? (setenv "SCRIBA_LOG_LEVEL" "debug")))
         (logger (scriba-auto-logger))
         (output (option-ref options 'output "sitemap.xml"))
         (max-urls (option->number options 'max-urls 0))
         (max-depth (option->number options 'max-depth #f))
         (delay (option->number options 'delay 0))
         (timeout (option->number options 'timeout default-timeout))
         (retries (option->number options 'retries default-retries))
         (user-agent (option-ref options 'user-agent default-user-agent))
         (split? (not (option-ref options 'no-split #f)))
         (respect-robots? (not (option-ref options 'no-robots #f)))
         (allow-subdomains? (option-ref options 'include-subdomains #f))
         (seed (seed->url url)))
    (cond
     ((not seed) (die (format #f "not a usable http(s) URL: ~a" url)))
     ((not max-urls) (die "--max-urls needs a number"))
     ((not delay) (die "--delay needs a number"))
     ((not timeout) (die "--timeout needs a number"))
     ((not retries) (die "--retries needs a number"))
     (else
      (let* ((base-url (or (option-ref options 'sitemap-base-url #f)
                           (crawl-origin seed)))
             (writer (catch #t
                       (lambda ()
                         (open-sitemap-writer #:path output
                                              #:split? split?
                                              #:base-url base-url))
                       (lambda (key . args)
                         (format (current-error-port)
                                 "araneola: cannot write ~a: ~a~%"
                                 output (describe-error key args))
                         #f))))
        (if (not writer)
            1
            (let ((stats #f) (ok? #f))
              (catch #t
               (lambda ()
                 (dynamic-wind
                  (lambda () #t)
                  (lambda ()
                    (set! stats
                          (araneola-crawl #:parent-domain seed
                                          #:url seed
                                          #:exclude excludes
                                          #:include includes
                                          #:sleep-seconds delay
                                          #:max-urls max-urls
                                          #:max-depth max-depth
                                          #:user-agent user-agent
                                          #:timeout timeout
                                          #:retries retries
                                          #:respect-robots? respect-robots?
                                          #:allow-subdomains? allow-subdomains?
                                          #:writer writer
                                          #:logger logger))
                    (set! ok? #t))
                  ;; Runs on success *and* on an exception, so an interrupted
                  ;; crawl can never leave a half-written sitemap behind.
                  ;; A crawl that fetched nothing publishes nothing either:
                  ;; an empty urlset would replace a good sitemap with a
                  ;; worse one.
                  (lambda ()
                    (if (and ok?
                             (> (or (assq-ref stats 'fetched) 0) 0))
                        (sitemap-finish! writer)
                        (sitemap-abort! writer)))))
               (lambda (key . args)
                 (format (current-error-port)
                         "araneola: crawl aborted: ~a~%"
                         (describe-error key args))
                 (set! stats #f)))
              (if (not stats)
                  1
                  (begin
                    (log-info
                     logger
                     "Crawl finished: ~a pages, ~a errors, ~a skipped by robots.txt, ~a filtered, ~a noindex, ~a redirects in ~,1f s"
                     (or (assq-ref stats 'fetched) 0)
                     (or (assq-ref stats 'errors) 0)
                     (or (assq-ref stats 'skipped-robots) 0)
                     (or (assq-ref stats 'filtered) 0)
                     (or (assq-ref stats 'noindex) 0)
                     (or (assq-ref stats 'redirects) 0)
                     (or (assq-ref stats 'duration) 0))
                    (let ((errors (assq-ref stats 'error-kinds)))
                      (when (pair? errors)
                        (log-info logger "Failures: ~a"
                                  (string-join (map (lambda (entry)
                                                      (format #f "~a=~a"
                                                              (car entry)
                                                              (cdr entry)))
                                                    errors)
                                               ", "))))
                    (when (eq? (assq-ref stats 'stopped-by) 'max-urls)
                      (log-warning
                       logger
                       "Stopped at the --max-urls limit; the sitemap is incomplete"))
                    (if (> (or (assq-ref stats 'fetched) 0) 0)
                        (begin
                          (log-success logger "Sitemap written to ~a" output)
                          0)
                        (begin
                          (log-error
                           logger
                           "No pages could be crawled; no sitemap written")
                          1)))))))))))
