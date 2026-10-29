;; araneola - high-performance web crawler and sitemap generator
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;;
;;; Run with:
;;;
;;;   guile -L src -L . tests/run-tests.scm
;;;
;;; Every assertion here exists because the old crawler got it wrong, or
;;; because a crawler that gets it wrong is dangerous to a live site:
;;; leaving its scope, ignoring robots.txt, hanging on a dead socket, or
;;; publishing half a sitemap.
;;;
;;; Code:

(use-modules (srfi srfi-1)
             (srfi srfi-13)
             (srfi srfi-64)
             (ice-9 format)
             (ice-9 regex)
             (ice-9 string-fun)
             (ice-9 textual-ports)
             (web uri)
             (araneola url)
             (araneola html)
             (araneola robots)
             (araneola http)
             (araneola sitemap)
             (araneola araneola)
             (araneola main)
             (tests support))

(setenv "SCRIBA_LOG_LEVEL" "critical")

;; Keep our own handle on the runner: `test-end' resets the current runner to
;; #f, and the exit status has to be computed afterwards.
(define %test-runner (test-runner-simple))
(test-runner-current %test-runner)

(define (tmp-dir)
  (let ((dir (string-append "/tmp/araneola-tests-" (number->string (getpid)))))
    (catch #t (lambda () (mkdir dir)) (lambda _ #f))
    dir))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define (xml-unescape text)
  (string-replace-substring
   (string-replace-substring
    (string-replace-substring
     (string-replace-substring
      (string-replace-substring text "&lt;" "<")
      "&gt;" ">")
     "&quot;" "\"")
    "&apos;" "'")
   "&amp;" "&"))

(define (locs-in path)
  "The <loc> values in a sitemap, unescaped and in document order."
  (let ((text (read-file path)))
    (map (lambda (match)
           (xml-unescape (match:substring match 1)))
         (list-matches "<loc>([^<]*)</loc>" text))))

(define (file-exists-any? paths)
  (any file-exists? paths))

;;; ------------------------------------------------------------------
(test-begin "url")

(test-equal "resolves dot segments"
  "https://ex.test/d1/x/y.html"
  (uri->string (resolve-uri "https://ex.test/d1/d2/page.html" "../x/y.html")))
(test-equal "resolves path relative"
  "https://ex.test/d1/d2/y.html"
  (uri->string (resolve-uri "https://ex.test/d1/d2/page.html" "./y.html")))
(test-equal "resolves host relative"
  "https://ex.test/solo?q=1"
  (uri->string (resolve-uri "https://ex.test/d1/page.html" "/solo?q=1")))
(test-equal "resolves protocol relative"
  "https://cdn.other.test/i.png"
  (uri->string (resolve-uri "https://ex.test/d1/" "//cdn.other.test/i.png")))
(test-equal "resolves query only"
  "https://ex.test/d1/page?b=2"
  (uri->string (resolve-uri "https://ex.test/d1/page?a=1" "?b=2")))
(test-equal "resolves relative against a file"
  "https://ex.test/d1/sub/x.html"
  (uri->string (resolve-uri "https://ex.test/d1/page" "sub/x.html")))
(test-equal "garbage reference does not raise"
  #f
  (resolve-uri "https://ex.test/" "http://[::1"))

(test-equal "canonicalises scheme host port path and fragment"
  "http://ex.com/b/?x=1"
  (canonical-url "HTTP://Ex.com:80/A/../b/?x=1#frag"))
(test-equal "canonicalises missing path"
  "https://ex.com/"
  (canonical-url "https://ex.com"))
(test-equal "drops the https default port"
  "https://ex.com/a"
  (canonical-url "https://ex.com:443/a"))
(test-assert "rejects non http schemes"
  (not (canonical-url "mailto:someone@ex.com")))

(test-assert "refuses a look-alike host"
  (not (is-interesting-url? #:parent-domain "https://example.com"
                            #:url "https://example.com.evil.test/")))
(test-assert "accepts the same host"
  (is-interesting-url? #:parent-domain "https://example.com"
                       #:url "https://example.com/a"))
(test-assert "refuses subdomains by default"
  (not (is-interesting-url? #:parent-domain "https://example.com"
                            #:url "https://sub.example.com/a")))
(test-assert "accepts subdomains on request"
  (is-interesting-url? #:parent-domain "https://example.com"
                       #:url "https://sub.example.com/a"
                       #:allow-subdomains? #t))
(test-assert "refuses other schemes on the same host"
  (not (is-interesting-url? #:parent-domain "https://example.com"
                            #:url "ftp://example.com/a")))
(test-equal "path and query for robots checks"
  "/a/b?c=d"
  (url-path+query "https://ex.com/a/b?c=d"))

(test-end "url")

;;; ------------------------------------------------------------------
(test-begin "html")

(test-equal "decodes named entities"
  "a.php?x=1&y=2"
  (decode-entities "a.php?x=1&amp;y=2"))
(test-equal "decodes numeric entities"
  "café & co"
  (decode-entities "caf&#233; &#x26; co"))
(test-equal "keeps unknown entities"
  "&bogus; & &alsobogus;"
  (decode-entities "&bogus; &amp; &alsobogus;"))
(test-equal "leaves text without entities alone"
  "Tom & Jerry"
  (decode-entities "Tom & Jerry"))

(define fixture-html
  (string-append
   "<html><head><base href=\"/root/\"></head><body>"
   "<a href=\"a.html\">A</a>"
   "<a href='/b.html?x=1&amp;y=2'>B</a>"
   "<a href=\"https://ex.test/deep/p.html#frag\">C</a>"
   "<a href=\"../up.html\">D</a>"
   "<a href=\"mailto:x@y.z\">M</a>"
   "<a href=\"https://other.test/x\">O</a>"
   "<a href=\"nofollow.html\" rel=\"nofollow\">N</a>"
   "<a href=\"/b.html?x=1&amp;y=2\">B again</a>"
   "</body></html>"))

(test-equal "extracts resolvable in-scope links"
  '("https://ex.test/root/a.html"
    "https://ex.test/b.html?x=1&y=2"
    "https://ex.test/deep/p.html"
    "https://ex.test/up.html")
  (page-links #:url "https://ex.test/root/page.html" #:html fixture-html))
(test-equal "survives broken markup"
  '("https://ex.test/x")
  (page-links #:url "https://ex.test/" #:html "<a href=\"/x\""))
(test-equal "returns nothing for an empty document"
  '()
  (page-links #:url "https://ex.test/" #:html ""))
(test-assert "does not raise on binary noise"
  (begin (html->sxml-safe "\x00\x01binary") #t))

(test-assert "recognises a noindex meta tag"
  (assq-ref (page-analysis #:url "https://ex.test/p"
                           #:html (string-append
                                   "<html><head><meta name=\"ROBOTS\" "
                                   "content=\"NOINDEX, FOLLOW\"></head></html>"))
            'noindex))
(test-assert "treats meta none as noindex"
  (noindex-content? "none"))
(test-assert "does not mistake index for noindex"
  (not (assq-ref (page-analysis #:url "https://ex.test/p"
                                #:html (string-append
                                        "<html><head><meta name=\"robots\" "
                                        "content=\"index, follow\">"
                                        "</head></html>"))
                 'noindex)))
(test-equal "reads the canonical URL"
  "https://ex.test/x"
  (assq-ref (page-analysis #:url "https://ex.test/p"
                           #:html (string-append
                                   "<html><head><link rel=\"canonical\" "
                                   "href=\"/x\"></head></html>"))
            'canonical))
(test-assert "ignores a canonical pointing off-site"
  (not (assq-ref (page-analysis #:url "https://ex.test/p"
                                #:html (string-append
                                        "<html><head><link rel=\"canonical\" "
                                        "href=\"https://other.test/x\">"
                                        "</head></html>"))
                 'canonical)))
(test-equal "page-analysis survives an unparsable document"
  '((links) (noindex . #f) (canonical . #f))
  (page-analysis #:url "https://ex.test/" #:html ""))

(test-end "html")

;;; ------------------------------------------------------------------
(test-begin "robots")

(define robots-text
  (string-append
   "# a comment\n"
   "User-agent: *\n"
   "Disallow: /private/\n"
   "Allow: /private/keep\n"
   "Disallow: /*.pdf$\n"
   "Crawl-delay: 2\n"
   "\n"
   "User-agent: araneola\n"
   "User-agent: otherbot\n"
   "Disallow: /bot-trap\n"
   "Sitemap: https://ex.test/sitemap.xml\n"))

(define parsed (parse-robots robots-text))

(test-equal "groups consecutive user agents"
  2
  (length (assq-ref parsed 'groups)))
(test-equal "collects sitemap directives"
  '("https://ex.test/sitemap.xml")
  (robots-sitemaps parsed))

(define araneola-rules (robots-for parsed "Araneola/2.0 (+https://example.org)"))
(define wildcard-rules (robots-for parsed "SomeOtherCrawler/1.0"))

(test-assert "named groups take precedence over the wildcard"
  (not (robots-allowed? araneola-rules "/bot-trap/x")))
(test-assert "the wildcard rules do not leak into a named group"
  (robots-allowed? araneola-rules "/private/x"))

(test-assert "disallows a directory"
  (not (robots-allowed? wildcard-rules "/private/x")))
(test-assert "the longest matching allow wins"
  (robots-allowed? wildcard-rules "/private/keep/a"))
(test-assert "anchored wildcards are honoured"
  (not (robots-allowed? wildcard-rules "/doc.pdf")))
(test-assert "an anchored wildcard does not match a longer path"
  (robots-allowed? wildcard-rules "/doc.pdf.html"))
(test-assert "allows everything else"
  (robots-allowed? wildcard-rules "/"))
(test-equal "reads the crawl delay"
  2
  (robots-crawl-delay wildcard-rules))
(test-assert "empty robots.txt allows everything"
  (robots-allowed? (robots-for (parse-robots "") "Araneola") "/anything"))
(test-assert "an empty disallow allows everything"
  (robots-allowed? (robots-for (parse-robots "User-agent: *\nDisallow:\n")
                               "Araneola")
                   "/anything"))

(test-end "robots")

;;; ------------------------------------------------------------------
(test-begin "sitemap")

(define dir (tmp-dir))

(test-equal "escapes XML metacharacters"
  "a&amp;b&lt;c&gt;d&quot;e&apos;f"
  (xml-escape "a&b<c>d\"e'f"))
(test-equal "drops characters XML cannot carry"
  "ab"
  (xml-escape (string #\a #\nul #\b)))

(let ((path (string-append dir "/single.xml")))
  (let ((writer (open-sitemap-writer #:path path #:split? #f)))
    (sitemap-add! writer "https://ex.test/" "2024-05-06")
    (sitemap-add! writer "https://ex.test/a?x=1&y=2" #f)
    (test-equal "finishes to the requested path"
      path
      (sitemap-finish! writer)))
  (test-equal "writes every URL"
    '("https://ex.test/" "https://ex.test/a?x=1&y=2")
    (locs-in path))
  (test-assert "leaves no temporary file behind"
    (not (file-exists? (string-append path ".tmp")))))

(test-equal "escapes URLs in the document"
  "https://ex.test/a?x=1&amp;y=2"
  (let ((path (string-append dir "/escaped.xml")))
    (let ((writer (open-sitemap-writer #:path path #:split? #f)))
      (sitemap-add! writer "https://ex.test/a?x=1&y=2" #f)
      (sitemap-finish! writer))
    (let ((hit (regexp-exec (make-regexp "<loc>([^<]*)</loc>")
                            (read-file path))))
      (and hit (match:substring hit 1)))))

(let ((path (string-append dir "/many.xml")))
  (parameterize ((sitemap-max-urls 2))
    (let ((writer (open-sitemap-writer #:path path #:split? #t
                                       #:base-url "https://ex.test/sub")))
      (for-each (lambda (i)
                  (sitemap-add! writer
                                (string-append "https://ex.test/p"
                                               (number->string i))))
                '(1 2 3 4 5))
      (sitemap-finish! writer)))
  (test-equal "writes a sitemap index pointing at the parts"
    '("https://ex.test/sub/many-1.xml"
      "https://ex.test/sub/many-2.xml"
      "https://ex.test/sub/many-3.xml")
    (locs-in path))
  (test-equal "splits the URLs across parts"
    '("https://ex.test/p1" "https://ex.test/p2")
    (locs-in (string-append dir "/many-1.xml"))))

(let ((path (string-append dir "/aborted.xml")))
  (let ((writer (open-sitemap-writer #:path path)))
    (sitemap-add! writer "https://ex.test/x")
    (sitemap-abort! writer))
  (test-assert "an aborted crawl publishes nothing"
    (not (file-exists-any? (list path (string-append path ".tmp"))))))

(test-end "sitemap")

;;; ------------------------------------------------------------------
(test-begin "http")

(define site (start-site!))
(define hole (start-blackhole!))

(test-equal "fetches a page"
  200
  (assq-ref (fetch-url (string-append site "/a")) 'status))
(test-assert "reads the body"
  (string-contains (assq-ref (fetch-url (string-append site "/a")) 'body)
                   "<h1>a</h1>"))
(test-equal "reports the content type as a string"
  "text/html"
  (assq-ref (fetch-url (string-append site "/a")) 'content-type))
(test-equal "rejects an unusable URL without raising"
  'invalid-url
  (assq-ref (fetch-url "mailto:x@y.z") 'error))
(test-equal "a 404 is an error, not a crash"
  'http-error
  (assq-ref (fetch-url (string-append site "/missing")) 'error))
(test-equal "a 404 still reports its status"
  404
  (assq-ref (fetch-url (string-append site "/missing")) 'status))

(let ((response (fetch-url (string-append site "/redirect"))))
  (test-equal "follows a redirect" 200 (assq-ref response 'status))
  (test-equal "reports the final URL"
    (string-append site "/a")
    (assq-ref response 'url))
  (test-equal "counts redirects" 1 (assq-ref response 'redirects)))

(reset-requests!)
(test-equal "retries a transient failure"
  200
  (assq-ref (fetch-url (string-append site "/flaky")
                       #:retries 2 #:backoff 0.01)
            'status))

(test-equal "caps the body size"
  16
  (string-length
   (or (assq-ref (fetch-url (string-append site "/a") #:limit 16) 'body) "")))

(let* ((started (gettimeofday))
       (response (fetch-url hole #:timeout 0.3 #:retries 0))
       (elapsed (- (car (gettimeofday)) (car started))))
  (test-equal "gives up on a silent host" 'timeout (assq-ref response 'error))
  (test-assert "gives up quickly" (< elapsed 5)))

;; A dropped connection is a transport failure, not an HTTP status, and used
;; to be given up on without a second attempt.  The fixture records every
;; request it dropped, so this proves the retry rather than inferring it.
(reset-requests!)
(test-equal "retries a dropped connection"
  200
  (assq-ref (fetch-url (string-append site "/drop")
                       #:retries 2 #:backoff 0.01)
            'status))
(test-assert "the dropped connection really was retried"
  (>= (length (filter (lambda (path) (string=? path "/drop"))
                       (requested-paths)))
      2))

(test-end "http")

;;; ------------------------------------------------------------------
(test-begin "crawl")

(reset-requests!)
(let* ((path (string-append dir "/crawl.xml"))
       (writer (open-sitemap-writer #:path path #:split? #f))
       (stats (parameterize ((visited-urls (make-hash-table)))
                (araneola-crawl #:parent-domain site #:url (string-append site "/")
                                #:writer writer
                                #:timeout 2
                                #:retries 0)))
       (_ (sitemap-finish! writer))
       (locs (locs-in path))
       (requested (requested-paths)))
  (test-assert "crawls the seed page" (member (string-append site "/") locs))
  (test-assert "crawls linked pages" (member (string-append site "/a") locs))
  (test-assert "crawls deeper pages" (member (string-append site "/c") locs))
  (test-assert "follows redirects to their target"
    (member (string-append site "/a") locs))
  (test-assert "resolves fragment links to the real document"
    (member (string-append site "/fragment") locs))
  (test-assert "includes non-HTML documents"
    (member (string-append site "/doc.pdf") locs))
  (test-assert "survives broken markup" (member (string-append site "/bad") locs))
  (test-assert "does not repeat a URL"
    (= 1 (length (filter (lambda (loc) (string=? loc (string-append site "/a")))
                         locs))))
  (test-assert "never fetches what robots.txt disallows"
    (not (member "/private/secret" requested)))
  (test-assert "counts the robots.txt skips"
    (>= (assq-ref stats 'skipped-robots) 1))
  (test-assert "never leaves the site"
    (not (any (lambda (loc) (string-contains loc "other.test")) locs)))
  (test-assert "does not request an off-site host"
    (not (any (lambda (path) (string-contains path "other.test")) requested)))
  (test-assert "does not record the fragment"
    (not (any (lambda (loc) (string-contains loc "#")) locs)))
  (test-assert "reports at least one page fetched"
    (> (assq-ref stats 'fetched) 0))
  (test-assert "finishes on its own"
    (eq? (assq-ref stats 'stopped-by) 'done)))

(let* ((path (string-append dir "/bounded.xml"))
       (writer (open-sitemap-writer #:path path #:split? #f)))
  (reset-requests!)
  (let ((stats (parameterize ((visited-urls (make-hash-table)))
                 (araneola-crawl #:parent-domain site
                                 #:url (string-append site "/")
                                 #:writer writer
                                 #:max-urls 2
                                 #:timeout 2
                                 #:retries 0))))
    (sitemap-finish! writer)
    (test-equal "honours --max-urls" 'max-urls (assq-ref stats 'stopped-by))
    (test-equal "stops after the requested number of pages"
      2
      (assq-ref stats 'attempted))))

(let* ((path (string-append dir "/shallow.xml"))
       (writer (open-sitemap-writer #:path path #:split? #f)))
  (parameterize ((visited-urls (make-hash-table)))
    (araneola-crawl #:parent-domain site
                    #:url (string-append site "/")
                    #:writer writer
                    #:max-depth 0
                    #:timeout 2
                    #:retries 0))
  (sitemap-finish! writer)
  (test-equal "honours --max-depth"
    (list (string-append site "/"))
    (locs-in path)))

(let* ((path (string-append dir "/norobots.xml"))
       (writer (open-sitemap-writer #:path path #:split? #f)))
  (reset-requests!)
  (parameterize ((visited-urls (make-hash-table)))
    (araneola-crawl #:parent-domain site
                    #:url (string-append site "/")
                    #:writer writer
                    #:respect-robots? #f
                    #:timeout 2
                    #:retries 0))
  (sitemap-finish! writer)
  (test-assert "crawls disallowed paths when asked to"
    (member "/private/secret" (requested-paths))))

;;; A page can ask not to be indexed, and can name the URL it should be
;;; indexed as.  Both are hints a sitemap generator is expected to honour.
(let* ((path (string-append dir "/hints.xml"))
       (writer (open-sitemap-writer #:path path #:split? #f))
       (stats (parameterize ((visited-urls (make-hash-table)))
                (araneola-crawl #:parent-domain site
                                #:url (string-append site "/")
                                #:writer writer
                                #:timeout 2
                                #:retries 0)))
       (_ (sitemap-finish! writer))
       (locs (locs-in path)))
  (test-assert "leaves a noindex page out of the sitemap"
    (not (member (string-append site "/noindex") locs)))
  (test-assert "honours an X-Robots-Tag noindex header"
    (not (member (string-append site "/noindex-header") locs)))
  (test-assert "counts the noindex pages"
    (>= (assq-ref stats 'noindex) 2))
  (test-assert "still crawls the links of a noindex page"
    (member (string-append site "/c") locs))
  (test-assert "lists a page under its canonical URL"
    (not (member (string-append site "/canonical") locs)))
  (test-assert "keeps the canonical target in the sitemap"
    (member (string-append site "/a") locs)))

;;; --exclude and --include are checked before a page is queued, so an
;;; excluded subtree costs no requests at all.
(let* ((path (string-append dir "/excluded.xml"))
       (writer (open-sitemap-writer #:path path #:split? #f)))
  (reset-requests!)
  (let ((stats (parameterize ((visited-urls (make-hash-table)))
                 (araneola-crawl #:parent-domain site
                                 #:url (string-append site "/")
                                 #:writer writer
                                 #:exclude (list "/admin")
                                 #:timeout 2
                                 #:retries 0))))
    (sitemap-finish! writer)
    (test-assert "never requests an excluded subtree"
      (not (member "/admin/page" (requested-paths))))
    (test-assert "never follows a link out of an excluded page"
      (not (member "/admin/unlinked" (requested-paths))))
    (test-assert "keeps crawling what was not excluded"
      (member "/a" (requested-paths)))
    (test-assert "counts the filtered URLs"
      (>= (assq-ref stats 'filtered) 1))))

(let* ((path (string-append dir "/included.xml"))
       (writer (open-sitemap-writer #:path path #:split? #f)))
  (reset-requests!)
  (parameterize ((visited-urls (make-hash-table)))
    (araneola-crawl #:parent-domain site
                    #:url (string-append site "/")
                    #:writer writer
                    #:include (list "/a$")
                    #:timeout 2
                    #:retries 0))
  (sitemap-finish! writer)
  (test-assert "include patterns restrict what is fetched"
    (member "/a" (requested-paths)))
  (test-assert "include patterns keep the rest out"
    (not (member "/b" (requested-paths)))))

(let* ((path (string-append dir "/included-seed.xml"))
       (writer (open-sitemap-writer #:path path #:split? #f)))
  (reset-requests!)
  (parameterize ((visited-urls (make-hash-table)))
    (araneola-crawl #:parent-domain site
                    #:url (string-append site "/")
                    #:writer writer
                    #:include (list "/nothing-here")
                    #:timeout 2
                    #:retries 0))
  (sitemap-finish! writer)
  (test-assert "the seed is crawled even when it fails the include patterns"
    (member "/" (requested-paths))))

(test-end "crawl")

;;; ------------------------------------------------------------------
(test-begin "cli")

(define (quiet thunk)
  "Run THUNK with both standard ports going nowhere, for the exit status."
  (let ((sink (open-output-string)))
    (parameterize ((current-output-port sink)
                   (current-error-port sink))
      (thunk))))

(test-equal "--help exits successfully"
  0
  (quiet (lambda () (main #:args (list "araneola" "--help")))))
(test-equal "a missing --url is a usage error"
  2
  (quiet (lambda () (main #:args (list "araneola")))))
(test-equal "an unparsable --exclude is a usage error"
  2
  (quiet (lambda () (main #:args (list "araneola" "-u" "https://ex.test/"
                                        "--exclude" "[")))))
(test-equal "a --exclude without a value is a usage error"
  2
  (quiet (lambda () (main #:args (list "araneola" "-u" "https://ex.test/"
                                        "--exclude")))))
(test-equal "a non-numeric --max-urls is a usage error"
  2
  (quiet (lambda () (main #:args (list "araneola" "-u" "https://ex.test/"
                                        "--max-urls" "lots")))))
(test-assert "the help text documents the filters"
  (and (string-contains (with-output-to-string usage) "--exclude")
       (string-contains (with-output-to-string usage) "--include")))

;; The wrapper parses the command line once for the friendly error messages
;; and the Scheme program parses it again; a repeated option must survive the
;; trip, which `getopt-long' alone would not manage.
(test-equal "collects every --exclude and --include"
  '(("-u" "https://ex.test/") ("/admin" "/tmp") ("x") #f)
  (call-with-values
      (lambda ()
        (take-filter-options
         (list "araneola" "-u" "https://ex.test/"
               "--exclude" "/admin" "--exclude=/tmp" "--include" "x")))
    (lambda (rest excludes includes bad?)
      (list (cdr rest) excludes includes bad?))))

(test-end "cli")

(stop-site!)
(stop-blackhole!)

;;; ------------------------------------------------------------------
(let ((failures (test-runner-fail-count %test-runner))
      (passes (test-runner-pass-count %test-runner)))
  (format (current-error-port) "~%~a passed, ~a failed~%" passes failures)
  (force-output (current-error-port))
  (exit (if (and (zero? failures) (> passes 0)) 0 1)))
