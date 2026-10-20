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
;;; Writing sitemaps that a search engine will actually accept.
;;;
;;; Three properties matter:
;;;
;;; 1. The file is never observed half written.  Items stream into a ".tmp"
;;;    file and the finished file is renamed into place, so a crawl that is
;;;    interrupted (or a disk that fills) cannot publish invalid XML over a
;;;    good sitemap.
;;; 2. The protocol limits are respected.  A single sitemap may hold at most
;;;    50,000 URLs and weigh at most 50 MB; past that a sitemap index is
;;;    written instead, pointing at numbered sitemaps.
;;; 3. Text is escaped.  URLs with "&" are extremely common (every query
;;;    string) and unescaped they produce a file no parser will read.
;;;
;;; Code:

(define-module (araneola sitemap)
  #:declarative? #t
  #:use-module (ice-9 match)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-19)
  #:use-module (araneola url)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (sitemap-max-urls
            sitemap-max-bytes
            open-sitemap-writer
            sitemap-writer?
            sitemap-add!
            sitemap-finish!
            sitemap-abort!
            sitemap-count
            sitemap-paths
            xml-escape
            write-sitemap-header
            write-sitemap-item
            write-sitemap-footer))

;; Parameters rather than constants so tests (and unusually constrained
;; deployments) can shrink the limits without generating 50,000 URLs.
(define sitemap-max-urls (make-parameter 50000))
(define sitemap-max-bytes (make-parameter (* 50 1024 1024)))

(define %xml-escape-table
  '((#\& . "&amp;") (#\< . "&lt;") (#\> . "&gt;") (#\" . "&quot;")
    (#\' . "&apos;")))

(define (xml-escape text)
  "TEXT with the characters XML reserves replaced by references.

Characters that are not legal in XML 1.0 at all are dropped rather than
written out, because a single one makes the whole document unparsable."
  (if (not (string? text))
      ""
      (let loop ((chars (string->list text)) (out '()))
        (if (null? chars)
            (apply string-append (reverse out))
            (let* ((char (car chars))
                   (hit (assoc-ref %xml-escape-table char))
                   (code (char->integer char)))
              (loop (cdr chars)
                    (cons (cond
                           (hit hit)
                           ((or (< code 32) (= code 127)) "")
                           (else (string char)))
                          out)))))))

(define (today)
  (date->string (current-date) "~Y-~m-~d"))

(define-record-type <sitemap-writer>
  (%make-writer path split? base-url)
  sitemap-writer?
  (path writer-path)
  (split? writer-split?)
  (base-url writer-base-url)
  (port writer-port set-writer-port!)
  (parts writer-parts set-writer-parts!)
  (count writer-count set-writer-count!)
  (bytes writer-bytes set-writer-bytes!)
  (total writer-total set-writer-total!)
  (index writer-index set-writer-index!)
  (state writer-state set-writer-state!))

(define (tmp-path path)
  (string-append path ".tmp"))

(define (strip-tmp path)
  (if (string-suffix? ".tmp" path)
      (substring path 0 (- (string-length path) 4))
      path))

(define (part-path path index)
  "The path of sitemap number INDEX derived from PATH."
  (let ((stem (if (string-suffix? ".xml" path)
                  (substring path 0 (- (string-length path) 4))
                  path)))
    (string-append stem "-" (number->string index) ".xml")))

(define (file-name path)
  (let ((slash (string-rindex path #\/)))
    (if slash (substring path (+ slash 1) (string-length path)) path)))

(define (write-header port)
  (display "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" port)
  (display "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
           port)
  (force-output port))

(define (write-footer port)
  (display "</urlset>\n" port)
  (force-output port))

(define* (open-sitemap-writer #:key
                              (path "sitemap.xml")
                              (split? #t)
                              (base-url #f))
  "Open a writer that streams URLs into PATH.

With SPLIT? a crawl larger than one sitemap file is spread over numbered
files with a sitemap index at PATH; BASE-URL is the public location of that
directory and is used for the index entries."
  (let ((writer (%make-writer path (and split? #t) base-url)))
    (set-writer-parts! writer '())
    (set-writer-count! writer 0)
    (set-writer-bytes! writer 0)
    (set-writer-total! writer 0)
    (set-writer-index! writer (if split? 1 0))
    (set-writer-state! writer 'open)
    (let ((port (open-output-file (tmp-path (if split?
                                                (part-path path 1)
                                                path)))))
      (set-writer-port! writer port)
      (write-header port)
      writer)))

(define (current-part-path writer)
  (if (writer-split? writer)
      (part-path (writer-path writer) (writer-index writer))
      (writer-path writer)))

(define (rotatable? writer)
  (and (writer-split? writer)
       (or (>= (writer-count writer) (sitemap-max-urls))
           (>= (writer-bytes writer) (sitemap-max-bytes)))))

(define (rotate! writer)
  (let ((done (tmp-path (current-part-path writer))))
    (write-footer (writer-port writer))
    (close-port (writer-port writer))
    (set-writer-parts! writer (append (writer-parts writer) (list done)))
    (set-writer-index! writer (+ 1 (writer-index writer)))
    (set-writer-count! writer 0)
    (set-writer-bytes! writer 0)
    (let ((port (open-output-file (tmp-path (current-part-path writer)))))
      (set-writer-port! writer port)
      (write-header port))))

(define* (sitemap-add! writer url #:optional lastmod)
  "Append URL to the sitemap being written.  Returns #t when it was written."
  (and writer
       (eq? (writer-state writer) 'open)
       (not (string-null? (or url "")))
       (let* ((item (string-append
                     "  <url>\n    <loc>" (xml-escape url) "</loc>"
                     (if (and lastmod (not (string-null? lastmod)))
                         (string-append "\n    <lastmod>" (xml-escape lastmod)
                                        "</lastmod>")
                         "")
                     "\n  </url>\n"))
              (size (bytevector-length (string->utf8 item))))
         (display item (writer-port writer))
         (set-writer-count! writer (+ 1 (writer-count writer)))
         (set-writer-bytes! writer (+ size (writer-bytes writer)))
         (set-writer-total! writer (+ 1 (writer-total writer)))
         ;; Rotate only once the current part holds something, so an oversized
         ;; single document can never produce an empty sitemap.
         (when (rotatable? writer) (rotate! writer))
         #t)))

(define (write-index port writer entries)
  (display "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" port)
  (display "<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
           port)
  (for-each
   (lambda (entry)
     (let* ((part (car entry))
            (base (string-trim-right (writer-base-url writer) #\/))
            (location (string-append base "/" (file-name part))))
       (display "  <sitemap>\n" port)
       (display "    <loc>" port)
       (display (xml-escape location) port)
       (display "</loc>\n" port)
       (display "    <lastmod>" port)
       (display (today) port)
       (display "</lastmod>\n" port)
       (display "  </sitemap>\n" port)))
   entries)
  (display "</sitemapindex>\n" port)
  (force-output port))

(define (sitemap-finish! writer)
  "Close WRITER, publish its files and return the path of the document a
search engine should be pointed at.

This is where a partially written crawl becomes a whole file: every part
is finished, renamed into place and, when there is more than one, indexed."
  (and writer
       (case (writer-state writer)
         ((open)
          (write-footer (writer-port writer))
          (close-port (writer-port writer))
          (let* ((last-part (tmp-path (current-part-path writer)))
                 (parts (append (writer-parts writer) (list last-part)))
                 (finals (map strip-tmp parts)))
            (set-writer-parts! writer finals)
            ;; Rename the finished parts into place.
            (for-each (lambda (tmp final)
                        (when (file-exists? final) (delete-file final))
                        (rename-file tmp final))
                      parts finals)
            (cond
             ((not (writer-split? writer))
              (set-writer-state! writer 'finished)
              (writer-path writer))
             ((= 1 (length finals))
              ;; A single part: publish it as the requested sitemap itself.
              (when (file-exists? (writer-path writer))
                (delete-file (writer-path writer)))
              (rename-file (car finals) (writer-path writer))
              (set-writer-parts! writer (list (writer-path writer)))
              (set-writer-state! writer 'finished)
              (writer-path writer))
             (else
              (let ((index-tmp (tmp-path (writer-path writer))))
                (call-with-output-file index-tmp
                  (lambda (port)
                    (write-index port writer
                                 (map (lambda (part) (list part)) finals))))
                (when (file-exists? (writer-path writer))
                  (delete-file (writer-path writer)))
                (rename-file index-tmp (writer-path writer))
                (set-writer-state! writer 'finished)
                (writer-path writer))))))
         (else (writer-path writer)))))

(define (sitemap-abort! writer)
  "Give up on WRITER and remove every file it was going to publish.

The previously published sitemap, if any, is left untouched."
  (and writer
       (case (writer-state writer)
         ((open)
          (catch #t
            (lambda () (close-port (writer-port writer)))
            (lambda _ #f))
          (set-writer-state! writer 'aborted)
          (let ((candidates (cons (tmp-path (current-part-path writer))
                                  (writer-parts writer))))
            (for-each (lambda (path)
                        (when (file-exists? path)
                          (catch #t
                            (lambda () (delete-file path))
                            (lambda _ #f))))
                      candidates))
          #t)
         (else #f))))

(define (sitemap-count writer)
  (and writer (writer-total writer)))

(define (sitemap-paths writer)
  (and writer (writer-parts writer)))

;;; ------------------------------------------------------------------
;;; Compatibility helpers
;;; ------------------------------------------------------------------

(define (write-sitemap-header port)
  "Write the XML declaration and open the root urlset element."
  (write-header port))

(define (write-sitemap-item port url lastmod)
  "Append a single <url> element to PORT."
  (display (string-append "  <url>\n    <loc>" (xml-escape url) "</loc>"
                          (if lastmod
                              (string-append "\n    <lastmod>"
                                             (xml-escape lastmod) "</lastmod>")
                              "")
                          "\n  </url>\n")
           port)
  (force-output port))

(define (write-sitemap-footer port)
  "Close the root urlset element."
  (write-footer port))
