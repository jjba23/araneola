;; araneola - high-performance web crawler and sitemap generator
;;
;; SPDX-License-Identifier: MIT
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;;; Commentary:
;;;
;;; Turning an HTML document into the list of URLs a crawler should visit.
;;;
;;; Three things make this less trivial than it looks:
;;;
;;; 1. Documents from the wild are broken.  `html->sxml-safe' never raises,
;;;    it returns #f for documents the parser cannot survive.
;;; 2. Attribute values arrive entity encoded ("?a=1&amp;b=2").  Feeding that
;;;    straight into a URL means requesting "b=amp;2" and publishing a broken
;;;    sitemap, so hrefs are decoded first.
;;; 3. Pages can carry a <base href>, which changes what a relative link
;;;    means, and rel="nofollow" asks crawlers not to follow a link.
;;;
;;; Code:

(define-module (araneola html)
  #:declarative? #t
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (htmlprag)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:use-module (araneola url)
  #:export (decode-entities
            html->sxml-safe
            extract-links-from-sxml
            page-links
            page-analysis
            noindex-content?))

(define %named-entities
  '(("amp" . "&")
    ("AMP" . "&")
    ("lt" . "<")
    ("LT" . "<")
    ("gt" . ">")
    ("GT" . ">")
    ("quot" . "\"")
    ("QUOT" . "\"")
    ("apos" . "'")
    ("nbsp" . " ")))

(define %entity-regexp
  (make-regexp "&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);"))

(define (numeric-entity name)
  "Decode NAME (\"#38\" or \"#x26\") to text, or #f when out of range."
  (let* ((hex? (or (string-prefix? "#x" name) (string-prefix? "#X" name)))
         (digits (if hex? (substring name 2) (substring name 1)))
         (value (catch #t
                  (lambda () (string->number digits (if hex? 16 10)))
                  (lambda _ #f))))
    (and (integer? value)
         (> value 0)
         (< value 1114112)
         (not (<= #xd800 value #xdfff))
         (string (integer->char value)))))

(define (entity->string name)
  "The text NAME stands for, or #f when the entity is unknown."
  (cond
   ((string-prefix? "#" name) (numeric-entity name))
   (else (or (assoc-ref %named-entities name)
             (assoc-ref %named-entities (string-downcase name))))))

(define* (decode-entities text #:optional (budget 64))
  "Replace HTML character references in TEXT with the characters they mean.

Unknown references are left untouched, and both the work list and the
number of replacements are bounded, so a pathological document cannot make
decoding run away."
  (define (rest-from offset)
    (substring text offset (string-length text)))
  (if (or (not (string? text))
          (not (string-contains text "&")))
      text
      (let loop ((offset 0) (out '()) (left budget))
        (if (or (<= left 0) (>= offset (string-length text)))
            (apply string-append (reverse (cons (rest-from (min offset
                                                                    (string-length text)))
                                                out)))
            (let ((match (regexp-exec %entity-regexp text offset)))
              (if (not match)
                  (apply string-append (reverse (cons (rest-from offset) out)))
                  (let* ((start (match:start match))
                         (end (match:end match))
                         (decoded (entity->string (match:substring match 1))))
                    (if decoded
                        (loop end
                              (cons decoded
                                    (cons (substring text offset start) out))
                              (- left 1))
                        ;; Not an entity we know: keep the text as written.
                        (loop end
                              (cons (match:substring match 0)
                                    (cons (substring text offset start) out))
                              (- left 1))))))))))

(define (html->sxml-safe html)
  "Parse HTML into SXML, or #f when it cannot be parsed.  Never raises."
  (and (string? html)
       (not (string-null? html))
       (catch #t
         (lambda () (html->sxml html))
         (lambda _ #f))))

(define (node-name node)
  (and (pair? node)
       (symbol? (car node))
       (string-downcase (symbol->string (car node)))))

(define (node-attrs node)
  "The attribute alist of NODE, or #f when it carries no (@ ...) list."
  (and (pair? node)
       (pair? (cdr node))
       (pair? (cadr node))
       (eq? '@ (car (cadr node)))
       (cdr (cadr node))))

(define (node-children node with-attrs?)
  (if with-attrs? (cddr node) (cdr node)))

(define (walk-sxml tree visit)
  "Call VISIT with (name attrs) for every tagged node of TREE."
  (cond
   ((not (pair? tree)) #f)
   ((symbol? (car tree))
    (let* ((name (node-name tree))
           (attrs (node-attrs tree)))
      (visit name attrs)
      (for-each (lambda (child)
                  (walk-sxml child visit))
                (node-children tree (and attrs #t)))))
   (else (for-each (lambda (child)
                     (walk-sxml child visit))
                   tree))))

(define (attr attrs key)
  (and attrs
       (let ((pair (assq key attrs)))
         (and pair (let ((value (cadr pair)))
                     (if (symbol? value) (symbol->string value) value))))))

(define (nofollow? attrs)
  (let ((rel (attr attrs 'rel)))
    (and rel
         (let ((tokens (string-split (string-downcase rel) #\space)))
           (member "nofollow" tokens)))))

;;; <meta name="robots"> is the standard spelling, but the search engine
;;; specific names are common enough (and equally binding) to be worth reading.
(define %robots-meta-names '("robots" "googlebot" "bingbot" "yandex"
                             "slurp" "baiduspider"))

(define (noindex-content? content)
  "True when a robots directive CONTENT asks not to be indexed.

`none' is shorthand for `noindex, nofollow', so it counts too.  The same
function reads the X-Robots-Tag header, which is spelled the same way."
  (and (string? content)
       (let ((low (string-downcase content)))
         (and (or (string-contains low "noindex")
                  (string-contains low "none"))
              #t))))

(define (rel-attrs? attrs token)
  (let ((rel (attr attrs 'rel)))
    (and rel
         (member token (string-split (string-downcase rel) #\space))
         #t)))

(define (collect-sxml-facts sxml respect-nofollow?)
  "One walk over SXML, gathering everything a crawl needs from a page.

Returns an alist of `hrefs' (raw, entity decoded, in document order),
`base', `noindex' and `canonical'."
  (let ((hrefs '())
        (base #f)
        (base-seen? #f)
        (noindex #f)
        (canonical #f))
    (walk-sxml
     sxml
     (lambda (name attrs)
       (cond
        ((equal? name "a")
         (let ((href (attr attrs 'href)))
           (when (and href
                      (not (string-null? (string-trim href)))
                      (or (not respect-nofollow?) (not (nofollow? attrs))))
             (set! hrefs (cons (decode-entities href) hrefs)))))
        ((and (equal? name "base") (not base-seen?))
         (let ((href (attr attrs 'href)))
           (when href
             (set! base-seen? #t)
             (set! base (decode-entities href)))))
        ((and (equal? name "meta") (not noindex))
         (let ((meta-name (attr attrs 'name))
               (content (attr attrs 'content)))
           (when (and meta-name content
                      (member (string-downcase meta-name) %robots-meta-names)
                      (noindex-content? content))
             (set! noindex #t))))
        ((and (equal? name "link") (not canonical))
         (let ((href (attr attrs 'href)))
           (when (and href (rel-attrs? attrs "canonical"))
             (set! canonical (decode-entities href))))))))
    (list (cons 'hrefs (reverse hrefs))
          (cons 'base base)
          (cons 'noindex noindex)
          (cons 'canonical canonical))))

(define* (extract-links-from-sxml #:key parent-domain url sxml
                                  (allow-subdomains? #f)
                                  (respect-nofollow? #t))
  "Every absolute, canonical, in-scope URL linked from SXML.

Links are resolved against URL (or against the document's <base href> when it
has one), entity decoded, canonicalised, and filtered to the site of
PARENT-DOMAIN.  Duplicates are removed.  Returns '() rather than raising."
  (if (not sxml)
      '()
      (let* ((page (or url parent-domain))
             (facts (collect-sxml-facts sxml respect-nofollow?))
             (base (or (and (assq-ref facts 'base)
                            (resolve-uri page (assq-ref facts 'base)))
                       page)))
        (delete-duplicates
         (filter-map (lambda (href)
                       (let* ((absolute (resolve-uri base href))
                              (canonical (and absolute
                                              (canonical-url absolute))))
                         (and canonical
                              (is-interesting-url?
                               #:parent-domain parent-domain
                               #:url canonical
                               #:allow-subdomains? allow-subdomains?)
                              canonical)))
                     (assq-ref facts 'hrefs))
         string=?))))

(define* (page-analysis #:key url html (allow-subdomains? #f))
  "Everything a crawl wants from the document HTML served at URL.

Returns an alist of `links' (the URLs to follow), `noindex' (the page asks
not to be indexed) and `canonical' (the URL the page says it should be
indexed as, or #f).  The document is parsed once for all three.  Any
failure yields empty answers rather than an exception."
  (define (empty)
    (list (cons 'links '()) (cons 'noindex #f) (cons 'canonical #f)))
  (let ((sxml (html->sxml-safe html)))
    (if (not sxml)
        (begin (log-debug (scriba-auto-logger) "Could not parse ~a" url)
               (empty))
        (catch #t
          (lambda ()
            (let* ((facts (collect-sxml-facts sxml #t))
                   (base (or (and (assq-ref facts 'base)
                                  (resolve-uri url (assq-ref facts 'base)))
                             url))
                   (canonical-ref (assq-ref facts 'canonical))
                   (canonical
                    (and canonical-ref
                         (let* ((absolute (resolve-uri base canonical-ref))
                                (canon (and absolute (canonical-url absolute))))
                           ;; A canonical pointing off-site is a claim about
                           ;; someone else's URL; it belongs in no sitemap we
                           ;; write.
                           (and canon
                                (is-interesting-url?
                                 #:parent-domain url
                                 #:url canon
                                 #:allow-subdomains? allow-subdomains?)
                                canon)))))
              (list (cons 'links
                          (extract-links-from-sxml
                           #:parent-domain url
                           #:url url
                           #:sxml sxml
                           #:allow-subdomains? allow-subdomains?))
                    (cons 'noindex (and (assq-ref facts 'noindex) #t))
                    (cons 'canonical canonical))))
          (lambda (key . args)
            ;; A page whose links cannot be read is a page we crawl no deeper;
            ;; say so at debug level rather than failing silently.
            (log-debug (scriba-auto-logger)
                       "Could not read links from ~a: ~a ~a"
                       url key args)
            (empty))))))

(define* (page-links #:key url html (allow-subdomains? #f))
  "Links to crawl from the HTML document at URL.  Returns '() on any failure."
  (assq-ref (page-analysis #:url url #:html html
                           #:allow-subdomains? allow-subdomains?)
            'links))
