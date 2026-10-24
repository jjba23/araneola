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

(define-module (maak)
  #:declarative? #t
  #:use-module (maak maak)
  ;; The container helpers are imported under a prefix because the tasks
  ;; below are named the way maak exposes them on the command line.
  #:use-module ((maak container) #:prefix ct:))

;; ====== Maak constants ======

;; The path to the directory where the main project files will be deployed.
(define deploy-dir
  "/srv/http/jointhefreeworld.org")

;; The URL for the CSS stylesheet used to style API documentation.
(define api-docs-css-url
  "https://jointhefreeworld.org/static/css/jointhefreeworld.css")

(define project-name
  'araneola)

(define hot-reload-file-types
  '(scm))

(define sitemap-domain
  (make-parameter "jointhefreeworld.org"))

(define scriba-logger-options
  (string-join (map (lambda (x)
                      (format #f "~a=~a"
                              (car x)
                              (cdr x)))
                    `((SCRIBA_LOGGER . color-console))) " "))

;; ====== Maak tasks ======

(define (help)
  "Display program help screen."
  (program-shell (list "araneola" "--help")))

(define (default)
  "Default task to run, call program's help."
  (help))

(define (fmt)
  "Format Scheme source code files according to the Guix style guide."
  ;; The task below is named `run', so the builtin of that name has to be
  ;; named in full here rather than reached through the module's bindings.
  ((@ (maak maak) run)
   (list "find" "." "-maxdepth" "8" "-name" "*.scm" "-type" "f"
         "-exec" "guix" "style" "-f" "{}" ";")
   #:verbose? #t))

(define (repl)
  "Development REPL."
  (time-machine-manifest-shell (list "guile" "-L" "./src"
                                     "-c" "'((@ (ares server) run-nrepl-server))'")))

(define (docs)
  "Generate technical API documentation for Maak."
  (delete-file-recursively "doc")
  (time-machine-manifest-shell (list "documenta" "api" (~ "./src/~a" project-name)))
  (time-machine-manifest-shell (list "texi2any" "-v" "--html"
                                     (~ "--css-ref=~a" api-docs-css-url)
                                     "./doc/api/index.texi"))
  (mv "./index" "./doc/api-dist"))

(define (deploy)
  (docs)
  ;; Deploy ARANEOLA
  (mkdir-p (~ "~a/araneola" deploy-dir))
  (delete-file-recursively (~ "~a/araneola/dist" deploy-dir))
  (mv "dist"
      (~ "~a/araneola/dist" deploy-dir))
  ;; Deploy API docs
  (remkdir-p (~ "~a/api-docs/~a" deploy-dir project-name))
  (mv "doc/api-dist/*"
      (~ "~a/api-docs/~a" deploy-dir project-name)
      #:expand? #t)
  (delete-file-recursively "doc"))

(define (package-docker)
  "Build a Docker image for ARANEOLA."
  (guix-pack '()
             #:format "docker"
             #:image-tag "araneola"
             #:symlinks '("/bin=bin")
             #:extra-packages '("bash" "coreutils" "util-linux-with-udev" "guile")
             #:verbose? #t))

(define (push-docker-latest)
  "Push the latest locally generated Docker image to Dockerhub."
  (ct:container (list "push"
                      (~ "localhost/~a:latest" project-name)
                      (~ "docker.io/jjba23/~a:latest" project-name))
                #:verbose? #t))

(define (push-docker-tag)
  "Push the locally generated Docker image to Dockerhub."
  (git-fetch "--all")
  (let ((latest-tag (git-describe-tag)))
    (ct:container (list "push"
                        (~ "localhost/~a:latest" project-name)
                        (~ "docker.io/jjba23/~a:~a" project-name latest-tag))
                  #:verbose? #t)))

(define (dev-run)
  (time-machine-manifest-shell (list "guile" "-L" "./src"
                                     "-c" "'((@(araneola main) main))'"
                                     "--resources" "./resources"
                                     "--url" (sitemap-domain))
                               #:env (list scriba-logger-options)
                               #:verbose? #t))

(define (run)
  (time-machine-program-shell (list "araneola" "--url" (sitemap-domain))
                              #:env (list scriba-logger-options)))

(define (hot-reload)
  "Hot-reloading developer's setup."
  (manifest-shell (list "watchexec" "'maak run'"
                        "--clear"
                        "--exts"
                        (string-join (map symbol->string
                                          hot-reload-file-types) ",")
                        "--on-busy-update=restart"
                        "--shell" "bash"
                        "--watch" ".")
                  #:env (list scriba-logger-options)))

(define (hr)
  (hot-reload))

(define (dev)
  (hot-reload))

;; ====== Container tasks ======

(define (container-build)
  "Build the container image for araneola."
  (ct:container-build "." #:tag "araneola:latest" #:verbose? #t))

(define (container-run)
  "Run the container image for araneola."
  (ct:container-run "araneola" #:interactive? #t #:tty? #t #:verbose? #t))
