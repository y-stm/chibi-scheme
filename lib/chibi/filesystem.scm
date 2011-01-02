;; filesystem.scm -- additional filesystem utilities
;; Copyright (c) 2009 Alex Shinn.  All rights reserved.
;; BSD-style license: http://synthcode.com/license.txt

(define (directory-fold dir kons knil)
  (let ((dir (opendir dir)))
    (let lp ((res knil))
      (let ((file (readdir dir)))
        (if file (lp (kons (dirent-name file) res)) res)))))

(define (directory-files dir)
  (directory-fold dir cons '()))

(define (renumber-file-descriptor old new)
  (and (duplicate-file-descriptor-to old new)
       (close-file-descriptor old)))

(define (file-status file)
  (if (string? file) (stat file) (fstat file)))

(define (file-device x) (stat-dev (if (stat? x) x (file-status x))))
(define (file-inode x) (stat-ino (if (stat? x) x (file-status x))))
(define (file-mode x) (stat-mode (if (stat? x) x (file-status x))))
(define (file-num-links x) (stat-nlinks (if (stat? x) x (file-status x))))
(define (file-owner x) (stat-uid (if (stat? x) x (file-status x))))
(define (file-group x) (stat-gid (if (stat? x) x (file-status x))))
(define (file-represented-device x) (stat-rdev (if (stat? x) x (file-status x))))
(define (file-size x) (stat-size (if (stat? x) x (file-status x))))
(define (file-block-size x) (stat-blksize (if (stat? x) x (file-status x))))
(define (file-num-blocks x) (stat-blocks (if (stat? x) x (file-status x))))
(define (file-access-time x) (stat-atime (if (stat? x) x (file-status x))))
(define (file-modification-time x) (stat-mtime (if (stat? x) x (file-status x))))
(define (file-change-time x) (stat-ctime (if (stat? x) x (file-status x))))

(define (file-regular? x) (S_ISREG (file-mode x)))
(define (file-directory? x) (S_ISDIR (file-mode x)))
(define (file-character? x) (S_ISCHR (file-mode x)))
(define (file-block? x) (S_ISBLK (file-mode x)))
(define (file-fifo? x) (S_ISFIFO (file-mode x)))
(define (file-link? x) (S_ISLNK (file-mode x)))
(define (file-socket? x) (S_ISSOCK (file-mode x)))

(define (file-exists? x) (and (file-status x) #t))