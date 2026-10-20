;; araneola tests: a small local web site to crawl.

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
;;; A deterministic stand-in for "the web": a Guile web server serving a tiny
;;; site with the awkward cases a crawler has to survive (a redirect, a 404,
;;; a PDF, a page guarded by robots.txt, malformed HTML, an off-site link, a
;;; fragment link, a flaky endpoint that fails twice then works) plus a
;;; black-hole server that accepts a request and never answers, for timeouts.
;;;
;;; The server runs on its own thread, so shared state lives in boxes rather
;;; than parameters (parameters are per-thread).
;;;
;;; Code:

(define-module (tests support)
  #:declarative? #t
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-111)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web server)
  #:use-module (web uri)
  #:export (start-site!
            stop-site!
            site-url
            requested-paths
            reset-requests!
            start-blackhole!
            stop-blackhole!
            blackhole-url))

;;; Paths the fixture site has served, most recent first.
(define requests (box '()))
(define flaky-hits (box 0))
(define drop-hits (box 0))
(define server (box #f))
(define blackhole-server (box #f))

(define (respond code headers body)
  (values (build-response #:code code #:headers headers) body))

(define html-headers '((content-type . (text/html))))

(define (page* title links head)
  (string-append
   "<!DOCTYPE html><html><head><title>" title "</title>" head "</head><body><h1>"
   title "</h1>"
   (string-join (map (lambda (href)
                       (string-append "<a href=\"" href "\">" href "</a>"))
                     links)
                "\n")
   "</body></html>"))

(define (page title links)
  (page* title links ""))

(define (record-request! path)
  (set-box! requests (cons path (unbox requests))))

;; The server passes its accumulated state as extra arguments.
(define (handler request body . state)
  (let* ((uri (request-uri request))
         (path (uri-path uri)))
    (record-request! path)
    (match path
      ("/" (respond 200 html-headers
                    (page "home"
                          '("/a" "/b" "/redirect" "/missing" "/private/secret"
                            "https://other.test/" "/fragment#top" "/doc.pdf"
                            "/bad" "/flaky" "/a#again" "/a?"
                            "/noindex" "/noindex-header" "/canonical"
                            "/admin/page"))))
      ;; A page that asks not to be indexed, but still links on.
      ("/noindex"
       (respond 200 html-headers
                (page* "noindex" '("/c")
                       "<meta name=\"robots\" content=\"noindex, follow\">")))
      ;; The same request expressed as a header, which also works for
      ;; documents there is no markup to read a meta tag from.
      ("/noindex-header"
       (respond 200 (list (cons 'content-type '(text/html))
                          (cons 'x-robots-tag "noindex"))
                (page "noindex header" '())))
      ;; Two spellings of one page, which should be listed once.
      ("/canonical"
       (respond 200 html-headers
                (page* "canonical" '()
                       "<link rel=\"canonical\" href=\"/a\">")))
      ;; A small subtree, to prove an exclusion stops the crawl at the door
      ;; rather than after fetching.
      ("/admin/page" (respond 200 html-headers
                              (page "admin" '("/admin/unlinked"))))
      ("/admin/unlinked" (respond 200 html-headers (page "admin" '())))
      ("/a" (respond 200 html-headers (page "a" '("/" "/b" "/c"))))
      ("/b" (respond 200 html-headers (page "b" '("/a"))))
      ("/c" (respond 200 html-headers (page "c" '())))
      ("/fragment" (respond 200 html-headers (page "fragment" '())))
      ("/private/secret" (respond 200 html-headers (page "secret" '())))
      ("/robots.txt" (respond 200 '((content-type . (text/plain)))
                            "User-agent: *\nDisallow: /private\n"))
      ("/redirect"
       (respond 302 (list (cons 'location (string->uri-reference "/a"))
                          (cons 'content-type '(text/html)))
                ""))
      ("/missing" (respond 404 html-headers (page "not found" '())))
      ("/doc.pdf" (respond 200 '((content-type . (application/pdf)))
                           "%PDF-1.4 not really a pdf"))
      ("/bad" (respond 200 html-headers
                       "<div><a href='/c'>c</a><p><b>unclosed <table>"))
      ("/flaky"
       ;; Fails twice, then works, to exercise the retry path.
       (let ((hits (unbox flaky-hits)))
         (set-box! flaky-hits (+ hits 1))
         (if (< hits 2)
             (respond 503 '((content-type . (text/html))) "busy")
             (respond 200 html-headers (page "flaky" '())))))
      ;; Closes the connection without answering, which is a transport
      ;; failure rather than an HTTP status: exactly what a dropped
      ;; connection looks like from the client side.
      ("/drop"
       (let ((hits (unbox drop-hits)))
         (set-box! drop-hits (+ hits 1))
         (if (< hits 2)
             (error "dropped connection")
             (respond 200 html-headers (page "drop" '())))))
      ("/hang" (sleep 60) (respond 200 html-headers "never"))
      (_ (respond 404 html-headers (page "404" '()))))))

;; `open-server' wants the server implementation record, while `run-server'
;; resolves the symbol itself; look it up once here.
(define http-impl (lookup-server-impl 'http))

(define (serve-forever handler http-server)
  (call-with-new-thread
   (lambda ()
     ;; The state is a list (it is spliced into the handler's arguments), so
     ;; it starts empty rather than #f.
     (let serve ((state '()))
       ;; A handler that throws is a fixture choice (see /drop), not a reason
       ;; to stop serving: the client sees the connection close.
       (serve (catch #t
                (lambda () (serve-one-client handler http-impl http-server state))
                (lambda _ state)))))))

(define* (open-on-free-port #:key (ports (iota 40 18800)))
  (let loop ((candidates ports))
    (and (pair? candidates)
         (or (catch #t
               (lambda ()
                 (cons (open-server http-impl (list #:port (car candidates)))
                       (car candidates)))
               (lambda _ #f))
             (loop (cdr candidates))))))

(define* (start-site! #:key (ports (iota 40 18800)))
  "Start the fixture site on the first free port and return its base URL."
  (let ((opened (open-on-free-port #:ports ports)))
    (if (not opened)
        (error "no free port for the test server")
        (begin
          (set-box! server (car opened))
          (serve-forever handler (car opened))
          (site-url (cdr opened))))))

(define (site-url port)
  (string-append "http://127.0.0.1:" (number->string port)))

(define (stop-site!)
  (let ((http-server (unbox server)))
    (set-box! server #f)
    (and http-server
         (catch #t
           (lambda () (close-server http-impl http-server))
           (lambda _ #f)))))

(define (requested-paths)
  (reverse (unbox requests)))

(define (reset-requests!)
  (set-box! requests '())
  (set-box! flaky-hits 0)
  (set-box! drop-hits 0))

;;; A server that reads the request and then never answers: the only reliable
;;; way to prove that one unresponsive host cannot hang the whole crawl.
(define* (start-blackhole! #:key (ports (iota 20 18900)))
  (let ((opened (open-on-free-port #:ports ports)))
    (if (not opened)
        (error "no free port for the black hole")
        (begin
          (set-box! blackhole-server (car opened))
          (serve-forever (lambda (request body . state)
                           (sleep 60)
                           (respond 200 html-headers "never"))
                         (car opened))
          (blackhole-url (cdr opened))))))

(define (blackhole-url port)
  (string-append "http://127.0.0.1:" (number->string port) "/"))

(define (stop-blackhole!)
  (let ((http-server (unbox blackhole-server)))
    (set-box! blackhole-server #f)
    (and http-server
         (catch #t
           (lambda () (close-server http-impl http-server))
           (lambda _ #f)))))
