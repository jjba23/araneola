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

(define-module (araneola http)
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
  #:export (parse-http-response fetch-body))

(define (parse-http-response response body)
  "Parses successful HTTP responses into an association list of string bodies and metadata."
  (let* ((s (scriba-auto-logger))
         (status (response-code response))
         (raw-lm (response-last-modified response #f))
         (last-modified (and raw-lm
                             (date->string raw-lm "~Y-~m-~d"))))
    (unless (= status 200)
      (with-log-context `((status ,status))
                        (log-info logger "Received HTTP status")))
    `((body unquote
            (if (bytevector? body)
                (utf8->string body) body))
      (last-modified unquote last-modified))))

(define* (fetch-body #:key continuation-proc url)
  "Fetches the URL and returns the body as a UTF-8 string, or #f on failure."
  (let ((s (scriba-auto-logger))
        (initial-uri (if (string? url)
                         (string->uri url) url)))
    (with-log-context `((url unquote url))
                      (log-info s "Fetching HTML"))
    (catch #t
           continuation-proc
           (lambda (key . args)
             (if (eq? key
                      'http-error)
                 (begin
                   (with-log-context `((error unquote key)
                                       (details unquote args)
                                       (url unquote url))
                                     (log-error s "Failed to fetch URL")) #f)
                 (apply throw key args))))))
