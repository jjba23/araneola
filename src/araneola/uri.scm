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

;; araneola: guile glyph generator
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>

(define-module (araneola uri)
  #:declarative? #t
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:use-module (sxml simple)
  #:use-module (ice-9 getopt-long)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (htmlprag)
  #:use-module (srfi srfi-19)
  #:use-module (scriba auto)
  #:use-module (scriba scriba)
  #:export (resolve-uri normalize-url is-interesting-url?))

(define* (is-interesting-url? #:key parent-domain url)
  "Validates if the fully qualified URL belongs to the target domain."
  (cond
    ((string-contains url "../")
     #f)
    ((or (equal? "" url)
         (equal? "/" url)
         (equal? parent-domain url))
     #f)
    ((string-prefix? parent-domain url)
     #t)
    (else #f)))

(define (resolve-uri base relative)
  "Safely resolve absolute, relative, host-relative, or protocol-relative URIs against a base URI."
  (cond
   ((uri-scheme relative)
    relative) ;; Already an absolute URI
   ((uri-host relative)
    ;; Protocol-relative URI (e.g., //example.com/path)
    (build-uri (uri-scheme base)
               #:userinfo (uri-userinfo relative)
               #:host (uri-host relative)
               #:port (uri-port relative)
               #:path (uri-path relative)
               #:query (uri-query relative)
               #:fragment (uri-fragment relative)))
   ((string-prefix? "/" (uri-path relative))
    ;; Host-relative URI (e.g., /path/to/resource)
    (build-uri (uri-scheme base)
               #:userinfo (uri-userinfo base)
               #:host (uri-host base)
               #:port (uri-port base)
               #:path (uri-path relative)
               #:query (uri-query relative)
               #:fragment (uri-fragment relative)))
   (else
    ;; Path-relative URI (e.g., sub/path or ../path)
    (let* ((base-path (uri-path base))
           (last-slash (string-rindex base-path #\/))
           (dir (if last-slash (substring base-path 0 (+ last-slash 1)) "/"))
           (new-path (string-append dir (uri-path relative))))
      (build-uri (uri-scheme base)
                 #:userinfo (uri-userinfo base)
                 #:host (uri-host base)
                 #:port (uri-port base)
                 #:path new-path
                 #:query (uri-query relative)
                 #:fragment (uri-fragment relative))))))

(define (normalize-url parent-domain path)
  "Ensures correct joining of domain and paths to prevent double slashes."
  (let ((clean-domain (string-trim-right parent-domain #\/))
        (clean-path (string-trim path #\/)))
    (string-append clean-domain "/" clean-path)))
