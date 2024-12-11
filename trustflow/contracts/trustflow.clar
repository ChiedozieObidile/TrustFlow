;; TrustFlow: Reputation-Based Lending Protocol
;; A decentralized lending protocol based on on-chain reputation with DAO governance

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))
(define-constant ERR-LOW-REPUTATION (err u103))
(define-constant ERR-LOAN-EXISTS (err u104))
(define-constant ERR-INVALID-PROPOSAL (err u105))
(define-constant ERR-PROPOSAL-EXISTS (err u106))
(define-constant ERR-VOTING-ENDED (err u107))
(define-constant ERR-ALREADY-VOTED (err u108))

(define-constant MINIMUM-REPUTATION-SCORE u500) ;; Out of 1000
(define-constant REPUTATION-PENALTY u100)
(define-constant MAX-LOAN-AMOUNT u1000000) ;; In microSTX
(define-constant PROPOSAL-DURATION u1440) ;; ~10 days with 10min blocks
(define-constant MINIMUM-VOTES-REQUIRED u10)
(define-constant DAO-THRESHOLD u700) ;; Minimum score to participate in DAO

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

;; DAO Governance Maps
(define-map appeal-proposals
    uint
    {
        proposer: principal,
        target-user: principal,
        requested-score: uint,
        reason: (string-ascii 256),
        votes-for: uint,
        votes-against: uint,
        end-height: uint,
        executed: bool
    }
)

(define-map proposal-votes
    {proposal-id: uint, voter: principal}
    bool
)

(define-data-var proposal-nonce uint u0)

;; DAO Functions

;; Create an appeal proposal
(define-public (create-appeal-proposal 
    (target-user principal)
    (requested-score uint)
    (reason (string-ascii 256)))
    (let (
        (sender tx-sender)
        (proposal-id (var-get proposal-nonce))
        (proposer-reputation (unwrap! (get-reputation sender) ERR-NOT-AUTHORIZED))
    )
        ;; Check if proposer has sufficient reputation
        (asserts! (>= (get score proposer-reputation) DAO-THRESHOLD) ERR-NOT-AUTHORIZED)
        
        ;; Create proposal
        (map-set appeal-proposals proposal-id {
            proposer: sender,
            target-user: target-user,
            requested-score: requested-score,
            reason: reason,
            votes-for: u0,
            votes-against: u0,
            end-height: (+ block-height PROPOSAL-DURATION),
            executed: false
        })
        
        ;; Increment nonce
        (var-set proposal-nonce (+ proposal-id u1))
        (ok proposal-id)
    )
)

;; Vote on an appeal proposal
(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
    (let (
        (sender tx-sender)
        (proposal (unwrap! (map-get? appeal-proposals proposal-id) ERR-INVALID-PROPOSAL))
        (voter-reputation (unwrap! (get-reputation sender) ERR-NOT-AUTHORIZED))
        (updated-proposal (merge proposal {
            votes-for: (if vote-for (+ (get votes-for proposal) u1) (get votes-for proposal)),
            votes-against: (if vote-for (get votes-against proposal) (+ (get votes-against proposal) u1))
        }))
    )
        ;; Check voting requirements
        (asserts! (>= (get score voter-reputation) DAO-THRESHOLD) ERR-NOT-AUTHORIZED)
        (asserts! (< block-height (get end-height proposal)) ERR-VOTING-ENDED)
        (asserts! (is-none (map-get? proposal-votes {proposal-id: proposal-id, voter: sender})) ERR-ALREADY-VOTED)
        
        ;; Record vote
        (map-set proposal-votes {proposal-id: proposal-id, voter: sender} vote-for)
        
        ;; Update vote counts
        (map-set appeal-proposals proposal-id updated-proposal)
        
        ;; Update governance participation
        (try! (update-reputation-components sender u1 u0))
        (ok true)
    )
)

;; Execute proposal if passed
(define-public (execute-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? appeal-proposals proposal-id) ERR-INVALID-PROPOSAL))
        (total-votes (+ (get votes-for proposal) (get votes-against proposal)))
    )
        ;; Check execution requirements
        (asserts! (>= block-height (get end-height proposal)) ERR-NOT-AUTHORIZED)
        (asserts! (not (get executed proposal)) ERR-NOT-AUTHORIZED)
        (asserts! (>= total-votes MINIMUM-VOTES-REQUIRED) ERR-NOT-AUTHORIZED)
        
        ;; Check if proposal passed (simple majority)
        (if (> (get votes-for proposal) (get votes-against proposal))
            (begin
                ;; Update target user's reputation
                (try! (set-reputation (get target-user proposal) (get requested-score proposal)))
                ;; Mark proposal as executed
                (map-set appeal-proposals proposal-id
                    (merge proposal {executed: true})
                )
                (ok true)
            )
            (ok false)
        )
    )
)

;; Private function to set reputation directly (only called by execute-proposal)
(define-private (set-reputation (user principal) (new-score uint))
    (let ((current-reputation (unwrap! (get-reputation user) ERR-NOT-AUTHORIZED)))
        (ok (map-set user-reputation user
            (merge current-reputation {score: new-score})
        ))
    )
)

;; Original Lending Functions

(define-public (initialize-reputation (user principal))
    (let ((existing-record (get-reputation user)))
        (if (is-none existing-record)
            (ok (map-set user-reputation user {
                score: u500,
                loans-repaid: u0,
                governance-participation: u0,
                staking-history: u0
            }))
            ERR-NOT-AUTHORIZED
        )
    )
)

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
            due-height: (+ block-height u1440),
            repaid: false
        })
        
        (ok (as-contract (stx-transfer? amount (as-contract tx-sender) sender)))
    )
)

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

;; Getter Functions

(define-read-only (get-reputation (user principal))
    (map-get? user-reputation user)
)

(define-read-only (get-active-loan (user principal))
    (map-get? active-loans user)
)

(define-read-only (get-balance (user principal))
    (default-to u0 (map-get? user-balances user))
)

(define-read-only (get-proposal (proposal-id uint))
    (map-get? appeal-proposals proposal-id)
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
    (map-get? proposal-votes {proposal-id: proposal-id, voter: voter})
)