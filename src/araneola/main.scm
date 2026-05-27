;; araneola: guile glyph generator
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>
;; [License Header Preserved...]

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

(define visited-urls
  (make-parameter (make-hash-table)))

(define (normalize-url parent-domain path)
  "Ensures correct joining of domain and paths to prevent double slashes."
  (let ((clean-domain (string-trim-right parent-domain #\/))
        (clean-path (string-trim path #\/)))
    (string-append clean-domain "/" clean-path)))

(define* (fetch-html #:key parent-domain url)
  "Fetches the URL and returns the body as a UTF-8 string, or #f on failure."
  (let* ((s (scriba-auto-logger))
         (u (if (string-prefix? "/" url)
                (normalize-url parent-domain url) url)))
    (with-log-context `((url unquote u))
                      (log-info s "Fetching HTML"))

    (catch #t
           (lambda ()
             (let* ((response+body (call-with-values (lambda ()
                                                       (http-get u)) list))
                    (response (car response+body))
                    (body (cadr response+body)))
               (if (bytevector? body)
                   (utf8->string body) body)))
           (lambda (key . args)
             (with-log-context `((error unquote key)
                                 (url unquote u))
                               (log-error s "Failed to fetch URL")) #f))))

(define* (is-interesting-url? #:key parent-domain url)
  (cond
    ((or (equal? "" url)
         (equal? "/" url)
         (equal? parent-domain url))
     #f)
    ((string-prefix? parent-domain url)
     #t)
    ((string-prefix? "/" url)
     #t)
    (else #f)))

(define* (extract-links #:key url sxml)
  "Recursively walks the SXML tree and extracts all interesting 'href' values."
  (let loop
    ((tree sxml)
     (acc '()))
    (match tree
      ;; Match <a> tags with attributes
      (((quote a) ((quote @) attrs ...) . body) (let* ((href-pair (assq 'href
                                                                        attrs))
                                                       ;; Safely extract the string value from (href "url")
                                                       (href-val (and
                                                                  href-pair
                                                                  (cadr
                                                                   href-pair))))
                                                  (if (and href-val
                                                           (is-interesting-url?
                                                            #:parent-domain
                                                            url
                                                            #:url href-val))
                                                      (loop body
                                                            (cons href-val acc))
                                                      (loop body acc))))

      ;; Match other tags with attributes (skip the attributes, parse the body)
      ((tag ((quote @) attrs ...) . body) (loop body acc))

      ;; Traverse nested lists
      ((head . tail) (loop tail
                           (loop head acc)))

      ;; Base case
      (_ acc))))

(define* (araneola-crawl #:key parent-domain url)
  (let ((v-urls (visited-urls))
        (s (scriba-auto-logger)))
    ;; Only proceed if we haven't visited this URL yet
    (unless (hash-ref v-urls url)
      (hash-set! v-urls url #t) ;Mark as visited immediately
      
      (let* ((html (fetch-html #:parent-domain parent-domain
                               #:url url)))
        
        (when html
          (let* ((sxml (html->sxml html))
                 (links (reverse (extract-links #:url parent-domain
                                                #:sxml sxml))))
            
            (with-log-context `((link-count unquote
                                            (length links))
                                (links unquote links))
                              (log-info s "Found links"))

            (for-each (lambda (link)
                        (araneola-crawl #:parent-domain parent-domain
                                        #:url link)) links)))))))

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

    ;; Initialize a fresh hash table for the run
    (parameterize ((visited-urls (make-hash-table)))
      (araneola-crawl #:parent-domain url
                      #:url url))))
