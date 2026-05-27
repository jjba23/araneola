;; araneola: guile glyph generator

;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

;; araneola is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; araneola is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with araneola.  If not, see <https://www.gnu.org/licenses/>.

(define-module (araneola main)
  #:declarative? #f
  #:use-module (ice-9 format)
  #:use-module (ice-9 iconv)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 string-fun)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 getopt-long)
  #:use-module (araneola sxml)
  #:use-module (web client)
  #:use-module (rnrs bytevectors)
  #:use-module (htmlprag)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (main))

(define* (fetch-html #:key parent-domain url)
  "Fetches the URL and returns the body as a UTF-8 string."
  (let* ((s (scriba-auto-logger))
         (u (if (string-prefix? "/" url)
                (string-append parent-domain url) url))
         (_ (with-log-context `((url unquote u))
                              (log-info s "Fetching HTML")))
         (response+body (call-with-values (lambda ()
                                            (http-get u)) list))
         (response (car response+body))
         (body (cadr response+body)))
    ;; http-get may return a bytevector depending on the server's Content-Type
    (if (bytevector? body)
        (utf8->string body) body)))

(define* (is-interesting-url? #:key parent-domain url)
  (cond
    ((equal? "" url)
     #f)
    ((equal? "/" url)
     #f)
    ((equal? parent-domain url)
     #f)
    ((string-prefix? parent-domain url)
     #t)
    ((string-prefix? "/" url)
     #t)
    (else #f)))

(define* (extract-links #:key url sxml)
  "Recursively walks the SXML tree and extracts all interesting 'href' values from 'a' tags."
  (let loop
    ((tree sxml)
     (acc '()))
    (match tree
      (((quote a) ((quote @) attrs ...) . body) (let* ((href-pair (assq 'href
                                                                        attrs))
                                                       (href-val (if href-pair
                                                                  (cadr
                                                                   href-pair)
                                                                  #f)))
                                                  (if href-val
                                                      (loop body
                                                            (if (is-interesting-url?
                                                                 #:parent-domain
                                                                 url
                                                                 #:url
                                                                 href-val)
                                                                (cons href-val
                                                                 acc) acc))
                                                      (loop body acc))))

      ((tag ((quote @) attrs ...) . body) (loop body acc))

      ((head . tail) (loop tail
                           (loop head acc)))
      (_ acc))))

(define crawled-links (make-parameter '()))

(define* (araneola-crawl #:key parent-domain url)
  (let* ((s (scriba-auto-logger))
         (html (fetch-html #:parent-domain parent-domain
                           #:url url))
         (sxml (html->sxml html))
         (links (reverse (extract-links #:url url
                                        #:sxml sxml))))

    (with-log-context `((link-count unquote
                                    (length links))
                        (links unquote links))
                      (log-info s "Found links"))

    (for-each (lambda (link)
                (araneola-crawl #:parent-domain parent-domain
                                #:url link)) links)))

(define* (main #:key (args (command-line)))

  (let* ((option-spec '((resources (single-char #\r)
                                   (value #t))
                        (url (single-char #\u)
                             (value #t)
                             (required? #t))))
         (options (getopt-long args option-spec))
         (resources (option-ref options
                                'resources #f))
         (s (scriba-auto-logger))
         (raw-url (option-ref options
                              'url #f))
         (url (if (string-prefix? "https://" raw-url) raw-url
                  (string-append "https://" raw-url))))

    (with-log-context `((url unquote url))
                      (log-info s "Araneola is starting"))

    (araneola-crawl #:parent-domain url
                    #:url url)))
