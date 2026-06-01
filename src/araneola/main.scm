;; araneola: guile glyph generator
;; Copyright © Josep Bigorra <jjbigorra@gmail.com>
;; [License Header Preserved...]

(define-module (araneola main)
  #:declarative? #t
  #:use-module (ice-9 format)
  #:use-module (ice-9 iconv)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 string-fun)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (sxml simple)
  #:use-module (ice-9 getopt-long)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (rnrs bytevectors)
  #:use-module (htmlprag)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
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

(define* (fetch-html #:key url)
  "Fetches the URL and returns the body as a UTF-8 string, or #f on failure."
  (let* ((s (scriba-auto-logger)))
    (with-log-context `((url unquote url))
                      (log-info s "Fetching HTML"))

    (catch #t
           (lambda ()
             (let* ((response+body (call-with-values (lambda ()
                                                       (http-get url)) list))
                    (response (car response+body))
                    (body (cadr response+body))
                    (raw-lm (response-last-modified response #f))
                    (last-modified (if raw-lm
                                       (date->string raw-lm "~Y-~m-~d") #f)))
               (if (bytevector? body)
                   `((body unquote
                           (utf8->string body))
                     (last-modified unquote last-modified))
                   `((body unquote body)
                     (last-modified unquote last-modified)))))
           (lambda (key . args)
             (with-log-context `((error unquote key)
                                 (url unquote url))
                               (log-error s "Failed to fetch URL")) #f))))

(define* (is-interesting-url? #:key parent-domain url)
  (cond
    ((string-contains url "../")
     #f)
    ((or (equal? "" url)
         (equal? "/" url)
         (equal? parent-domain url))
     #f)
    ((string-prefix? parent-domain url)
     #t)
    ((string-prefix? "/" url)
     #t)
    (else #f)))

(define* (extract-links #:key parent-domain url sxml)
  "Recursively walks the SXML tree and extracts all interesting 'href' values."
  (let loop
    ((tree sxml)
     (acc '()))
    (match tree
      ;; Match <a> tags with attributes
      (((quote a) ((quote @) attrs ...) . body) (let* ((href-pair (assq 'href
                                                                        attrs))
                                                       (href-val (and
                                                                  href-pair
                                                                  (cadr
                                                                   href-pair))))
                                                  (if (and href-val
                                                           (is-interesting-url?
                                                            #:parent-domain
                                                            parent-domain
                                                            #:url href-val))
                                                      (loop body
                                                            (cons (if (string-prefix?
                                                                       "/"
                                                                       href-val)
                                                                   (normalize-url
                                                                    parent-domain
                                                                    href-val)
                                                                   href-val)
                                                                  acc))
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
    
    (unless (hash-ref v-urls url)
      (let ((d (fetch-html #:url url)))
        (hash-set! v-urls url
                   `((visited . #t) (last-modified unquote
                                                   (assq-ref d
                                                             'last-modified))))
        (when (assq-ref d
                        'body)
          (let* ((sxml (html->sxml (assq-ref d
                                             'body)))
                 (links (reverse (filter (lambda (l)
                                           ;; Only keep links we have NOT visited
                                           (not (hash-ref v-urls l)))
                                         (extract-links #:parent-domain
                                                        parent-domain
                                                        #:url url
                                                        #:sxml sxml)))))
            
            (with-log-context `((link-count unquote
                                            (length links))
                                (links unquote links))
                              (if (nil? links)
                                  (log-debug s "No links found")
                                  (log-info s "Found links")))

            (for-each (lambda (link)
                        (araneola-crawl #:parent-domain parent-domain
                                        #:url link)) links)))))))

(define (write-sitemap sxml filename)
  "Takes a SXML tree and writes a valid sitemap.xml using."
  (let* ((s (scriba-auto-logger))
         (out-port (open-output-file filename)))
    (with-log-context `((filename unquote filename))
                      (log-info s "Writing sitemap to file")
                      (sxml->xml sxml out-port)
                      (close-port out-port)
                      (log-success s "Wrote sitemap to file"))))

(define (make-sitemap urls)
  "Takes a list of URLs and writes a valid sitemap.xml using SXML."
  (let* ((xs (hash-map->list (lambda (k v)
                               (append v
                                       `((url unquote k))))
                             (visited-urls)))
         
         (valid-xs (filter (lambda (x)
                             (assq-ref x
                                       'url)) xs))

         (sitemap-sxml `(*TOP* (*PI* xml "version=\"1.0\" encoding=\"UTF-8\"")
                               (urlset (@ (xmlns
                                           "http://www.sitemaps.org/schemas/sitemap/0.9"))
                                       ,@(map (lambda (x)
                                                (let ((url (assq-ref x
                                                                     'url))
                                                      (lastmod (assq-ref x
                                                                         'last-modified)))
                                                  `(url (loc ,url)
                                                        ,@(if lastmod
                                                              `((lastmod ,lastmod))
                                                              '())))) valid-xs)))))
    sitemap-sxml))

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

    (parameterize ((visited-urls (make-hash-table)))
      (araneola-crawl #:parent-domain url
                      #:url url)
      (with-log-context `((total-link-count unquote
                                            (hash-count (const #t)
                                                        (visited-urls))))
                        (log-info s "Links found"))
      (write-sitemap (make-sitemap (visited-urls)) "sitemap.xml")
      (log-info s "Araneola is stopping"))))
