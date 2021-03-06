#lang racket
(require redex)

; import surface language
(require "../../../src/redex/core/wa-surface.rkt")
; import full language
(require "../../../src/redex/core/wa-full.rkt")
; import optimizations
(require "../../../src/redex/optimizations/wa-optimized.rkt")

(displayln "Test for litmus-wa/test04:")

(define p
    (term
  (evalg
   (seq
    (mdef "r2" () (mcall r1))
    (seq (mdef "i" () (seq (evalg (mdef "r1" () 2)) (mcall r2))) (mcall i)))))
)

(test-equal (term (run-to-r ,p)) (term err-no-method))

(test-results)