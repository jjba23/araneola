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
;;; robots.txt (RFC 9309).
;;;
;;; A crawler that ignores robots.txt is a crawler that gets its operator
;;; complained about, so this module is part of the default path: before a
;;; page is fetched, `robots-allowed?' is asked whether it may be.
;;;
;;; The rules that matter in practice:
;;;
;;; - Consecutive `User-agent' lines before any rule form a single group.
;;; - The most specific `Allow'/`Disallow' prefix wins; `Allow' wins ties, so
;;;   a long `Allow' can carve a hole in a broad `Disallow'.
;;; - `*' matches any run of characters and a trailing `$' anchors the end.
;;; - `Crawl-delay' is advisory, and is honoured as a minimum delay.
;;;
;;; Fetching policy when robots.txt is unavailable:
;;;
;;; - 2xx            parse and obey it.
;;; - 401 / 403      treat the whole host as disallowed (the server said no).
;;; - anything else  crawl, but say so at warning level.  A site owner
;;;                  generating their own sitemap should not end up with an
;;;                  empty file because robots.txt was briefly down.
;;;
;;; Code:

(define-module (araneola robots)
  #:declarative? #t
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (web uri)
  #:use-module (araneola http)
  #:use-module (araneola url)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (parse-robots
            robots-for
            robots-allowed?
            robots-crawl-delay
            robots-sitemaps
            fetch-robots
            empty-robots
            deny-all-robots))

;;; A robots value is an alist:
;;;
;;;   ((groups . (((agents . ("*")) (allow . ("/p")) (disallow . ("/q"))
;;;                (crawl-delay . 2)) ...))
;;;    (sitemaps . ("https://example.com/sitemap.xml"))
;;;    (status . 200))
;;;
;;; A rules value (what `robots-for' returns) is:
;;;
;;;   ((allow . ("/keep")) (disallow . ("/")) (crawl-delay . 2))

;; Built with `list'/`cons' rather than quoted: these values are mutated with
;; `assoc-set!' by callers, and mutating a literal is an error.
(define (empty-robots)
  (list (cons 'groups '())
        (cons 'sitemaps '())
        (cons 'status 'seen)))(define (deny-all-robots)
  (list (cons 'groups
              (list (list (cons 'agents '("*"))
                          (cons 'allow '())
                          (cons 'disallow '("/")))))
        (cons 'sitemaps '())
        (cons 'status 'denied)))

;;; ------------------------------------------------------------------
;;; Parsing
;;; ------------------------------------------------------------------

(define (strip-comment line)
  (let ((hash (string-index line #\#)))
    (string-trim-both (if hash (substring line 0 hash) line))))

(define (split-directive line)
  "Split \"Key: value\" into a down-cased key and a trimmed value, or #f."
  (let ((colon (string-index line #\:)))
    (and colon
         (let ((key (string-downcase (string-trim-both
                                      (substring line 0 colon))))
               (value (string-trim-both
                       (substring line (+ colon 1) (string-length line)))))
           (and (not (string-null? key))
                (cons key value))))))

;; Every key a group may ever need is created up front.  Groups are stored in
;; the `groups' list and also referenced by `current', so pushing a brand new
;; key-value pair would leave the copy in `groups' stale; mutating an existing
;; pair keeps both views pointing at the same rules.
(define (make-group agents)
  (list (cons 'agents agents)
        (cons 'allow '())
        (cons 'disallow '())
        (cons 'crawl-delay #f)))

(define (group-add-rule! group key value)
  (let ((existing (assq-ref group key)))
    (assoc-set! group key (append existing (list value)))))

(define (parse-robots text)
  "Parse robots.txt TEXT into a robots value.  Never raises."
  (if (not (string? text))
      (empty-robots)
      (let ((groups '())
            (sitemaps '())
            (current #f)
            ;; True while we are still collecting User-agent lines for the
            ;; group being built, i.e. before its first rule appears.
            (collecting-agents? #f))
        (for-each
         (lambda (raw-line)
           (let ((directive (split-directive (strip-comment raw-line))))
             (when directive
               (match directive
                 (("user-agent" . agent)
                  (let ((agent (string-downcase agent)))
                    (cond
                     (collecting-agents?
                      (assoc-set! current 'agents
                                  (append (assq-ref current 'agents)
                                          (list agent))))
                     (else
                      (set! current (make-group (list agent)))
                      (set! groups (append groups (list current)))
                      (set! collecting-agents? #t)))))
                 (("allow" . pattern)
                  (when (and current (not (string-null? pattern)))
                    (set! collecting-agents? #f)
                    (set! current (group-add-rule! current 'allow pattern))))
                 (("disallow" . pattern)
                  (when current
                    (set! collecting-agents? #f)
                    ;; "Disallow:" with no value means "allow everything",
                    ;; which is the same as having no rule at all.
                    (unless (string-null? pattern)
                      (set! current
                            (group-add-rule! current 'disallow pattern)))))
                 (("crawl-delay" . value)
                  (when current
                    (let ((seconds (catch #t
                                     (lambda () (string->number value))
                                     (lambda _ #f))))
                      (when seconds
                        (set! collecting-agents? #f)
                        (assoc-set! current 'crawl-delay seconds)))))
                 (("sitemap" . url)
                  (unless (string-null? url)
                    (set! sitemaps (append sitemaps (list url)))))
                 (_ #f)))))
         (string-split (if (string-null? text) "" text) #\newline))
        (list (cons 'groups groups)
              (cons 'sitemaps sitemaps)
              (cons 'status 'parsed)))))

;;; ------------------------------------------------------------------
;;; Rule selection
;;; ------------------------------------------------------------------

(define (agent-matches? pattern user-agent)
  "True when a group for PATTERN applies to USER-AGENT.

\"*\" matches every crawler; otherwise the token has to appear in the user
agent string, which is how a site's \"Araneola\" group is recognised."
  (let ((pattern (string-downcase pattern))
        (agent (string-downcase user-agent)))
    (or (string=? pattern "*")
        (and (not (string-null? pattern))
             (string-contains agent pattern) #t))))

(define (robots-for robots user-agent)
  "The rules in ROBOTS that apply to USER-AGENT.

Named groups take precedence over \"*\"; if any named group matches, the
wildcard groups are ignored, as RFC 9309 requires."
  (let* ((groups (or (assq-ref robots 'groups) '()))
         (named (filter (lambda (group)
                          (any (lambda (agent)
                                 (and (not (string=? agent "*"))
                                      (agent-matches? agent user-agent)))
                               (assq-ref group 'agents)))
                        groups))
         (selected (or (and (pair? named) named)
                       (filter (lambda (group)
                                 (any (lambda (agent)
                                        (string=? agent "*"))
                                      (assq-ref group 'agents)))
                               groups))))
    (list (cons 'allow (append-map (lambda (g) (or (assq-ref g 'allow) '()))
                                   selected))
          (cons 'disallow (append-map (lambda (g)
                                        (or (assq-ref g 'disallow) '()))
                                      selected))
          (cons 'crawl-delay
                (let ((delays (filter-map (lambda (g)
                                            (assq-ref g 'crawl-delay))
                                          selected)))
                  (and (pair? delays) (apply max delays)))))))

(define %regexp-specials
  (list #\. #\^ #\$ #\* #\+ #\? #\[ #\] #\( #\) #\{ #\} #\| #\\))

(define (regexp-escape text)
  (list->string
   (append-map (lambda (char)
                 (if (memv char %regexp-specials)
                     (list #\\ char)
                     (list char)))
               (string->list text))))

(define (pattern->regexp pattern)
  "Compile a robots.txt path pattern (with `*' and trailing `$') to a regexp."
  (let* ((anchored? (string-suffix? "$" pattern))
         (body (if anchored?
                   (substring pattern 0 (- (string-length pattern) 1))
                   pattern))
         (parts (string-split body #\*))
         (joined (string-join (map regexp-escape parts) ".*")))
    (make-regexp (string-append "^" joined (if anchored? "$" "")))))

(define (pattern-matches? pattern path)
  (and (not (string-null? pattern))
       (or (string=? pattern "/")
           (catch #t
             (lambda ()
               (if (string-contains pattern "*")
                   (and (regexp-exec (pattern->regexp pattern) path) #t)
                   (if (string-suffix? "$" pattern)
                       (string-suffix? (substring pattern 0
                                                  (- (string-length pattern) 1))
                                       path)
                       (string-prefix? pattern path))))
             (lambda _ #f)))))

(define (longest-match patterns path)
  "The length of the longest PATTERN matching PATH, or -1 when none does."
  (fold (lambda (pattern best)
          (if (pattern-matches? pattern path)
              (max best (string-length pattern))
              best))
        -1
        patterns))

(define (robots-allowed? rules path)
  "True when PATH may be fetched according to RULES."
  (let ((allow (longest-match (or (assq-ref rules 'allow) '()) path))
        (disallow (longest-match (or (assq-ref rules 'disallow) '()) path)))
    (cond
     ((< disallow 0) #t)
     ((< allow 0) #f)
     (else (>= allow disallow)))))

(define (robots-crawl-delay rules)
  (assq-ref rules 'crawl-delay))

(define (robots-sitemaps robots)
  (or (assq-ref robots 'sitemaps) '()))

;;; ------------------------------------------------------------------
;;; Fetching
;;; ------------------------------------------------------------------

(define* (robots-url origin)
  "The robots.txt URL for ORIGIN (a scheme and host, no trailing slash)."
  (let ((uri (catch #t
               (lambda () (string->uri-reference origin))
               (lambda _ #f))))
    (and uri (uri-host uri)
         (uri->string (build-uri (or (uri-scheme uri) 'https)
                                 #:host (uri-host uri)
                                 #:port (uri-port uri)
                                 #:path "/robots.txt")))))

(define* (fetch-robots origin #:key
                       (user-agent default-user-agent)
                       (timeout default-timeout)
                       (retries 1)
                       (logger (scriba-auto-logger)))
  "Fetch and parse robots.txt for ORIGIN.  Never raises.

Returns a robots value; `status' explains which policy was applied."
  (let ((url (robots-url origin)))
    (if (not url)
        (empty-robots)
        (let ((response (fetch-url url #:user-agent user-agent
                                   #:timeout timeout #:retries retries
                                   #:limit (* 512 1024)
                                   #:logger logger)))
          (cond
           ((result-ok? response)
            (let ((parsed (parse-robots (assq-ref response 'body))))
              (assoc-set! parsed 'status 200)))
           ((not (= (or (assq-ref response 'status) 0) 0))
            (let ((status (assq-ref response 'status)))
              (cond
               ((or (= status 401) (= status 403))
                (log-warning logger
                             "robots.txt for ~a returned ~a; treating the host as disallowed"
                             origin status)
                (deny-all-robots))
               (else
                (log-debug logger
                           "No usable robots.txt for ~a (~a); crawling freely"
                           origin status)
                (assoc-set! (empty-robots) 'status status)))))
           (else
            (log-warning logger
                         "Could not read robots.txt for ~a (~a); crawling freely"
                         origin (or (assq-ref response 'error) "no response"))
            (assoc-set! (empty-robots) 'status 'unreachable)))))))
