
(define (make-rtd name fields . o)
  (let ((parent (and (pair? o) (car o))))
    (register-simple-type name (vector->list fields) parent)))

(define (rtd? x)
  (type? x))

(define (rtd-constructor rtd . o)
  (let ((fields (vector->list (if (pair? o) (car o) (rtd-all-field-names))))
        (make (make-constructor (type-name rtd) rtd)))
    (lambda args
      (let ((res (make)))
        (let lp ((a args) (p fields))
          (cond
           ((null? a) (if (null? p) res (error "not enough args" p)))
           ((null? p) (error "too many args" a))
           (else
            (slot-set! res rtd (car p) (car a))
            (lp (cdr a) (cdr p)))))))))

(define (rtd-predicate rtd)
  (make-type-predicate (type-name rtd) rtd))

(define (field-index-of ls field)
  (let lp ((i 0) (ls ls))
    (cond ((null? ls ) #f)
          ((if (pair? (car ls))
               (eq? field (cadar ls))
               (eq? field (car ls)))
           i)
          (else (lp (+ i 1) (cdr ls))))))

(define (rtd-field-offset rtd field)
  (let ((p (type-parent rtd)))
    (or (and (type? p)
             (rtd-field-offset p field))
        (let ((i (field-index-of (type-slots rtd) field)))
          (and i
               (if (type? p)
                   (+ i (vector-length (rtd-all-field-names p)))
                   i))))))

(define (rtd-accessor rtd field)
  (make-getter rtd (type-name rtd) (rtd-field-offset rtd field)))

(define (rtd-mutator rtd field)
  (if (rtd-field-mutable? rtd field)
      (make-setter rtd (type-name rtd) (rtd-field-offset rtd field))
      (error "can't make mutator for immutable field" rtd field)))
