;; TrustFlow: Reputation-Based Lending Protocol
;; A decentralized lending protocol based on on-chain reputation

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))
(define-constant ERR-LOW-REPUTATION (err u103))
(define-constant ERR-LOAN-EXISTS (err u104))
(define-constant MINIMUM-REPUTATION-SCORE u500) ;; Out of 1000
(define-constant REPUTATION-PENALTY u100)
(define-constant MAX-LOAN-AMOUNT u1000000) ;; In microSTX

;; Data Maps
(define-map user-reputation 
    principal 
    {
        score: uint,
        loans-repaid: uint,
        governance-participation: uint,
        staking-history: uint
    }
)

(define-map active-loans
    principal
    {
        amount: uint,
        due-height: uint,
        repaid: bool
    }
)

(define-map user-balances principal uint)

;; Initialize or update user reputation
(define-public (initialize-reputation (user principal))
    (let ((existing-record (get-reputation user)))
        (if (is-none existing-record)
            (ok (map-set user-reputation user {
                score: u500,  ;; Starting score
                loans-repaid: u0,
                governance-participation: u0,
                staking-history: u0
            }))
            ERR-NOT-AUTHORIZED
        )
    )
)

;; Calculate reputation score based on various factors
(define-private (calculate-reputation-score 
    (loans-repaid uint) 
    (governance-participation uint)
    (staking-history uint))
    (let ((base-score (* loans-repaid u100))
          (governance-bonus (* governance-participation u50))
          (staking-bonus (* staking-history u50)))
        (+ (+ base-score governance-bonus) staking-bonus)
    )
)

;; Update user's reputation components
(define-public (update-reputation-components
    (user principal)
    (governance-points uint)
    (staking-points uint))
    (let ((current-reputation (unwrap! (get-reputation user) ERR-NOT-AUTHORIZED)))
        (ok (map-set user-reputation user
            {
                score: (calculate-reputation-score 
                    (get loans-repaid current-reputation)
                    (+ (get governance-participation current-reputation) governance-points)
                    (+ (get staking-history current-reputation) staking-points)
                ),
                loans-repaid: (get loans-repaid current-reputation),
                governance-participation: (+ (get governance-participation current-reputation) governance-points),
                staking-history: (+ (get staking-history current-reputation) staking-points)
            }
        ))
    )
)

;; Request a loan
(define-public (request-loan (amount uint))
    (let (
        (sender tx-sender)
        (reputation (unwrap! (get-reputation sender) ERR-NOT-AUTHORIZED))
        (current-loan (get-active-loan sender))
    )
        (asserts! (<= amount MAX-LOAN-AMOUNT) ERR-INVALID-AMOUNT)
        (asserts! (>= (get score reputation) MINIMUM-REPUTATION-SCORE) ERR-LOW-REPUTATION)
        (asserts! (is-none current-loan) ERR-LOAN-EXISTS)
        
        (map-set active-loans sender {
            amount: amount,
            due-height: (+ block-height u1440), ;; ~10 days with 10min blocks
            repaid: false
        })
        
        (ok (as-contract (stx-transfer? amount (as-contract tx-sender) sender)))
    )
)

;; Repay loan
(define-public (repay-loan)
    (let (
        (sender tx-sender)
        (loan (unwrap! (get-active-loan sender) ERR-NOT-AUTHORIZED))
        (reputation (unwrap! (get-reputation sender) ERR-NOT-AUTHORIZED))
    )
        (asserts! (not (get repaid loan)) ERR-NOT-AUTHORIZED)
        (try! (stx-transfer? (get amount loan) sender (as-contract tx-sender)))
        
        (map-set active-loans sender {
            amount: (get amount loan),
            due-height: (get due-height loan),
            repaid: true
        })
        
        (ok (map-set user-reputation sender {
            score: (+ (get score reputation) u50),
            loans-repaid: (+ (get loans-repaid reputation) u1),
            governance-participation: (get governance-participation reputation),
            staking-history: (get staking-history reputation)
        }))
    )
)

;; Check if loan is defaulted and penalize if necessary
(define-public (check-loan-status (user principal))
    (let (
        (loan (unwrap! (get-active-loan user) ERR-NOT-AUTHORIZED))
        (reputation (unwrap! (get-reputation user) ERR-NOT-AUTHORIZED))
    )
        (if (and 
            (> block-height (get due-height loan))
            (not (get repaid loan))
        )
            (ok (map-set user-reputation user {
                score: (- (get score reputation) REPUTATION-PENALTY),
                loans-repaid: (get loans-repaid reputation),
                governance-participation: (get governance-participation reputation),
                staking-history: (get staking-history reputation)
            }))
            (ok true)
        )
    )
)

;; Getter functions
(define-read-only (get-reputation (user principal))
    (map-get? user-reputation user)
)

(define-read-only (get-active-loan (user principal))
    (map-get? active-loans user)
)

(define-read-only (get-balance (user principal))
    (default-to u0 (map-get? user-balances user))
)