;; araneola - high-performance web crawler and sitemap generator
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;;
;;; A crawler talks to a lot of servers it does not control, so every request
;;; here is assumed to go wrong in some way:
;;;
;;; - `fetch-url' never raises.  It always returns a result alist describing
;;;   what happened, because a single dead link must not end a crawl.
;;; - Requests run under `with-timeout', so a server that accepts a connection
;;;   and then goes quiet cannot hang the whole run.
;;; - Bodies are read incrementally and capped at `max-body-bytes', so a
;;;   multi-gigabyte download cannot exhaust memory.
;;; - Transient failures (timeouts, 429, 5xx, dropped connections) are retried
;;;   with exponential backoff, honouring Retry-After when the server sends it.
;;; - Redirects (301, 302, 303, 307, 308) are followed with loop detection and
;;;   a depth limit, and the final URL is reported back to the caller.
;;;
;;; Code:

(define-module (araneola http)
  #:declarative? #t
  #:use-module (ice-9 format)
  #:use-module ((ice-9 iconv) #:select (bytevector->string))
  #:use-module (ice-9 threads)
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:use-module ((rnrs io ports) #:select (get-bytevector-n))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-19)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (araneola url)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (default-user-agent
            default-timeout
            default-retries
            max-body-bytes
            with-timeout
            fetch-url
            fetch-body
            parse-http-response
            result-ok?
            html-content-type?))

(define default-user-agent
  "Araneola/2.0 (+https://codeberg.org/jjba23/araneola)")

(define default-timeout 30)
(define default-retries 2)

;;; The largest body we are willing to hold in memory.  Documents are parsed
;;; for links, so a truncated 5 MiB page is still useful, while a 2 GiB ISO is
;;; not worth downloading.
(define max-body-bytes (* 5 1024 1024))

(define %redirect-statuses '(301 302 303 307 308))
(define %retry-statuses '(408 425 429 500 502 503 504))

;;; Errors that mean "the network misbehaved", as opposed to "the server
;;; answered and meant it".  A timeout, a reset connection or a garbled
;;; response is worth another try; a 404 or a bad certificate is not.
(define %retryable-errors '(timeout connection-error protocol-error
                            request-failed))

(define (sleep-seconds seconds)
  "Sleep for SECONDS, which may be fractional."
  (when (and seconds (> seconds 0))
    (usleep (inexact->exact (round (* seconds 1000000))))))

(define* (with-timeout seconds thunk #:optional (timeout-value 'timed-out))
  "Run THUNK, giving up after SECONDS seconds.

Returns THUNK's value, TIMEOUT-VALUE when the deadline passes, or
`(error KEY ARGS)' when THUNK raised.  A non-positive or #f SECONDS runs
THUNK with no deadline at all.

The worker is cancelled when the deadline passes.  Guile can interrupt a
thread blocked in a socket read, which is what makes this useful; a thread
stuck somewhere uninterruptible is simply abandoned and its result ignored.

The result is collected by polling a small shared vector rather than with a
condition variable: in this Guile `wait-condition-variable' reports a
timeout immediately even when given a generous one, which would make every
request look as if it failed.  The first polls are a millisecond apart and
the interval doubles up to 50ms, so a fast response is not delayed."
  (if (or (not seconds) (<= seconds 0))
      (catch #t
        thunk
        (lambda (key . args) (list 'error key args)))
      (let* ((cell (vector 'pending #f))
             (worker
              (call-with-new-thread
               (lambda ()
                 (let ((outcome (catch #t
                                  thunk
                                  (lambda (key . args)
                                    (list 'error key args)))))
                   (vector-set! cell 1 outcome)
                   (vector-set! cell 0 'done))))))
        (let loop ((waited 0) (slice 0.001))
          (cond
           ((eq? (vector-ref cell 0) 'done) (vector-ref cell 1))
           ((>= waited seconds)
            (cancel-thread worker)
            timeout-value)
           (else
            (sleep-seconds slice)
            (loop (+ waited slice) (min 0.05 (* slice 2)))))))))

(define (concat-bytevectors chunks)
  (let* ((total (fold (lambda (chunk sum) (+ sum (bytevector-length chunk))) 0 chunks))
         (out (make-bytevector total 0)))
    (let loop ((rest chunks) (at 0))
      (if (null? rest)
          out
          (let ((chunk (car rest)))
            (bytevector-copy! chunk 0 out at (bytevector-length chunk))
            (loop (cdr rest) (+ at (bytevector-length chunk))))))))

(define* (read-bounded port #:key (limit max-body-bytes))
  "Read at most LIMIT bytes from PORT.  Returns two values: the bytevector
and whether the body was truncated."
  (let loop ((chunks '()) (total 0))
    (if (>= total limit)
        (values (concat-bytevectors (reverse chunks)) #t)
        (let ((chunk (get-bytevector-n port (min 65536 (max 1 (- limit total))))))
          (if (eof-object? chunk)
              (values (concat-bytevectors (reverse chunks)) #f)
              (loop (cons chunk chunks) (+ total (bytevector-length chunk))))))))

(define* (decode-body bytes #:optional content-type)
  "Bytes to text, using the declared charset, UTF-8, or Latin-1 in that
order of preference.  Never raises."
  (if (not bytes)
      #f
      (let* ((charset (and content-type
                           (pair? (cdr content-type))
                           (assq-ref (cdr content-type) 'charset)))
             (rtl (if (and charset (pair? charset)) (car charset) charset)))
        (or (catch #t
              (lambda () (bytevector->string bytes (or rtl "utf-8")))
              (lambda _ #f))
            (catch #t
              (lambda () (bytevector->string bytes "iso-8859-1"))
              (lambda _ ""))))))

(define (content-type-name response)
  "The media type of RESPONSE as a string, or #f.

Guile hands the type back as a symbol (`text/html'), which quietly defeats
any `string-prefix?' test, so it is normalised here."
  (let ((type (response-content-type response)))
    (and type
         (pair? type)
         (let ((name (car type)))
           (cond
            ((string? name) name)
            ((symbol? name) (symbol->string name))
            (else (and name (format #f "~a" name))))))))

(define (html-content-type? content-type)
  (and (string? content-type)
       (or (string-prefix? "text/html" content-type)
           (string-prefix? "application/xhtml+xml" content-type))))

(define (last-modified-string response)
  (let ((date (catch #t
                (lambda () (response-last-modified response))
                (lambda _ #f))))
    (and date (catch #t
                (lambda () (date->string date "~Y-~m-~d"))
                (lambda _ #f)))))

(define* (result #:key (url #f) (status #f) (body #f) (content-type #f)
                 (last-modified #f) (robots-tag #f) (redirects 0)
                 (truncated? #f) (error #f))
  "The shape every fetch returns: never an exception, always this alist."
  (list (cons 'url url)
        (cons 'status status)
        (cons 'body body)
        (cons 'content-type content-type)
        (cons 'last-modified last-modified)
        (cons 'robots-tag robots-tag)
        (cons 'redirects redirects)
        (cons 'truncated? truncated?)
        (cons 'error error)))

(define (result-ok? result)
  (and result
       (not (assq-ref result 'error))
       (let ((status (assq-ref result 'status)))
         (and status (>= status 200) (< status 300)))))

(define (result-error result)
  (and result (assq-ref result 'error)))

(define (parse-http-response response body)
  "Parse a response into an alist of `body' and `last-modified'.

Kept for backwards compatibility; new code uses `fetch-url', which also
handles redirects, retries, timeouts and content types."
  (let ((status (response-code response)))
    (unless (= status 200)
      (log-warning (scriba-auto-logger)
                   "Received HTTP status ~a" status))
    `((body unquote
            (if (bytevector? body)
                (decode-body body (response-content-type response))
                body))
      (last-modified unquote (last-modified-string response)))))

(define* (request-once uri #:key user-agent timeout max-body-bytes limit)
  "Perform one GET of URI and read at most LIMIT bytes of its body.

Returns an alist with the response plus the decoded body, or an alist whose
`error' says what went wrong.  Never raises."
  ;; Only the User-Agent is sent.  Guile validates every outgoing header with
  ;; its own parsers and rejects the usual crawler Accept/Accept-Encoding
  ;; strings, while servers return usable HTML without being asked for it.
  (let* ((headers `((user-agent . ,user-agent)))
         (outcome
          (with-timeout
           timeout
           (lambda ()
             (call-with-values
                 (lambda ()
                   (http-get (if (string? uri) (string->uri uri) uri)
                             #:streaming? #t
                             #:headers headers))
               (lambda (response port)
                 (let-values (((bytes truncated)
                               (if port
                                   (read-bounded port #:limit limit)
                                   (values #vu8() #f))))
                   (when port (close-port port))
                   (list response bytes truncated)))))
           'timed-out)))
    (cond
     ((eq? outcome 'timed-out)
      (result #:url (canonical-url uri) #:error 'timeout))
     ((and (pair? outcome) (eq? (car outcome) 'error))
      (let ((key (cadr outcome)))
        (log-debug (scriba-auto-logger)
                   "Request to ~a failed: ~a ~a" uri key (caddr outcome))
        (result #:url (canonical-url uri)
                #:error (cond
                         ((eq? key 'gnutls-error) 'tls-error)
                         ((eq? key 'getaddrinfo-error) 'dns-error)
                         ((eq? key 'system-error) 'connection-error)
                         ((memq key '(bad-header bad-request bad-response
                                      bad-content-length protocol-error))
                          'protocol-error)
                         (else 'request-failed)))))
     ((not (pair? outcome))
      (result #:url (canonical-url uri) #:error 'request-failed))
     (else
      (let* ((response (car outcome))
             (bytes (cadr outcome))
             (truncated (caddr outcome))
             (status (catch #t
                       (lambda () (response-code response))
                       (lambda _ #f)))
             (type (content-type-name response))
             (location (catch #t
                         (lambda () (response-location response))
                         (lambda _ #f)))
             (redirect? (and status (member status %redirect-statuses)))
             (success? (and status (>= status 200) (< status 300)))
             (error (cond
                     (redirect? 'redirect)
                     ((not status) 'protocol-error)
                     ((>= status 400)
                      (if (member status %retry-statuses) 'retry 'http-error))
                     ((member status '(300 304 305 306)) 'http-error)
                     (else #f)))
             (retry-after (catch #t
                            (lambda ()
                              (assq-ref (response-headers response) 'retry-after))
                            (lambda _ #f)))
             ;; An X-Robots-Tag header applies to whatever the response is,
             ;; including PDFs that carry no markup to parse.
             (robots-tag (catch #t
                           (lambda ()
                             (assq-ref (response-headers response) 'x-robots-tag))
                           (lambda _ #f)))
             (base (result #:url (canonical-url uri)
                           #:status status
                           #:content-type type
                           #:last-modified (last-modified-string response)
                           #:robots-tag robots-tag
                           #:truncated? truncated
                           #:body (and success?
                                       (decode-body
                                        bytes
                                        (response-content-type response)))
                           #:error error)))
        (cond
         (redirect? (append base (list (cons 'location location))))
         (retry-after (append base
                              (list (cons 'retry-after retry-after))))
         (else base)))))))

(define (retry-after-seconds response)
  "The server's requested pause before retrying, in seconds, if numeric."
  (let ((value (and response (assq-ref response 'retry-after))))
    (and value (string->number (if (string? value) value (format #f "~a" value))))))

(define* (backoff-seconds attempt #:optional (base 1))
  "Exponential backoff for the given zero-based ATTEMPT, capped at 30s."
  (min 30 (* (max base 0) (expt 2 (min attempt 5)))))

(define* (fetch-url url #:key
                    (user-agent default-user-agent)
                    (timeout default-timeout)
                    (retries default-retries)
                    (max-redirects 10)
                    (backoff 1)
                    (limit max-body-bytes)
                    (logger (scriba-auto-logger)))
  "GET URL and return a result alist, following redirects and retrying
transient failures.  Never raises; inspect `error' in the result."
  (define (log-attempt message . args)
    (apply log-debug logger message args))
  (let ((start (canonical-url url)))
    (if (not start)
        (begin
          (log-warning logger "Skipping unusable URL: ~a" url)
          (result #:url (and (string? url) url) #:error 'invalid-url))
        (let loop ((current start)
                   (seen '())
                   (redirects 0)
                   (attempt 0))
          (cond
           ((member current seen)
            (log-warning logger "Redirect loop at ~a" current)
            (result #:url current #:redirects redirects #:error 'redirect-loop))
           ((> redirects max-redirects)
            (log-warning logger "Too many redirects from ~a" start)
            (result #:url current #:redirects redirects
                    #:error 'too-many-redirects))
           (else
            (let ((response (request-once current
                                          #:user-agent user-agent
                                          #:timeout timeout
                                          #:limit limit)))
              (let ((error (result-error response)))
                (cond
                 ((eq? error 'redirect)
                  (let* ((location (assq-ref response 'location))
                         (next (and location (resolve-uri current location)))
                         (canonical (and next (canonical-url next))))
                    (if (not canonical)
                        (begin
                          (log-warning logger
                                       "Redirect from ~a has no usable Location"
                                       current)
                          (append (result #:url current #:redirects redirects
                                          #:error 'bad-redirect)
                                  '()))
                        (loop canonical
                              (cons current seen)
                              (+ redirects 1)
                              0))))
                 ((and (or (eq? error 'retry)
                           (memq error %retryable-errors))
                       (< attempt retries))
                  (let ((delay (or (retry-after-seconds response)
                                   (backoff-seconds attempt backoff))))
                    (log-attempt "Retrying ~a after ~as (~a)"
                                 current delay
                                 (or (assq-ref response 'status) error))
                    (sleep-seconds delay)
                    (loop current seen redirects (+ attempt 1))))
                 (else
                  (if error
                      (log-debug logger "Fetch of ~a failed: ~a"
                                 current error)
                      (log-attempt "Fetched ~a (~a bytes)" current
                                   (string-length (or (assq-ref response 'body) ""))))
                  (let ((final (result #:url current
                                       #:status (assq-ref response 'status)
                                       #:body (assq-ref response 'body)
                                       #:content-type
                                       (assq-ref response 'content-type)
                                       #:last-modified
                                       (assq-ref response 'last-modified)
                                       #:robots-tag
                                       (assq-ref response 'robots-tag)
                                       #:redirects redirects
                                       #:truncated?
                                       (assq-ref response 'truncated?)
                                       #:error error)))
                    (when (and error (not (eq? error 'retry)))
                      (log-debug logger "Fetch ~a: ~a" current error))
                    final)))))))))))

(define* (fetch-body #:key url continuation-proc (logger (scriba-auto-logger)))
  "The body of URL as text, or #f.

Kept for backwards compatibility.  CONTINUATION-PROC is accepted and
ignored; older callers used it to run the whole fetch loop inside this
function, which is exactly what made one bad page abort an entire crawl."
  (let ((response (fetch-url url #:logger logger)))
    (and (result-ok? response) (assq-ref response 'body))))
