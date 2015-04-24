;; commands.scm -- snow commands
;;
;; This code was written by Alex Shinn in 2014 and placed in the
;; Public Domain.  All warranties are disclaimed.

(define known-implementations
  '((chibi "chibi-scheme" (chibi-scheme -V) "0.7.3")
    (chicken "chicken" (csi -p "(chicken-version)") "4.9.0")
    (foment "foment")
    (gauche "gosh" (gosh -E "print (gauche-version)" -E exit) "0.9.4")
    (kawa "kawa" (kawa --version) "2.0")
    (larceny "larceny" (larceny --version) "v0.98")
    (sagittarius "sagittarius")))

(define (impl->version impl cmd)
  (let* ((lines (process->string-list cmd))
         (line (and (pair? lines) (string-split (car lines)))))
    (and (pair? line)
         (if (and (pair? (cdr line))
                  (let ((x (string-downcase (car line)))
                        (name (symbol->string impl)))
                    (or (equal? x name)
                        (equal? x (string-append name "-scheme")))))
             (cadr line)
             (car line)))))

(define (impl-available? cfg spec confirm?)
  (if (find-in-path (cadr spec))
      (or (null? (cddr spec))
          (conf-get cfg 'skip-version-checks?)
          (let ((version (impl->version (car spec) (third spec))))
            (or (and version (version>=? version (fourth spec)))
                (let ((msg
                       (string-append
                        "Implementation " (symbol->string (car spec))
                        " is an unsupported version, " version ", but"
                        " at least " (fourth spec) " is required.")))
                  (cond
                   (confirm?
                    (yes-or-no? cfg msg " Install anyway?"))
                   (else
                    (warn msg)
                    #f))))))
      (and confirm?
           (yes-or-no? cfg "Implementation " (car spec) " does not "
                       " seem to be available, install anyway?"))))

(define (conf-selected-implementations cfg)
  (let ((requested (conf-get-list cfg 'implementations '(chibi))))
    (let lp ((ls (if (memq 'all requested)
                     (append (map car known-implementations)
                             (delete 'all requested))
                     requested))
             (res '()))
      (cond
       ((null? ls)
        (if (null? res)
            (warn "no implementations available"))
        (reverse res))
       ((memq (car ls) res)
        (lp (cdr ls) res))
       ((assq (car ls) known-implementations)
        => (lambda (x)
             (cond
              ((or (cond-expand (chibi (eq? 'chibi (car ls))) (else #f))
                   (impl-available? cfg x #t))
               (lp (cdr ls) (cons (car ls) res)))
              (else
               (warn "ignoring unavailable implementation" (car ls))
               (lp (cdr ls) res)))))
       ((yes-or-no? cfg "Unknown implementation: " (car ls)
                    " - try to install anyway?")
        (lp (cdr ls) (cons (car ls) res)))
       (else
        (warn "ignoring unknown implementation: " (car ls))
        (lp (cdr ls) res))))))

(define (conf-program-implementation? impl cfg)
  (cond ((conf-get cfg 'program-implementation)
         => (lambda (x) (eq? impl x)))
        (else
         (let ((ls (conf-selected-implementations cfg)))
           (or (null? ls) (eq? impl (car ls)))))))

(define (conf-for-implementation cfg impl)
  (conf-specialize cfg 'implementation impl))

;; Hack to evaluate an expression in a separate process with a larger
;; default heap.  The expression and result must be serializable with
;; write, and imports should be an argument list for environment.
;; Currently only used when generating keys and signing.
(define (fast-eval expr imports . o)
  (let* ((heap-size (if (pair? o) (car o) 500))
         (cmd
          `("chibi-scheme"
            ,(string-append "-h" (number->string heap-size) "M")
            ,@(map
               (lambda (i)
                 (string-append "-m" (string-join (map write-to-string i) ".")))
               imports)
            "-p" ,(write-to-string expr))))
    (let ((res (process->sexp cmd)))
      (if (eof-object? res)  ; process error
          (eval expr (apply environment imports))
          res))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Package - generate a package from one or more libraries.

(define (x->string x)
  (cond ((string? x) x)
        ((symbol? x) (symbol->string x))
        ((number? x) (number->string x))
        (else (error "not a valid path component" x))))

(define (library-path-base file name)
  (let lp ((ls (cdr (reverse name))) (dir (path-directory file)))
    (cond
     ((null? ls) dir)
     ((equal? (x->string (car ls)) (path-strip-directory dir))
      (lp (cdr ls) (path-directory dir)))
     (else dir))))

(define (path-relative file dir)
  (let ((file (path-normalize file))
        (dir (string-trim-right (path-normalize dir) #\/)))
    (string-trim-left
     (if (string-prefix? dir file)
         (substring file (string-length dir))
         file)
     #\/)))

;; remove import qualifiers
(define (import-name import)
  (cond
   ((and (pair? import)
         (memq (car import) '(only except prefix drop-prefix rename))
         (pair? (cadr import)))
    (import-name (cadr import)))
   (else import)))

(define (extract-library cfg file)
  (let ((lib (read-from-file file)))
    (match lib
      (('define-library (name ...)
         declarations ...)
       (let* ((dir (library-path-base file name))
              (lib-file (path-relative file dir))
              (lib-dir (path-directory lib-file)))
         (define (resolve file)
           (let ((dest-path (make-path lib-dir file)))
             (list 'rename (make-path dir dest-path) dest-path)))
         (define (ffi-file-includes file)
           (let lp ((forms (guard (exn (else '()))
                             (call-with-input-file file port->sexp-list)))
                    (res '()))
             (cond ((null? forms) (reverse res))
                   ((and (pair? (car forms))
                         (eq? 'c-include-verbatim (caar forms)))
                    (lp (cdr forms) (append (cdar forms) res)))
                   (else (lp (cdr forms) res)))))
         (define (ffi-files base)
           (let* ((path (path-resolve base (path-directory file)))
                  (stub-file (string-append path ".stub"))
                  (c-file (string-append path ".c")))
             (cond
              ((file-exists? stub-file)
               (cons (string-append base ".stub")
                     (ffi-file-includes stub-file)))
              ((file-exists? c-file)
               (list c-file))
              (else
               (warn "couldn't find ffi stub or c source" base)
               '()))))
         (let lp ((ls declarations)
                  (info `(,@(cond
                             ((conf-get cfg '(command package author))
                              => (lambda (x) (list (list 'author x))))
                             (else '()))
                          (path ,lib-file)
                          (name ,name)
                          library))
                  (deps '())
                  (files `((rename ,file ,lib-file)))
                  (chibi-ffi? #f))
           (cond
            ((null? ls)
             ;; Force a fake dependency on (chibi) if the chibi ffi is
             ;; used so this isn't available to other implementations.
             (let* ((deps (if (and chibi-ffi? (not (member '(chibi) deps)))
                              (cons '(chibi) deps)
                              deps))
                    (info (reverse (cons `(depends ,@deps) info))))
               (cons info files)))
            (else
             (match (car ls)
               (((or 'include 'include-ci) includes ...)
                (lp (cdr ls)
                    info
                    deps
                    (append (map resolve includes) files)
                    chibi-ffi?))
               (('include-library-declarations includes ...)
                (lp (append (append-map file->sexp-list includes) (cdr ls))
                    info
                    deps
                    (append (map resolve includes) files)
                    chibi-ffi?))
               (('include-shared includes ...)
                (lp (cdr ls)
                    info
                    deps
                    (append (map resolve (append-map ffi-files includes))
                            files)
                    #t))
               (('import libs ...)
                (lp (cdr ls)
                    info
                    (append (map import-name libs) deps)
                    files
                    chibi-ffi?))
               (('cond-expand clauses ...)
                (let ((libs+files (map (lambda (c) (lp c '() '() '() #f)) clauses)))
                  (lp (cdr ls)
                      (cons (cons 'cond-expand
                                  (map cons
                                       (map car clauses)
                                       (map car libs+files)))
                            info)
                      deps
                      (append files (append-map cdr libs+files))
                      chibi-ffi?)))
               (else
                (lp (cdr ls) info deps files chibi-ffi?))))))))
      (else
       (die 2 "not a valid library declaration " lib " in file " file)))))

(define (extract-program-dependencies file . o)
  (let ((depends (or (and (pair? o) (car o)) 'depends)))
    (let lp ((ls (guard (exn (else '()))
                   (if (and (pair? file) (eq? 'inline (car file)))
                       (port->sexp-list (open-input-string (cadr file)))
                       (file->sexp-list file))))
             (deps '())
             (cond-deps '()))
      (cond
       ((and (pair? ls) (pair? (car ls)) (eq? 'import (caar ls)))
        (lp (cdr ls)
            (append (reverse (map import-name (cdar ls))) deps)
            cond-deps))
       ((and (pair? ls) (pair? (car ls)) (eq? 'cond-expand (caar ls)))
        ;; flatten all imports, but maintain cond-expand's separately
        (let ((res (filter-map
                    (lambda (clause)
                      (let ((imps (lp (cdar ls) '() '())))
                        ;; TODO: support nested cond-expand's
                        (and (pair? imps)
                             (pair? (car imps))
                             (eq? depends (caar imps))
                             (list (car clause) (car imps)))))
                    (cdar ls))))
          (if (pair? res)
              (lp (cdr ls) deps `((cond-expand ,@res) ,@cond-deps))
              (lp deps cond-deps))))
       (else
        (append (if (pair? deps) (list (cons depends (reverse deps))) '())
                (if (pair? cond-deps) (reverse cond-deps) '())))))))

(define (make-package-name cfg pkg libs . o)
  (let ((name (or (assoc-get pkg 'name)
                  (any (lambda (x) (or (library-name x) (program-name x))) libs)))
        (version (and (pair? o) (car o))))
    (cond
     ((not (and (pair? name) (list? name)))
      (die 2 "Invalid library name: " name))
     ((not name)
      (die 2 "Couldn't determine package name from libs: " libs))
     (else
      (let lp ((ls (if version
                       (append name (list version))
                       name))
               (res '()))
        (if (null? ls)
            (string-join (reverse (cons ".tgz" res)))
            (lp (cdr ls)
                (cons (x->string (car ls))
                      (if (null? res) res (cons "-" res))))))))))

(define (check-overwrite cfg file type-pred type-name)
  (let ((mode (conf-get cfg '(command package overwrite) 'same-type)))
    (cond
     ((eq? mode 'always))
     ((file-exists? file)
      (case mode
        ((never)
         (die 2 "Destination " file " already exists, not overwriting"))
        ((same-type)
         (if (and (not (type-pred file))
                  (not (yes-or-no? cfg "Destination " file
                                   " doesn't look like a " type-name
                                   ", overwrite?")))
             (die 2 "Not overwriting " file)))
        ((confirm)
         (if (not (yes-or-no? cfg "Overwrite existing " file "?"))
             (die 2 "Not overwriting " file))))))))

;; Simplistic pretty printing for package/repository/config declarations.
(define (write-simple-pretty pkg out)
  (let wr ((ls pkg) (indent 0) (tails 0))
    (cond
     ((and (pair? ls)
           (pair? (cdr ls))
           (pair? (cadr ls)))
      (display (make-string indent #\space) out)
      (write-char #\( out)
      (write (car ls) out)
      (newline out)
      (for-each (lambda (x) (wr x (+ indent 2) 0)) (drop-right (cdr ls) 1))
      (wr (last ls) (+ indent 2) (+ tails 1)))
     (else
      (display (make-string indent #\space) out)
      (write ls out)
      (display (make-string tails #\)) out)
      (newline out)))))

;; We want to automatically bundle (foo bar *) when packaging (foo bar)
;; if it's already in the same directory.
(define (submodule->path cfg base file lib dep)
  (and base
       (> (length dep) (length base))
       (equal? base (take dep (length base)))
       ;; TODO: find-library(-relative)
       (let* ((dir (library-path-base file lib))
              (dep-file (make-path dir (string-append
                                        (library-name->path cfg dep)
                                        ".sld"))))
         (and (file-exists? dep-file) dep-file))))

(define (package-docs cfg spec libs lib-dirs)
  (guard (exn (else (warn "package-docs failed" exn)
                    '()))
    (cond
     ((conf-get cfg '(command package doc)) => list)
     ((conf-get cfg '(command package doc-from-scribble))
      (filter-map
       (lambda (lib)
         (let ((lib-name (library-file-name lib))
               (docs (extract-module-file-docs lib #f)))
           (and (pair? docs)
                (not (and (= 1 (length docs)) (eq? 'subsection (caar docs))))
                `(inline
                  ,(string-append (library-name->path cfg lib-name) ".html")
                  ,(call-with-output-string
                     (lambda (out)
                       (sxml-display-as-html
                        (generate-docs
                         `((title ,(write-to-string lib-name)) ,docs)
                         (guard (exn (else (make-default-doc-env)))
                           (make-module-doc-env lib-name)))
                        out)))))))
       libs))
     (else '()))))

(define package-description
  (let ((sent-re (regexp '(: "<p>" (* "\n") (* space) ($ (* (~ ("."))) "."))))
        (space-re (regexp '(or (: (* space) "\n" (* space)) (>= 2 space))))
        (tag-re (regexp '(: "<" (? "/") (* (~ ("<>"))) ">"))))
    (lambda (cfg spec libs docs)
      (cond
       ((conf-get cfg '(command package description)))
       ((conf-get cfg '(command upload description)))
       ;; Crazy hack, make this more robust, probably opt-in.
       ((and (pair? docs) (pair? (car docs)) (eq? 'inline (caar docs))
             (regexp-search sent-re (third (car docs))))
        => (lambda (m)
             (let ((s (regexp-match-submatch m 1)))
               (and s
                    (string-trim
                     (regexp-replace-all
                      space-re
                      (regexp-replace-all tag-re s "")
                      " "))))))
       (else #f)))))

(define (package-test cfg)
  (conf-get cfg '(command package test)))

(define (package-license cfg)
  (conf-get cfg '(command package license)))

(define (package-output-version cfg)
  (cond ((conf-get cfg '(command package version)))
        ((conf-get cfg '(command upload version)))
        ((conf-get cfg '(command package version-file))
         => (lambda (file) (call-with-input-file file read-line)))
        ((conf-get cfg '(command upload version-file))
         => (lambda (file) (call-with-input-file file read-line)))
        (else #f)))

(define (package-output-path cfg package-spec)
  (or (conf-get cfg '(command package output))
      (make-path
       (conf-get cfg '(command package output-dir) ".")
       (make-package-name
        cfg
        package-spec
        (filter (lambda (x) (and (pair? x) (memq (car x) '(library program))))
                package-spec)
        (package-output-version cfg)))))

(define (replace-library-pattern pat base-lib)
  (case (and (pair? pat) (car pat))
    ((append-to-last)
     (append (drop-right base-lib 1)
             (list
              (string->symbol
               (string-append (x->string (last base-lib))
                              (x->string (cadr pat)))))))
    ((append) (append base-lib (cdr pat)))
    ((quote) (cadr pat))
    (else pat)))

(define (find-library-from-pattern cfg pat lib . o)
  (cond ((not pat) #f)
        ((and (pair? pat) (eq? 'or (car pat)))
         (any (lambda (pat) (find-library-from-pattern pat lib)) (cdr pat)))
        (else
         (let ((lib-name (replace-library-pattern pat lib)))
           (apply find-library-file cfg lib-name o)))))

(define (tests-from-libraries cfg libs lib-dirs)
  (let ((pat (conf-get cfg '(command package test-library))))
    (cond
     ((string? pat)
      (list pat))
     ((symbol? pat)
      (list (symbol->string pat)))
     (else
      (filter-map
       (lambda (lib) (find-library-from-pattern cfg pat lib lib-dirs))
       libs)))))

(define (test-program-from-libraries lib-files)
  (call-with-output-string
    (lambda (out)
      (let* ((lib-names (filter-map library-file-name lib-files))
             (run-names
              (map (lambda (lib)
                     (string->symbol
                      (string-append "run-"
                                     (string-join (map x->string lib) "-")
                                     "-tests")))
                   lib-names)))
        (for-each
         (lambda (lib run)
           (write `(import (rename ,lib (run-tests ,run))) out)
           (newline out))
         lib-names
         run-names)
        (newline out)
        (for-each (lambda (run) (write `(,run) out) (newline out)) run-names)))))

(define (package-spec+files cfg spec libs)
  (define (symbols->strings x)
    (cond
     ((symbol? x) (symbol->string x))
     ((pair? x) (cons (symbols->strings (car x)) (symbols->strings (cdr x))))
     (else x)))
  (let* ((recursive? (conf-get cfg '(command package recursive?)))
         (programs (conf-get-list cfg '(command package programs)))
         (data-files (symbols->strings
                      (conf-get-list cfg '(command package data-files))))
         (name (conf-get cfg '(command package name)))
         (authors (conf-get-list cfg '(command package authors)))
         (test (package-test cfg))
         (version (package-output-version cfg))
         (maintainers (conf-get-list cfg '(command package maintainers)))
         (license (package-license cfg)))
    (let lp ((ls (map (lambda (x) (cons x #f)) libs))
             (progs programs)
             (res
              `(,@(if license `((license ,license)) '())
                ,@(if version `((version ,version)) '())
                ,@(if (pair? authors) `((authors ,@authors)) '())
                ,@(if (pair? maintainers) `((maintainers ,@maintainers)) '())
                ,@(if name `((name ,name)) '())))
             (files '())
             (lib-dirs '())
             (test test)
             (extracted-tests? #f))
      (cond
       ((pair? ls)
        (let* ((lib+files (extract-library cfg (caar ls)))
               (lib (car lib+files))
               (name (library-name lib))
               (base (or (cdar ls) name))
               (subdeps (if recursive?
                            (filter-map
                             (lambda (x)
                               (submodule->path cfg base (caar ls) name x))
                             (cond ((assq 'depends (cdr lib)) => cdr)
                                   (else '())))
                            '())))
          (lp (append (map (lambda (x) (cons x base)) subdeps) (cdr ls))
              progs
              (cons lib res)
              (append (reverse (cdr lib+files)) files)
              (delete-duplicates
               (cons (library-path-base (caar ls) name) lib-dirs))
              test
              extracted-tests?)))
       ((pair? progs)
        (lp ls
            (cdr progs)
            (cons `(program
                    (path ,(path-strip-leading-parents (car progs)))
                    ,@(extract-program-dependencies (car progs)))
                  res)
            (cons (car progs) files)
            lib-dirs
            test
            extracted-tests?))
       ((null? res)
        (die 2 "No packages generated"))
       ((and (not test)
             (not extracted-tests?)
             (tests-from-libraries
              cfg
              (filter-map (lambda (x) (and (library? x) (library-name x)))
                          res)
              lib-dirs))
        => (lambda (tests-from-libraries)
             (if (pair? tests-from-libraries)
                 (lp (append (map (lambda (x) (cons x #f)) tests-from-libraries)
                             ls)
                     progs
                     res
                     files
                     lib-dirs
                     `(inline
                       "run-tests.scm"
                       ,(test-program-from-libraries tests-from-libraries))
                     #t)
                 (lp ls progs res files lib-dirs test #t))))
       (else
        (let* ((docs (package-docs cfg spec libs lib-dirs))
               (desc (package-description cfg spec libs docs))
               (test-depends
                (if test
                    (extract-program-dependencies test 'test-depends)
                    '()))
               ;; cleanup - package data-files relative to the lib-dir
               (src-data-files
                (map (lambda (x) (if (pair? x) (cadr x) x)) data-files))
               (rel-data-files
                (if (= 1 (length lib-dirs))
                    (map (lambda (f) (path-relative-to f (car lib-dirs)))
                         data-files)
                    src-data-files))
               (tar-data-files
                (map (lambda (src rel) `(rename ,src ,rel))
                     src-data-files
                     rel-data-files))
               (pkg-data-files
                (if (= 1 (length lib-dirs))
                    (map (lambda (file rel)
                           (if (pair? file)
                               `(rename ,rel ,(third file))
                               rel))
                         data-files
                         rel-data-files)
                    data-files))
               (tar-files
                (reverse
                 (append (if test (list test)) docs tar-data-files files))))
          (cons `(package
                  ,@(reverse res)
                  ,@(if (pair? data-files) `((data-files ,@pkg-data-files)) '())
                  ,@(if (pair? docs)
                        `((manual ,@(map
                                     (lambda (x)
                                       (path-strip-leading-parents
                                        (if (pair? x) (cadr x) x)))
                                     docs)))
                        '())
                  ,@(if desc `((description ,desc)) '())
                  ,@(if test
                        `((test ,(path-strip-leading-parents
                                  (if (pair? test) (cadr test) test))))
                        '())
                  ,@test-depends)
                tar-files)))))))

(define (create-package spec files path)
  (gzip
   (tar-create #f `(,@files
                    (inline "package.scm"
                            ,(call-with-output-string
                               (lambda (out) (write-simple-pretty spec out)))))
               (let ((dir (path-strip-extension (path-strip-directory path))))
                 (lambda (f) (make-path dir f)))
               #t)))

(define (command/package cfg spec . libs)
  (let* ((spec+files (package-spec+files cfg spec libs))
         (output (package-output-path cfg (car spec+files)))
         (tarball (create-package (car spec+files) (cdr spec+files) output)))
    (check-overwrite cfg output package-file? "package")
    (let ((out (open-binary-output-file output)))
      (write-bytevector tarball out)
      (close-output-port out))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Index - add packages to a local repository file.

(define (command/index cfg spec repo-path . pkg-files)
  (let* ((dir (path-directory repo-path))
         (pkgs (filter-map
                (lambda (pkg-file)
                  (let ((pkg (package-file-meta pkg-file)))
                    (and pkg
                         `(,(car pkg)
                           (url ,(path-relative-to pkg-file dir))
                           ,@(cdr pkg)))))
                (if (pair? pkg-files)
                    pkg-files
                    (filter package-file?
                            (map
                             (lambda (f) (make-path dir f))
                             (directory-files dir))))))
         (repo (fold (lambda (pkg repo)
                       (let ((name (package-name pkg)))
                         `(,(car repo)
                           ,pkg
                           ,@(remove
                              (lambda (x) (equal? name (package-name x)))
                              (cdr repo)))))
                     (guard (exn (else (list 'repository)))
                       (car (file->sexp-list repo-path)))
                     pkgs)))
    (call-with-output-file repo-path
      (lambda (out) (write-simple-pretty repo out)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Gen-key - generate a new RSA key pair.

(define (conf-get-snow-dir cfg)
  (or (conf-get cfg 'snow-dir)
      (string-append (get-environment-variable "HOME") "/.snow")))

(define (rsa-key->sexp key name email . o)
  (let ((password (and (pair? o) (not (equal? "" (car o))) (car o))))
    `((name ,name)
      (email ,email)
      (bits ,(rsa-key-bits key))
      ,@(cond (password `((password ,password))) (else '()))
      ,@(cond
         ((rsa-key-e key)
          => (lambda (e)
               `((public-key
                  (modulus ,(integer->hex-string (rsa-key-n key)))
                  (exponent ,e)))))
         (else '()))
      ,@(cond
         ((rsa-key-d key)
          => (lambda (d)
               `((private-key
                  (modulus ,(integer->hex-string (rsa-key-n key)))
                  (exponent ,d)))))
         (else '())))))

(define (conf-gen-key cfg bits)
  (show #t "Generating a new key, this may take quite a while...\n")
  (if (conf-get cfg 'gen-key-in-process?)
      (rsa-key-gen bits)
      (let* ((lo (max 3 (expt 2 (- bits 1))))
             (hi (expt 2 bits))
             (p (fast-eval `(random-prime ,lo ,hi)
                           '((chibi math prime))))
             (q (fast-eval `(random-prime-distinct-from ,lo ,hi ,p)
                           '((chibi math prime)))))
        (rsa-key-gen-from-primes bits p q))))

(define (command/gen-key cfg spec)
  (show #t
        "Generate a new RSA key for signing packages.\n"
        "We need a descriptive name, and an email address to "
        "uniquely identify the key.\n")
  (let* ((name (input cfg '(gen-key name) "Name: "))
         (email (input cfg '(gen-key email) "Email: "))
         (passwd (input-password cfg '(gen-key password)
                                 "Password for upload: "
                                 "Password (confirmation): "))
         (bits (input-number cfg '(gen-key bits)
                             "RSA key size in bits: " 512 64 20148))
         (key (conf-gen-key cfg bits))
         (snow-dir (conf-get-snow-dir cfg))
         (key-file (or (conf-get cfg 'key-file)
                       (string-append snow-dir "/priv-key.scm")))
         (old-keys (guard (exn (else '()))
                     (call-with-input-file key-file read)))
         (new-keys
          (cons (rsa-key->sexp key name email passwd)
                ;; TODO: confirm overwrite, preserve old keys
                (remove (rsa-identity=? email) old-keys))))
    (if (not (file-directory? snow-dir))
        (create-directory snow-dir))
    (let* ((fd (open key-file (bitwise-ior open/write open/create) #o600))
           (out (open-output-file-descriptor fd)))
      (show out "("
            (joined (lambda (x)
                      (if (pair? x)
                          (each "(" (joined written x "\n  ") ")")
                          (written x)))
                    new-keys
                    "\n ")
            ")" nl)
      (close-output-port out)
      (show #t "Saved key to " key-file ".\n"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reg-key - register an RSA key pair with a repository.

(define (remote-uri cfg name path)
  (or (conf-get cfg name)
      (make-path (or (conf-get cfg 'host) "http://snow-fort.org")
                 path)))

(define (remote-command cfg name path params)
  (let ((uri (remote-uri cfg name path)))
    (sxml-display-as-text (read (http-post uri (cons '(fmt . "sexp") params))))
    (newline)))

(define (command/reg-key cfg spec)
  (let* ((keys (call-with-input-file
                   (or (conf-get cfg 'key-file)
                       (string-append (conf-get-snow-dir cfg) "/priv-key.scm"))
                 read))
         (email (or (conf-get cfg 'email)
                    (assoc-get (car keys) 'email)))
         (rsa-key-sexp (or (find (rsa-identity=? email) keys)
                           (and (not email) (car keys))))
         (name (assoc-get rsa-key-sexp 'name))
         ;; Register the sha-256 sum of email and password - we'll
         ;; never send the password itself over the network.
         ;; TODO: encrypt this
         (password
          (cond ((assoc-get rsa-key-sexp 'password)
                 => (lambda (pw) (sha-256 (string-append email pw))))
                (else #f)))
         (rsa-pub-key (extract-rsa-public-key rsa-key-sexp))
         (rsa-pub-key-str
          (write-to-string (rsa-key->sexp rsa-pub-key name email password))))
    (remote-command cfg
                    '(command reg-key uri)
                    "/pkg/reg"
                    `((u (file . "pub-key.scm")
                         (value . ,rsa-pub-key-str))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Sign - sign a package.

(define (generate-signature cfg package)
  (let* ((digest-name (conf-get cfg 'digest 'sha-256))
         (digest-func (lookup-digest digest-name))
         (raw-data (if (string? package)
                       (call-with-input-file package port->bytevector)
                       package))
         (snowball (maybe-gunzip raw-data))
         (digest (digest-func snowball))
         (keys (call-with-input-file
                   (or (conf-get cfg 'key-file)
                       (string-append (conf-get-snow-dir cfg) "/priv-key.scm"))
                 read))
         (email (or (conf-get cfg 'email)
                    (assoc-get (car keys) 'email)))
         (rsa-key-sexp (find (rsa-identity=? email) keys))
         (rsa-key (extract-rsa-private-key rsa-key-sexp)))
    (append
     `(signature
       (email ,email))
     (if (conf-get cfg 'sign-uploads?)
         (let* ((sig (fast-eval
                      `(rsa-sign (make-rsa-key ,(rsa-key-bits rsa-key)
                                               ,(rsa-key-n rsa-key)
                                               #f
                                               ,(rsa-key-d rsa-key))
                                 ;;,(hex-string->integer digest)
                                 ,(hex-string->bytevector digest))
                      '((chibi crypto rsa))))
                (hex-sig (if (bytevector? sig)
                             (bytevector->hex-string sig)
                             (integer->hex-string sig))))
           `((digest ,digest-name)
             (,digest-name ,digest)
             (rsa ,hex-sig)))
         '()))))

(define (command/sign cfg spec package)
  (let* ((dst (or (conf-get cfg 'output)
                  (path-replace-extension package "sig")))
         (sig (generate-signature cfg package)))
    (call-with-output-file dst
      (lambda (out) (write sig out)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Verify - verify a signature.

(define (command/verify cfg spec sig)
  (let* ((sig-spec (cdr (call-with-input-file sig read)))
         (keys (call-with-input-file
                   (or (conf-get cfg 'key-file)
                       (string-append (conf-get-snow-dir cfg) "/priv-key.scm"))
                 read))
         (email (assoc-get sig-spec 'email))
         (digest-name (assoc-get sig-spec 'digest #f 'sha-256))
         (digest (assoc-get sig-spec digest-name))
         (sig (assoc-get sig-spec 'rsa))
         (rsa-key-sexp (or (and (string? email)
                                (find (rsa-identity=? email) keys))
                           (car keys)))
         (rsa-key (extract-rsa-public-key rsa-key-sexp))
         (cipher (rsa-verify rsa-key (hex-string->bytevector sig)))
         (digest-bv (hex-string->bytevector digest)))
    (if (equal? cipher digest-bv)
        (show #t "signature valid " nl)
        (show #t "signature invalid " cipher " != " digest-bv nl))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Upload - upload a package.

(define (get-password cfg package)
  (and (not (conf-get cfg 'upload-without-password?))
       (let* ((keys (call-with-input-file
                        (or (conf-get cfg 'key-file)
                            (string-append (conf-get-snow-dir cfg)
                                           "/priv-key.scm"))
                      read))
              (email (or (conf-get cfg 'email)
                         (assoc-get (car keys) 'email)))
              (rsa-key-sexp (find (rsa-identity=? email) keys))
              (raw-password (assoc-get rsa-key-sexp 'password)))
         (and raw-password
              (sha-256 (string-append email raw-password))))))

(define (upload-package cfg spec package . o)
  (let ((password `(pw (value ,(get-password cfg))))
        (pkg (if (string? package)
                 `(u (file . ,package))
                 `(u (file . ,(if (pair? o) (car o) "package.tgz"))
                     (value . ,package))))
        (sig
         (cond
          ((conf-get cfg 'sig-file)
           => (lambda (sig-file) `(sig (file . ,sig-file))))
          (else
           (let ((sig (generate-signature cfg package)))
             `(sig (file . "package.sig")
                   (value . ,(write-to-string sig))))))))
    (remote-command cfg '(command package uri) "/pkg/put"
                    (list password pkg sig))))

(define (command/upload cfg spec . o)
  (define (non-homogeneous)
    (die 1 "upload arguments must all be packages or all be libraries, "
         "but got " o))
  (cond
   ((null? o)
    (die 1 "upload requires at least one input argument"))
   ((package-file? (car o))
    (if (not (every package-file? (cdr o)))
        (non-homogeneous))
    (for-each
     (lambda (package) (upload-package cfg spec package))
     o))
   (else
    (if (any package-file? (cdr o))
        (non-homogeneous))
    (let* ((spec+files (package-spec+files cfg spec o))
           (package-file (package-output-path cfg (car spec+files)))
           (package (create-package (car spec+files)
                                    (cdr spec+files)
                                    package-file)))
      (upload-package cfg spec package package-file)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Remove - removes the listed libraries.
;;
;; Provides a summary of the libraries to remove along with any
;; dependencies they have which were not explicitly installed.

(define (warn-delete-file file)
  (guard (exn (else (warn "couldn't delete file: " file)))
    (delete-file file)))

(define (delete-library-files impl cfg pkg lib-name)
  (for-each warn-delete-file (package-installed-files pkg))
  (warn-delete-file (make-path (get-install-source-dir impl cfg)
                               (get-package-meta-file cfg pkg)))
  (cond
   ((package->path cfg pkg)
    => (lambda (path)
         (let ((dir (make-path (get-install-source-dir impl cfg) path)))
           (if (and (file-directory? dir)
                    (= 2 (length (directory-files dir))))
               (delete-directory dir)))))))

(define (command/remove cfg spec . args)
  (let* ((impls (conf-selected-implementations cfg))
         (impl-cfgs (map (lambda (impl)
                           (conf-for-implementation cfg impl))
                         impls))
         (lib-names (map parse-library-name args)))
    (for-each
     (lambda (impl impl-cfg)
       (for-each (lambda (pkg lib-name)
                   (delete-library-files impl impl-cfg (cdr pkg) lib-name))
                 (lookup-installed-libraries impl impl-cfg lib-names)
                 lib-names))
     impls
     impl-cfgs)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Search - search for libraries matching keywords.
;;
;; Prints a list of libraries whose meta-info contain any of the given
;; keywords.  Returns in sorted order for how well the package matches.

(define (summarize-libraries cfg lib-names+pkgs)
  (for-each (lambda (name pkg) (describe-library cfg name pkg))
            (map car lib-names+pkgs)
            (map cdr lib-names+pkgs)))

;; faster than (length (regexp-extract re str))
(define (regexp-count re str)
  (regexp-fold re (lambda (from md str acc) (+ acc 1)) 0 str))

(define (count-in-sexp x keywords)
  (regexp-count `(word (w/nocase (or ,@keywords)))
                (write-to-string x)))

(define (extract-matching-libraries cfg repo keywords)
  (define (library-score lib)
    (+ (* 10 (count-in-sexp (library-name lib) keywords))
       (count-in-sexp lib keywords)
       (let ((use-for (assoc-get lib 'use-for)))
         (case (if (pair? use-for) (car use-for) use-for)
           ((test) 0)
           ((build) 10)
           (else 100)))))
  (append-map
   (lambda (x)
     (cond
      ((not (package? x)) '())
      (else
       (let ((pkg-score (count-in-sexp x keywords))
             (libs (package-libraries x)))
         (if (or (zero? pkg-score) (null? libs))
             '()
             (let lp ((libs (cdr libs))
                      (best-score (library-score (car libs)))
                      (best-lib (car libs)))
               (cond
                ((null? libs)
                 (list (cons (+ best-score pkg-score)
                             (cons (library-name best-lib) x))))
                (else
                 (let ((score (library-score (car libs))))
                   (if (> score best-score)
                       (lp (cdr libs) score (car libs))
                       (lp (cdr libs) best-score best-lib)))))))))))
   repo))

(define (extract-sorted-packages cfg repo keywords)
  (let ((ls (extract-matching-libraries cfg repo keywords)))
    (map cdr (sort ls > car))))

(define (command/search cfg spec . keywords)
  (let* ((repo (maybe-update-repository cfg))
         (lib-names+pkgs (extract-sorted-packages cfg repo keywords)))
    (if (pair? lib-names+pkgs)
        (summarize-libraries cfg lib-names+pkgs)
        (display "No libraries matched your query.\n"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Show - show detailed information for the given libraries
;;
;; The typical pattern is to use search to find the names of libraries
;; of interest, and show to see detailed information to decide whether
;; or not to install them.

(define (describe-library cfg library-name pkg)
  (let ((sexp? (conf-get cfg 'sexp?)))
    (if sexp? (display "("))
    (display library-name)
    (display (if sexp? " " "\t"))
    ((if sexp? write display) (package-version pkg))
    (if sexp? (display ")"))
    (newline)))

(define (command/show cfg spec . args)
  (maybe-update-repository cfg)
  (let* ((impls (conf-selected-implementations cfg))
         (impl-cfgs (map (lambda (impl)
                           (conf-for-implementation cfg impl))
                         impls))
         (lib-names (map parse-library-name args)))
    (for-each
     (lambda (impl impl-cfg)
       (for-each (lambda (name pkg) (describe-library impl-cfg name pkg))
                 (lookup-installed-libraries impl impl-cfg lib-names)
                 lib-names))
     impls
     impl-cfgs)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Update - update the repository.

(define (valid-repository? repo)
  (and (pair? repo) (list? repo) (eq? 'repository (car repo))))

(define (repository-dir cfg)
  (cond
   ((zero? (current-user-id))
    (or (conf-get cfg 'local-root-repository)
        "/usr/local/share/snow/repo"))
   (else
    (or (conf-get cfg 'local-user-repository)
        (make-path (conf-get-snow-dir cfg) "repo")))))

(define (update-repository cfg)
  (let* ((local-dir (repository-dir cfg))
         (local-path (make-path local-dir "repo.scm"))
         (local-tmp (string-append local-path ".tmp."
                                   (number->string (current-second)) "-"
                                   (number->string (current-process-id))))
         (repo-uri (remote-uri cfg 'repository-uri "/s/repo.scm"))
         (repo-str (utf8->string (resource->bytevector repo-uri)))
         (repo (guard (exn (else #f))
                 (let ((repo (read (open-input-string repo-str))))
                   `(,(car repo) (url ,repo-uri) ,@(cdr repo))))))
    (cond
     ((not (valid-repository? repo))
      (die 2 "not a valid repository: " repo-uri))
     ((not (create-directory* local-dir))
      (die 2 "can't create directory: " local-dir ))
     (else
      (guard (exn (else (die 2 "couldn't write repository")))
        (call-with-output-file local-tmp
          (lambda (out) (write repo out)))
        (if (file-exists? local-path)
            (rename-file local-path (string-append local-path ".bak")))
        (rename-file local-tmp local-path)
        repo)))))

(define (repository-stale? cfg)
  (let ((path (make-path (repository-dir cfg) "repo.scm")))
    (guard (exn (else #t))
      (> (current-second)
         (+ (file-modification-time path)
            ;; by default update once every 3 hours
            (conf-get cfg 'update-refresh (* 3 60 60)))))))

(define (should-update-repository? cfg)
  (case (conf-get cfg 'update-strategy 'cache)
    ((always) #t)
    ((never) #f)
    ((cache)
     (repository-stale? cfg))
    ((confirm)
     (and (repository-stale? cfg)
          (yes-or-no? cfg "Update repository info?")))
    (else
     (warn "unknown update-stategy: " (conf-get cfg 'update-strategy))
     #f)))

(define (maybe-update-repository cfg)
  (or (guard (exn (else #f))
        (and (should-update-repository? cfg)
             (update-repository cfg)))
      (guard (exn (else '(repository)))
        (call-with-input-file (make-path (repository-dir cfg) "repo.scm")
          read))))

(define (command/update cfg spec)
  (update-repository cfg))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Install - install one or more libraries.
;;
;; Installs the listed libraries along with their transitive closure
;; of dependencies.  For each library to install we confirm the
;; current status (skipping if already installed), the signature and
;; trust (optionally updating the trust level), and the default tests.
;; If multiple implementations are targeted, we install separately but
;; use the same confirmations for each.

(define (get-install-dirs impl cfg)
  (define (guile-eval expr)
    (guard (exn (else #f))
      (process->sexp `(guile -c ,(write-to-string `(write ,expr))))))
  (case impl
    ((chibi)
     (let* ((dirs
             (reverse
              (cond-expand
               (chibi (eval '(current-module-path) (environment '(chibi))))
               (else (process->sexp
                      '(chibi-scheme -q -p "(current-module-path)"))))))
            (share-dir (find (lambda (d) (string-contains d "/share/")) dirs)))
       (if share-dir
           (cons share-dir (delete share-dir dirs))
           dirs)))
    ((gauche)
     (list
      (let ((dir (process->string '(gauche-config "--sitelibdir"))))
        (or (and (string? dir) (> (string-length dir) 0)
                 (eqv? #\/ (string-ref dir 0))
                 dir)
            "/usr/local/share/gauche/"))))
    ((guile)
     (let ((path
            (guile-eval
             '(string-append (cdr (assq 'pkgdatadir %guile-build-info))
                             (string (integer->char 47))
                             (effective-version)))))
       (list
        (if (string? path)
            path
            "/usr/local/share/guile/"))))
    ((larceny)
     (list
      (make-path
       (process->string
        '(larceny -quiet -nobanner -- -e
                  "(begin (display (getenv \"LARCENY_ROOT\")) (exit))"))
       "lib/Snow")))
    (else
     (list (make-path "/usr/local/share/snow" impl)))))

(define (scheme-script-command impl cfg)
  (or (and (eq? impl 'chibi) (conf-get cfg 'chibi-path))
      (let* ((prog (cond ((assq impl known-implementations) => cadr)
                         (else "scheme-script")))
             (path (or (find-in-path prog) prog))
             (arg (case impl
                    ((chicken) "-s")
                    ((gauche) "-b")
                    ((larceny) "-program")
                    (else #f))))
        (if (and path arg)
            (string-append path " " arg)
            path))))

(define (scheme-program-command impl cfg file . o)
  (let ((lib-path (and (pair? o) (car o)))
        (install-dir (get-install-source-dir impl cfg)))
    (case impl
      ((chibi)
       (let ((chibi (string-split (conf-get cfg 'chibi-path "chibi-scheme"))))
         (if lib-path
             `(,@chibi -A ,install-dir -A ,lib-path ,file)
             `(,@chibi -A ,install-dir ,file))))
      ((chicken)
       (if lib-path
           `(csi -R r7rs -I ,install-dir -I ,lib-path -s ,file)
           `(csi -R r7rs -I ,install-dir -s ,file)))
      ((foment)
       (if lib-path
           `(foment -A ,install-dir -A ,lib-path ,file)
           `(foment -A ,install-dir ,file)))
      ((gauche)
       (if lib-path
           `(gosh -A ,install-dir -A ,lib-path ,file)
           `(gosh -A ,install-dir ,file)))
      ((guile)
       (if lib-path
           `(guile -L ,install-dir -L ,lib-path ,file)
           `(guile -L ,install-dir ,file)))
      ((kawa)
       (let ((install-dir (path-resolve install-dir (current-directory))))
         (if lib-path
             `(kawa
               ,(string-append "-Dkawa.import.path=" install-dir ":"
                               (path-resolve lib-path (current-directory)))
               --r7rs --script ,file)
             `(kawa ,(string-append "-Dkawa.import.path=" install-dir)
                    --r7rs --script ,file))))
      ((larceny)
       (if lib-path
           `(larceny -r7rs -path ,(string-append install-dir ":" lib-path)
                     -program ,file)
           `(larceny -r7rs -path ,install-dir -program ,file)))
      (else
       #f))))

(define (get-install-search-dirs impl cfg)
  (let ((install-dir (get-install-source-dir impl cfg))
        (other-dirs (get-install-dirs impl cfg)))
    (cons install-dir (delete install-dir other-dirs))))

(define (find-library-meta impl cfg name)
  (let ((dirs (get-install-search-dirs impl cfg)))
    (let lp ((subname name))
      (or (find-sexp-in-path
           (package-name->meta-file cfg subname)
           dirs
           (lambda (x)
             (and (package? x)
                  (or (equal? name (package-name x))
                      (any (lambda (y) (equal? name (library-name y)))
                           (package-libraries x))
                      (any (lambda (y) (equal? name (program-name y)))
                           (package-programs x))))))
          (and (pair? (cdr subname))
               (lp (drop-right subname 1)))))))

;; test the package locally built in dir
(define (test-package impl cfg pkg dir)
  (let* ((test-file (cond ((assoc-get pkg 'test)
                           => (lambda (f) (path-resolve f dir)))
                          (else #f)))
         (command (scheme-program-command impl cfg test-file dir)))
    (cond
     ((and test-file command
           (not (or (conf-get cfg '(command install skip-tests?))
                    (conf-get cfg '(command upgrade skip-tests?)))))
      ;; install any data files locally in the dir
      (let ((true-install-dir (get-install-data-dir impl cfg))
            (test-install-dir
             (make-path dir (string-append "tmp-data-"
                                           (number->string
                                            (current-process-id)))))
            (data-files (package-data-files pkg)))
        (for-each
         (lambda (file)
           (let* ((src (make-path dir (if (pair? file) (cadr file) file)))
                  (dest0 (if (pair? file) (third file) file))
                  (dest (make-path test-install-dir
                                   (if (path-absolute? dest0)
                                       (path-relative-to dest0 true-install-dir)
                                       dest0))))
             (create-directory* (path-directory dest))
             (install-file cfg src dest)))
         (package-data-files pkg))
        (setenv "SNOW_TEST_DATA_DIR" test-install-dir))
      ;; Run the tests from within the temp directory.  This reduces
      ;; stray output in the pwd, can be useful for accessing data
      ;; files during testing, and is needed for chicken (see chicken
      ;; trac #736).
      ;; For chibi we run from the current directory anyway for the
      ;; sake of running snow-tests from an uninstalled chibi-scheme.
      (or (match ((if (eq? impl 'chibi) (lambda (dir f) (f)) with-directory)
                  dir
                  (lambda () (process->output+error+status command)))
            ((output error status)
             (cond
              ((or (not (zero? status))
                   (string-contains output "FAIL")
                   (string-contains error "FAIL")
                   (string-contains output "ERROR")
                   (string-contains error "ERROR"))
               (call-with-output-file (make-path dir "test-out.txt")
                 (lambda (out) (display output out)))
               (call-with-output-file (make-path dir "test-err.txt")
                 (lambda (err) (display error err)))
               (display output)
               (display error)
               #f)
              (else
               (info "All tests passed.")
               (cond ((or (conf-get cfg '(command install show-tests?))
                          (conf-get cfg '(command upgrade show-tests?)))
                      (display output)
                      (display error)))
               #t)))
            (other
             (warn "Test error: " other)
             #f))
          (yes-or-no? cfg "Tests failed: " test-file
                      " (details in " dir "/test-{out,err}.txt)\n"
                      "Proceed anyway?")))
     (else
      #t))))

(define (lookup-installed-libraries impl cfg names)
  (map (lambda (name)
         (cons name
               (or (find-library-meta impl cfg name)
                   `(not-installed ,name))))
       names))

(define (installed-libraries impl cfg)
  (delete-duplicates
   (directory-fold-tree
    (get-install-source-dir impl cfg)
    #f #f
    (lambda (file acc)
      (cond
       ((and (equal? "meta" (path-extension file))
             (guard (exn (else #f))
               (let ((pkg (call-with-input-file file read)))
                 (and (package? pkg) pkg))))
        => (lambda (pkg)
             (append
              (map
               (lambda (lib) (cons (library-name lib) pkg))
               (package-libraries pkg))
              acc)))
       (else acc)))
    '())
   (lambda (a b) (equal? (car a) (car b)))))

(define (get-install-source-dir impl cfg)
  (cond
   ((conf-get cfg 'install-source-dir))
   ((conf-get cfg 'install-prefix)
    => (lambda (prefix) (make-path prefix "share/snow" impl)))
   (else (car (get-install-dirs impl cfg)))))

(define (get-install-data-dir impl cfg)
  (cond
   ((conf-get cfg 'install-data-dir))
   ((conf-get cfg 'install-prefix)
    => (lambda (prefix) (make-path prefix "share/snow" impl)))
   (else (car (get-install-dirs impl cfg)))))

(define (get-install-library-dir impl cfg)
  (cond
   ((conf-get cfg 'install-library-dir))
   ((conf-get cfg 'install-prefix)
    => (lambda (prefix) (make-path prefix "share/snow" impl)))
   ((eq? impl 'chicken) (make-path "/usr/local/lib" impl 7))
   (else (make-path "/usr/local/lib" impl))))

(define (get-install-binary-dir impl cfg)
  (cond
   ((conf-get cfg 'install-binary-dir))
   ((conf-get cfg 'install-prefix)
    => (lambda (prefix) (make-path prefix "bin")))
   (else "/usr/local/bin")))

(define (get-library-extension impl cfg)
  (or (conf-get cfg 'library-extension)
      (case impl
        ((gauche kawa) "scm")
        (else "sld"))))

(define (install-with-sudo? cfg path)
  (case (conf-get cfg '(command install use-sudo?))
    ((always) #t)
    ((never) #f)
    (else
     (let lp ((path path))
       (let ((dir (path-directory path)))
         (and (not (file-is-writable? path))
              (or (file-exists? path)
                  (lp dir))))))))

(define (install-file cfg source dest)
  (if (install-with-sudo? cfg dest)
      (system "sudo" "cp" source dest)
      (system "cp" source dest)))

(define (install-sexp-file cfg obj dest)
  (if (install-with-sudo? cfg dest)
      (call-with-temp-file "sexp"
        (lambda (tmp-path out preserve)
          (write-simple-pretty obj out)
          (close-output-port out)
          (system "sudo" "cp" tmp-path dest)))
      (call-with-output-file dest
        (lambda (out) (write-simple-pretty obj out)))))

(define (install-symbolic-link cfg source dest)
  (if (install-with-sudo? cfg dest)
      (system "sudo" "ln" "-s" source dest)
      (symbolic-link-file source dest)))

(define (install-directory cfg dir)
  (cond
   ((file-directory? dir))
   ((install-with-sudo? cfg dir)
    (system "sudo" "mkdir" "-p" dir))
   (else
    (create-directory* dir))))

(define (install-package-meta-info impl cfg pkg)
  (let* ((meta-file (get-package-meta-file cfg pkg))
         (install-dir (get-install-source-dir impl cfg))
         (path (make-path install-dir meta-file)))
    ;; write the package name
    (install-sexp-file cfg pkg path)
    ;; symlink utility libraries for which the package can't be inferred
    (let ((pkg-name (package-name pkg)))
      (for-each
       (lambda (lib)
         (let ((lib-name (library-name lib)))
           (if (not (equal? pkg-name (take lib-name (length pkg-name))))
               (let* ((lib-meta (make-path install-dir
                                           (get-library-meta-file cfg lib)))
                      (rel-path
                       (path-relative-to path (path-directory lib-meta))))
                 (install-symbolic-link cfg rel-path lib-meta)))))
       (package-libraries pkg)))))

;; The default installer just copies the library file and any included
;; source files to the installation directory.
;; Returns a list of installed files.
(define (default-installer impl cfg library dir)
  (let* ((library-file (get-library-file cfg library))
         (ext (get-library-extension impl cfg))
         (dest-library-file (path-replace-extension library-file ext))
         (include-files
          (library-include-files impl cfg (make-path dir library-file)))
         (install-dir (get-install-source-dir impl cfg)))
    ;; install the library file
    (let ((path (make-path install-dir dest-library-file)))
      (install-directory cfg (path-directory path))
      (install-file cfg (make-path dir library-file) path)
      ;; install any includes
      (cons
       path
       (map
        (lambda (x)
          (let ((dest-file (make-path install-dir (path-relative x dir))))
            (install-directory cfg (path-directory dest-file))
            (install-file cfg x dest-file)
            dest-file))
        include-files)))))

(define (chicken-installer impl cfg library dir)
  (let* ((library-file (get-library-file cfg library))
         (library-base (string-join (map x->string (library-name library)) "."))
         (install-dir (get-install-library-dir impl cfg))
         (so-path (string-append library-base ".so"))
         (imp-path (string-append library-base ".import.scm"))
         (dest-so-path (make-path install-dir so-path))
         (dest-imp-path (make-path install-dir imp-path)))
    (install-directory cfg install-dir)
    (let ((meta-dir
           (string-join (map x->string (drop-right (library-name library) 1))
                        "/")))
      (install-directory cfg (make-path install-dir meta-dir)))
    (install-file cfg (make-path dir so-path) dest-so-path)
    (install-file cfg (make-path dir imp-path) dest-imp-path)
    (list dest-so-path dest-imp-path)))

;; installers should return the list of installed files
(define (lookup-installer installer)
  (case installer
    ((chicken) chicken-installer)
    (else default-installer)))

(define (installer-for-implementation impl cfg)
  (case impl
    ((chicken) 'chicken)
    (else 'default)))

(define (install-library impl cfg library dir)
  (let ((installer
         (lookup-installer (or (conf-get cfg 'installer)
                               (installer-for-implementation impl cfg)))))
    (installer impl cfg library dir)))

;; The default builder just renames files per implementation.
;; Returns a new library object with any renames.
(define (default-builder impl cfg library dir)
  (let* ((library-file (get-library-file cfg library))
         (ext (get-library-extension impl cfg))
         (src-library-file (make-path dir library-file))
         (library-dir (path-directory src-library-file))
         (dest-library-file (path-replace-extension library-file ext))
         (include-files
          (library-include-files impl cfg (make-path dir library-file)))
         (rewrite-include-files
          ;; Rewrite if any include has the same path as the library
          ;; declaration file after extension renaming.
          ;; TODO: Also rewrite for implementations which require certain
          ;; characters to be escaped.
          ;; TODO: Also rewrite if multiple libs use same file names?
          ;; For now we assume libraries with the same prefix cooperate.
          (filter-map
           (lambda (x)
             (and (equal? x (make-path dir dest-library-file))
                  (list x (string-append x ".renamed.scm"))))
           include-files))
         (relative-rewrite-include-files
          (map (lambda (x)
                 (list (path-relative-to (car x) library-dir)
                       (path-relative-to (cadr x) library-dir)))
               rewrite-include-files)))
    ;; rename
    (for-each
     (lambda (x)
       (rename-file (car x) (cadr x)))
     rewrite-include-files)
    (cond
     ((pair? rewrite-include-files)
      ;; TODO: rewrite with a structural editor to preserve formatting
      (let ((library
             (library-rewrite-includes
              (car (file->sexp-list src-library-file))
              relative-rewrite-include-files)))
        (install-sexp-file cfg library (make-path dir dest-library-file))
        (if (not (equal? library-file dest-library-file))
            (delete-file src-library-file))))
     ((not (equal? library-file dest-library-file))
      (rename-file src-library-file (make-path dir dest-library-file))))
    ;; return the rewritten library
    (library-rewrite-includes
     library
     (append relative-rewrite-include-files
             (if (equal? library-file dest-library-file)
                 '()
                 (list (list library-file dest-library-file)))))))

;; first call the default builder to fix paths, then compile any ffi files
(define (chibi-builder impl cfg library dir)
  (let* ((library (default-builder impl cfg library dir))
         (library-file (make-path dir (get-library-file cfg library)))
         (shared-includes
          (library-shared-include-files impl cfg library-file))
         (local-test? (file-exists? "tools/chibi-ffi"))
         (chibi-ffi
          (if local-test?
              (scheme-program-command impl cfg "tools/chibi-ffi")
              '("chibi-ffi")))
         (cc (string-split (or (conf-get cfg 'cc)
                               (get-environment-variable "CC")
                               "cc")))
         (cflags (string-split (or (get-environment-variable "CFLAGS") ""))))
    (let lp ((ls shared-includes))
      (if (null? ls)
          library
          (let* ((base (car ls))
                 (stub-file (string-append base ".stub"))
                 (c-file (string-append base ".c"))
                 (so-file (string-append base (cond-expand (macosx ".dylib")
                                                           (else ".so"))))
                 (so-flags (cond-expand (macosx '("-dynamiclib" "-Oz"))
                                        (else '("-fPIC" "-shared" "-Os"))))
                 (cc-cmd (append cc cflags so-flags
                                 (if local-test? '("-Iinclude" "-L.") '())
                                 `("-o" ,so-file ,c-file "-lchibi-scheme"))))
            (and (or (file-exists? c-file)
                     (and (file-exists? stub-file)
                          (or (and (system? (append chibi-ffi (list stub-file)))
                                   (file-exists? c-file))
                              (yes-or-no? cfg "couldn't generate c from stub: "
                                          stub-file " - install anyway?")))
                     (yes-or-no? cfg "can't find ffi stub or c source for: "
                                 base " - install anyway?"))
                 (or (system? cc-cmd)
                     (yes-or-no? cfg "couldn't compile chibi ffi c code: "
                                 c-file " - install anyway?"))
                 (lp (cdr ls))))))))

(define (chicken-builder impl cfg library dir)
  (let* ((library-file (make-path dir (get-library-file cfg library)))
         (library-base (string-join (map x->string (library-name library)) "."))
         (module-name (string-join (map x->string (library-name library)) "."))
         (so-path (make-path dir (string-append library-base ".so")))
         (imp-path (string-append library-base ".import.scm")))
    (with-directory
     dir
     (lambda ()
       (let ((res (system 'csc '-R 'r7rs '-X 'r7rs '-s '-J '-o so-path
                          '-I (path-directory library-file) library-file)))
         (and (or (and (pair? res) (zero? (cadr res)))
                  (yes-or-no? cfg "chicken failed to build: "
                              (library-name library-name)
                              " - install anyway?"))
              library))))))

(define (lookup-builder builder)
  (case builder
    ((chibi) chibi-builder)
    ((chicken) chicken-builder)
    (else default-builder)))

(define (builder-for-implementation impl cfg)
  (case impl
    ((chibi chicken) impl)
    (else 'default)))

(define (build-library impl cfg library dir)
  (let ((builder (lookup-builder (or (conf-get cfg 'builder)
                                     (builder-for-implementation impl cfg)))))
    (builder impl cfg library dir)))

;; strip extension, add #! if needed, copy and chmod
(define (default-program-builder impl cfg prog dir)
  (let* ((path (make-path dir (get-program-file cfg prog)))
         (dest (path-strip-extension path))
         (src-lines (call-with-input-file path port->string-list))
         (script (scheme-script-command impl cfg)))
    (if (equal? path dest)
        (system "cp" path (string-append path ".bak")))
    (call-with-output-file dest
      (lambda (out)
        (when script
          (display "#! " out)
          (display script out)
          (newline out)) 
        (for-each
         (lambda (line) (display line out) (newline out))
         (if (and (pair? src-lines) (string-prefix? "#!" (car src-lines)))
             (cdr src-lines)
             src-lines))))
    (chmod dest #o755)
    prog))

(define (chicken-program-builder impl cfg prog dir)
  (let ((path (get-program-file cfg prog)))
    (with-directory
     dir
     (lambda ()
       (let ((res (system 'csc '-R 'r7rs '-X 'r7rs
                          '-I (path-directory path) path)))
         (and (or (and (pair? res) (zero? (cadr res)))
                  (yes-or-no? cfg "chicken failed to build: "
                              path " - install anyway?"))
              prog))))))

(define (lookup-program-builder builder)
  (case builder
    ((chicken) chicken-program-builder)
    (else default-program-builder)))

(define (program-builder-for-implementation impl cfg)
  (case impl
    ((chicken) 'chicken)
    (else 'default)))

(define (build-program impl cfg prog dir)
  (let ((builder (lookup-program-builder
                  (or (conf-get cfg 'program-builder)
                      (program-builder-for-implementation impl cfg)))))
    (builder impl cfg prog dir)))

(define (default-program-installer impl cfg prog dir)
  (let* ((program-file (path-strip-extension (get-program-file cfg prog)))
         (dest-program-file (program-install-name prog))
         (install-dir (get-install-binary-dir impl cfg)))
    (let ((path (make-path install-dir dest-program-file)))
      (install-directory cfg (path-directory path))
      (install-file cfg (make-path dir program-file) path)
      (list path))))

(define (lookup-program-installer installer)
  (case installer
    (else default-program-installer)))

(define (install-program impl cfg prog dir)
  (let ((installer (lookup-program-installer
                    (conf-get cfg 'program-installer))))
    (installer impl cfg prog dir)))

(define (install-data-file impl cfg file dir)
  (let* ((src (if (pair? file) (cadr file) file))
         (dest0 (if (pair? file) (third file) file))
         (install-dir (get-install-data-dir impl cfg))
         (dest (path-resolve dest0 install-dir)))
    (create-directory* (path-directory dest))
    (install-file cfg (make-path dir src) dest)))

(define (fetch-package cfg url)
  (resource->bytevector url))

(define (path-strip-top file)
  (let ((pos (string-find file #\/)))
    (if (string-cursor<? pos (string-cursor-end file))
        (substring-cursor file (string-cursor-next file pos))
        file)))

(define (maybe-invalid-package-reason impl cfg pkg)
  (let ((res (invalid-package-reason pkg)))
    (and res
         (not (yes-or-no? cfg "Package invalid: " res "\nProceed anyway?"))
         res)))

(define (package-maybe-digest-mismatches impl cfg pkg raw)
  (and (not (conf-get cfg 'ignore-digests?))
       (let ((res (package-digest-mismatches cfg pkg raw)))
         (and res
              (not (yes-or-no? cfg "Package checksum mismatches: " res
                               "\nProceed anyway?"))
              res))))

(define (package-maybe-signature-mismatches repo impl cfg pkg raw)
  (cond
   ((conf-get cfg 'ignore-signature?) #f)
   ((not (assq 'signature (cdr pkg)))
    (and (conf-get cfg 'require-signature?)
         (not (yes-or-no? cfg "Package signature missing.\nProceed anyway?"))
         '(package-signature-missing)))
   (else
    (let ((res (package-signature-mismatches repo cfg pkg raw)))
      (and res
           (not (yes-or-no? cfg "Package signature mismatches: " res
                            "\nProceed anyway?"))
           res)))))

;; install from a raw, unzipped snowball as an in-memory bytevector
(define (install-package-from-snowball repo impl cfg pkg snowball)
  (cond
   ((not (tar-safe? snowball))
    (die 2 "package tarball should contain a single relative directory: "
         (tar-files snowball)))
   ((package-maybe-digest-mismatches impl cfg pkg snowball)
    => (lambda (x) (die 2 "package checksum didn't match: " x)))
   ((package-maybe-signature-mismatches repo impl cfg pkg snowball)
    => (lambda (x) (die 2 "package signature didn't match: " x)))
   (else
    (call-with-temp-dir
     "pkg"
     (lambda (dir preserve)
       (tar-extract snowball (lambda (f) (make-path dir (path-strip-top f))))
       (let ((libs (filter-map (lambda (lib) (build-library impl cfg lib dir))
                               (package-libraries pkg))))
         (if (test-package impl cfg pkg dir)
             (let* ((data-files
                     (append-map
                      (lambda (file)
                        (install-data-file impl cfg file dir))
                      (package-data-files pkg)))
                    (lib-files
                     (append-map
                      (lambda (lib)
                        (install-library impl cfg lib dir))
                      libs))
                    (prog-files
                     (if (conf-program-implementation? impl cfg)
                         (append-map
                          (lambda (prog)
                            (build-program impl cfg prog dir)
                            (install-program impl cfg prog dir))
                          (package-programs pkg))
                         '()))
                    (installed-files
                     (append data-files lib-files prog-files)))
               (install-package-meta-info
                impl cfg
                `(,@(remove (lambda (x)
                              (and (pair? x) (eq? 'installed-files (car x))))
                            pkg)
                  (installed-files ,@installed-files))))
             (preserve))))))))

(define (install-package-from-file repo impl cfg file)
  (let ((pkg (package-file-meta file))
        (snowball (maybe-gunzip (file->bytevector file))))
    (install-package-from-snowball repo impl cfg pkg snowball)))

(define (install-package repo impl cfg pkg)
  (cond
   ((maybe-invalid-package-reason impl cfg pkg)
    => (lambda (x) (die 2 "package invalid: " x)))
   ((package-url repo pkg)
    => (lambda (url)
         (let* ((raw (fetch-package cfg url))
                (snowball (maybe-gunzip raw)))
           (install-package-from-snowball repo impl cfg pkg snowball))))
   (else
    (die 2 "package missing url: " (package-name pkg)))))

(define (install-for-implementation repo impl cfg pkgs)
  (for-each
   (lambda (pkg) (install-package repo impl cfg pkg))
   pkgs))

;; --always-yes implies first candidate, --always-no implies none
(define (select-best-candidate impl cfg repo candidates)
  (cond
   ((or (null? (cdr candidates))
        (conf-get cfg 'always-yes?))
    (car candidates))
   ((conf-get cfg 'always-no?)
    #f)
   (else
    (display "Select a package:\n")
    (let lp ((ls candidates) (i 1))
      (if (pair? ls)
          (let ((pkg (car ls)))
            (display "  ") (display i)
            (display "  ") (display (package-name pkg))
            (display " ") (display (package-version pkg))
            (display " (") (display (package-author repo pkg #t))
            (display ")\n")
            (lp (cdr ls) (+ i 1)))))
    (let ((n (input-number cfg 'candidate-number "Candidate number: "
                           1 1 (length candidates))))
      (list-ref candidates (- n 1))))))

;; Choose packages for the corresponding libraries, and recursively
;; select uninstalled packages.
(define (expand-package-dependencies repo impl cfg lib-names)
  (let ((current (installed-libraries impl cfg)))
    (let lp ((ls lib-names) (res '()) (ignored '()))
      (cond
       ((null? ls) res)
       ((find (lambda (pkg) (package-provides? pkg (car ls))) res)
        (lp (cdr ls) res ignored))
       (else
        (let* ((current-version
                (cond ((assoc (car ls) current)
                       => (lambda (x) (package-version (cdr x))))
                      (else #f)))
               (providers
                (filter (lambda (pkg) (package-provides? pkg (car ls)))
                        (cdr repo)))
               (candidates
                (filter
                 (lambda (pkg)
                   (or (not current-version)
                       (version>? (package-version pkg)
                                  current-version)))
                 providers)))
          (cond
           ((member (car ls) ignored)
            (lp (cdr ls) res ignored))
           ((and (null? candidates) (assoc (car ls) current))
            (if (member (car ls) lib-names)
                (warn "skipping already installed library: " (car ls)))
            (lp (cdr ls) res (cons (car ls) ignored)))
           ((and (null? candidates)
                 (not (assoc (car ls) current))
                 (pair? (car ls))
                 (or (equal? (car ls) (list impl))
                     (case impl
                       ((foment gauche)
                        (memq (caar ls) (cons impl '(scheme))))
                       (else (eq? (caar ls) 'scheme)))))
            ;; assume certain core libraries already installed
            ;; (info "assuming core library installed: " (car ls))
            (lp (cdr ls) res (cons (car ls) ignored)))
           ((and (null? candidates) (member (car ls) lib-names))
            (die 2 "Can't find package: " (car ls)))
           ((null? candidates)
            (cond
             ((yes-or-no? cfg "Can't find package: " (car ls)
                          ".  Proceed anyway?")
              (lp (cdr ls) res (cons (car ls) ignored)))
             (else
              (die 2 "No candidates, not installing: " (car ls)))))
           ((select-best-candidate impl cfg repo candidates)
            => (lambda (pkg)
                 (lp (append (package-dependencies impl cfg pkg)
                             (package-test-dependencies impl cfg pkg)
                             (cdr ls))
                     (cons pkg res)
                     ignored)))
           (else
            (warn "no candidate selected")
            (lp (cdr ls) res ignored)))))))))

;; First lookup dependencies for all implementations so we can
;; download in a single batch.  Then perform the installations a
;; single implementation at a time.
(define (command/install cfg spec . args)
  (let*-values
      (((repo) (maybe-update-repository cfg))
       ((impls) (conf-selected-implementations cfg))
       ((impl-cfgs) (map (lambda (impl)
                           (conf-for-implementation cfg impl))
                         impls))
       ((package-files lib-names) (partition package-file? args))
       ((lib-names) (map parse-library-name lib-names))
       ((impl-pkgs)
        (map (lambda (impl cfg)
               (expand-package-dependencies repo impl cfg lib-names))
             impls
             impl-cfgs)))
    (for-each
     (lambda (impl cfg pkgs)
       ;; install by name and dependency
       (install-for-implementation repo impl cfg pkgs)
       ;; install by file
       (for-each
        (lambda (pkg-file)
          (install-package-from-file repo impl cfg pkg-file))
        package-files))
     impls
     impl-cfgs
     impl-pkgs)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Upgrade - upgrade installed packages.

;; With explicit packages same as install, but by default upgrade all
;; available packages.
(define (command/upgrade cfg spec . args)
  (if (pair? args)
      (apply command/install cfg spec args)
      (let* ((repo (maybe-update-repository cfg))
             (impls (conf-selected-implementations cfg))
             (impl-cfgs (map (lambda (impl)
                               (conf-for-implementation cfg impl))
                             impls)))
        (for-each
         (lambda (impl cfg)
           (let ((pkgs (map cdr (installed-libraries impl cfg))))
             (install-for-implementation repo impl cfg pkgs)))
         impls
         impl-cfgs))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Status - show the status of installed libraries.

(define (command/status cfg spec . args)
  (let* ((impls (conf-selected-implementations cfg))
         (impl-cfgs (map (lambda (impl)
                           (conf-for-implementation cfg impl))
                         impls))
         (sexp? (conf-get cfg 'sexp?)))
    (if sexp? (display "("))
    (for-each
     (lambda (impl impl-cfg)
       (if sexp? (display "("))
       (cond
        ((or sexp? (pair? (cdr impls)))
         (if (not (eq? impl (car impls)))
             (display "\n"))
         (display impl)
         (if (not sexp?) (display ":"))
         (display "\n")))
       (summarize-libraries
        impl-cfg
        (if (pair? args)
            (lookup-installed-libraries
             impl impl-cfg (map parse-library-name args))
            (installed-libraries impl impl-cfg)))
       (if sexp? (display ")\n")))
     impls
     impl-cfgs)
    (if sexp? (display ")\n"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Implementations - show the currently available implementations.

(define (command/implementations cfg spec . args)
  (for-each
   (lambda (impl) (write (car impl)) (newline))
   (filter (lambda (x) (impl-available? cfg x #f))
           known-implementations)))
