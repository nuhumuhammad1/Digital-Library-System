;; Digital Rights Management Contract
;; Protects copyrighted content access

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-CONTENT-NOT-FOUND (err u401))
(define-constant ERR-LICENSE-EXPIRED (err u402))
(define-constant ERR-ACCESS-DENIED (err u403))
(define-constant ERR-INVALID-INPUT (err u404))
(define-constant ERR-INSUFFICIENT-BALANCE (err u405))

;; Access Tier Constants
(define-constant TIER-BASIC u1)
(define-constant TIER-PREMIUM u2)
(define-constant TIER-INSTITUTIONAL u3)

;; Data Variables
(define-data-var next-content-id uint u1)
(define-data-var next-license-id uint u1)
(define-data-var basic-tier-price uint u1000000) ;; 1 STX
(define-data-var premium-tier-price uint u5000000) ;; 5 STX
(define-data-var institutional-tier-price uint u20000000) ;; 20 STX

;; Data Maps
(define-map digital-content
  { content-id: uint }
  {
    title: (string-ascii 100),
    creator: (string-ascii 50),
    content-hash: (string-ascii 64),
    copyright-holder: principal,
    required-tier: uint,
    is-active: bool,
    created-at: uint,
    usage-count: uint
  }
)

(define-map user-licenses
  { license-id: uint }
  {
    user: principal,
    tier: uint,
    expires-at: uint,
    is-active: bool,
    purchased-at: uint,
    usage-limit: uint,
    usage-count: uint
  }
)

(define-map user-current-license
  { user: principal }
  { license-id: uint }
)

(define-map content-access-log
  { content-id: uint, user: principal, accessed-at: uint }
  { license-id: uint }
)

(define-map subscription-renewals
  { user: principal }
  {
    auto-renew: bool,
    renewal-tier: uint
  }
)

;; Private Functions
(define-private (get-current-time)
  block-height
)

(define-private (get-tier-price (tier uint))
  (if (is-eq tier TIER-BASIC)
    (var-get basic-tier-price)
    (if (is-eq tier TIER-PREMIUM)
      (var-get premium-tier-price)
      (if (is-eq tier TIER-INSTITUTIONAL)
        (var-get institutional-tier-price)
        u0
      )
    )
  )
)

(define-private (get-tier-duration (tier uint))
  (if (is-eq tier TIER-BASIC)
    u4320 ;; ~30 days in blocks
    (if (is-eq tier TIER-PREMIUM)
      u12960 ;; ~90 days in blocks
      (if (is-eq tier TIER-INSTITUTIONAL)
        u52560 ;; ~365 days in blocks
        u0
      )
    )
  )
)

(define-private (get-tier-usage-limit (tier uint))
  (if (is-eq tier TIER-BASIC)
    u10
    (if (is-eq tier TIER-PREMIUM)
      u100
      (if (is-eq tier TIER-INSTITUTIONAL)
        u1000
        u0
      )
    )
  )
)

(define-private (has-valid-license (user principal) (required-tier uint))
  (match (map-get? user-current-license { user: user })
    current-license-data
    (match (map-get? user-licenses { license-id: (get license-id current-license-data) })
      license
      (and
        (get is-active license)
        (> (get expires-at license) (get-current-time))
        (>= (get tier license) required-tier)
        (< (get usage-count license) (get usage-limit license))
      )
      false
    )
    false
  )
)

;; Public Functions

;; Register digital content
(define-public (register-content
  (title (string-ascii 100))
  (creator (string-ascii 50))
  (content-hash (string-ascii 64))
  (required-tier uint))
  (let ((content-id (var-get next-content-id)))
    (asserts! (> (len title) u0) ERR-INVALID-INPUT)
    (asserts! (> (len creator) u0) ERR-INVALID-INPUT)
    (asserts! (> (len content-hash) u0) ERR-INVALID-INPUT)
    (asserts! (and (>= required-tier TIER-BASIC) (<= required-tier TIER-INSTITUTIONAL)) ERR-INVALID-INPUT)

    (map-set digital-content
      { content-id: content-id }
      {
        title: title,
        creator: creator,
        content-hash: content-hash,
        copyright-holder: tx-sender,
        required-tier: required-tier,
        is-active: true,
        created-at: (get-current-time),
        usage-count: u0
      }
    )

    (var-set next-content-id (+ content-id u1))
    (ok content-id)
  )
)

;; Purchase license
(define-public (purchase-license (tier uint))
  (let (
    (price (get-tier-price tier))
    (duration (get-tier-duration tier))
    (usage-limit (get-tier-usage-limit tier))
    (license-id (var-get next-license-id))
    (expires-at (+ (get-current-time) duration))
  )
    (asserts! (and (>= tier TIER-BASIC) (<= tier TIER-INSTITUTIONAL)) ERR-INVALID-INPUT)
    (asserts! (>= (stx-get-balance tx-sender) price) ERR-INSUFFICIENT-BALANCE)

    ;; Transfer payment to contract
    (try! (stx-transfer? price tx-sender (as-contract tx-sender)))

    ;; Deactivate existing license if any
    (match (map-get? user-current-license { user: tx-sender })
      current-license-data
      (let ((current-license (unwrap-panic (map-get? user-licenses { license-id: (get license-id current-license-data) }))))
        (map-set user-licenses
          { license-id: (get license-id current-license-data) }
          (merge current-license { is-active: false })
        )
      )
      true
    )

    ;; Create new license
    (map-set user-licenses
      { license-id: license-id }
      {
        user: tx-sender,
        tier: tier,
        expires-at: expires-at,
        is-active: true,
        purchased-at: (get-current-time),
        usage-limit: usage-limit,
        usage-count: u0
      }
    )

    ;; Update current license mapping
    (map-set user-current-license
      { user: tx-sender }
      { license-id: license-id }
    )

    (var-set next-license-id (+ license-id u1))
    (ok license-id)
  )
)

;; Access digital content
(define-public (access-content (content-id uint))
  (let (
    (content (unwrap! (map-get? digital-content { content-id: content-id }) ERR-CONTENT-NOT-FOUND))
    (required-tier (get required-tier content))
    (current-time (get-current-time))
  )
    (asserts! (get is-active content) ERR-ACCESS-DENIED)
    (asserts! (has-valid-license tx-sender required-tier) ERR-ACCESS-DENIED)

    ;; Get current license
    (let (
      (current-license-data (unwrap-panic (map-get? user-current-license { user: tx-sender })))
      (license-id (get license-id current-license-data))
      (license (unwrap-panic (map-get? user-licenses { license-id: license-id })))
    )
      ;; Update usage counts
      (map-set user-licenses
        { license-id: license-id }
        (merge license { usage-count: (+ (get usage-count license) u1) })
      )

      (map-set digital-content
        { content-id: content-id }
        (merge content { usage-count: (+ (get usage-count content) u1) })
      )

      ;; Log access
      (map-set content-access-log
        { content-id: content-id, user: tx-sender, accessed-at: current-time }
        { license-id: license-id }
      )

      (ok true)
    )
  )
)

;; Set auto-renewal
(define-public (set-auto-renewal (auto-renew bool) (renewal-tier uint))
  (begin
    (asserts! (and (>= renewal-tier TIER-BASIC) (<= renewal-tier TIER-INSTITUTIONAL)) ERR-INVALID-INPUT)

    (map-set subscription-renewals
      { user: tx-sender }
      {
        auto-renew: auto-renew,
        renewal-tier: renewal-tier
      }
    )

    (ok true)
  )
)

;; Process auto-renewal (can be called by anyone)
(define-public (process-auto-renewal (user principal))
  (let (
    (renewal-settings (map-get? subscription-renewals { user: user }))
    (current-license-data (map-get? user-current-license { user: user }))
  )
    (match renewal-settings
      settings
      (if (get auto-renew settings)
        (match current-license-data
          license-data
          (let (
            (license (unwrap! (map-get? user-licenses { license-id: (get license-id license-data) }) ERR-INVALID-INPUT))
            (renewal-tier (get renewal-tier settings))
            (price (get-tier-price renewal-tier))
          )
            (if (and
              (get is-active license)
              (<= (get expires-at license) (+ (get-current-time) u144)) ;; Within 1 day of expiry
              (>= (stx-get-balance user) price)
            )
              ;; Process renewal by calling purchase-license as the user would
              (ok false) ;; Placeholder - in real implementation, would need user authorization
              (ok false)
            )
          )
          (ok false)
        )
        (ok false)
      )
      (ok false)
    )
  )
)

;; Update content status (copyright holder only)
(define-public (update-content-status (content-id uint) (is-active bool))
  (let ((content (unwrap! (map-get? digital-content { content-id: content-id }) ERR-CONTENT-NOT-FOUND)))
    (asserts! (is-eq tx-sender (get copyright-holder content)) ERR-NOT-AUTHORIZED)

    (map-set digital-content
      { content-id: content-id }
      (merge content { is-active: is-active })
    )

    (ok true)
  )
)

;; Update tier prices (admin only)
(define-public (set-tier-price (tier uint) (new-price uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> new-price u0) ERR-INVALID-INPUT)

    (if (is-eq tier TIER-BASIC)
      (var-set basic-tier-price new-price)
      (if (is-eq tier TIER-PREMIUM)
        (var-set premium-tier-price new-price)
        (if (is-eq tier TIER-INSTITUTIONAL)
          (var-set institutional-tier-price new-price)
          false
        )
      )
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get content details
(define-read-only (get-content (content-id uint))
  (map-get? digital-content { content-id: content-id })
)

;; Get user's current license
(define-read-only (get-user-license (user principal))
  (match (map-get? user-current-license { user: user })
    license-data (map-get? user-licenses { license-id: (get license-id license-data) })
    none
  )
)

;; Check if user can access content
(define-read-only (can-access-content (user principal) (content-id uint))
  (match (map-get? digital-content { content-id: content-id })
    content
    (and
      (get is-active content)
      (has-valid-license user (get required-tier content))
    )
    false
  )
)

;; Get tier pricing
(define-read-only (get-tier-pricing)
  {
    basic: (var-get basic-tier-price),
    premium: (var-get premium-tier-price),
    institutional: (var-get institutional-tier-price)
  }
)

;; Get user's auto-renewal settings
(define-read-only (get-auto-renewal-settings (user principal))
  (map-get? subscription-renewals { user: user })
)

;; Get access log entry
(define-read-only (get-access-log (content-id uint) (user principal) (accessed-at uint))
  (map-get? content-access-log { content-id: content-id, user: user, accessed-at: accessed-at })
)

;; Withdraw revenue (admin only)
(define-public (withdraw-revenue (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (>= (stx-get-balance (as-contract tx-sender)) amount) ERR-INSUFFICIENT-BALANCE)
    (try! (as-contract (stx-transfer? amount tx-sender recipient)))
    (ok true)
  )
)
