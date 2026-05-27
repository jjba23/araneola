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

;; 1. Fetch the HTML
(define (fetch-html-string url)
  "Fetches the URL and returns the body as a UTF-8 string."
  (let* ((response+body (call-with-values (lambda ()
                                            (http-get url)) list))
         (response (car response+body))
         (body (cadr response+body)))
    ;; http-get may return a bytevector depending on the server's Content-Type
    (if (bytevector? body)
        (utf8->string body) body)))

;; 2 & 3. Parse and Extract SXML
(define (extract-links sxml)
  "Recursively walks the SXML tree and extracts all 'href' values from 'a' tags."
  (let loop
    ((tree sxml)
     (acc '()))
    (match tree
      ;; Match an <a> tag that has an attributes list (@ ...)
      (((quote a) ((quote @) attrs ...) . body) (let* ((href-pair (assq 'href
                                                                        attrs))
                                                       ;; Look for the href attribute
                                                       (href-val (if href-pair
                                                                  (cadr
                                                                   href-pair)
                                                                  #f)))
                                                  ;; Extract the value
                                                  (if href-val
                                                      (loop body
                                                            (cons href-val acc)) ;Add link and traverse children
                                                      (loop body acc)))) ;No href, just traverse children
      
      ((tag ((quote @) attrs ...) . body) (loop body acc))

      ((head . tail) (loop tail
                           (loop head acc)))
      (_ acc))))

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
         (url (option-ref options
                          'url #f)))
    
    (with-log-context `((url unquote url))
                      (log-info s "Araneola is starting"))
    (let* ((html (fetch-html-string url))
           (sxml (html->sxml html))
           (links (reverse (extract-links sxml))))
      
      (with-log-context `((link-count unquote
                                      (length links))
                          (links unquote links))
                        (log-info s "Found links"))
      ;; (for-each (lambda (link)
      ;; (display (string-append " - " link "\n"))) links)
      )))
