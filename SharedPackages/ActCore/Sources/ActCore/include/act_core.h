/*
 * act_core.h — C FFI header for the Anonymous Credit Tokens core library.
 *
 * This header is consumed by Swift (via bridging), Kotlin (via JNI), and
 * C# (via P/Invoke) to call the ACT protocol operations implemented in Rust.
 *
 * All CBOR buffers use the wire format specified in draft-schlesinger-cfrg-act.
 * Memory management: callers must free returned pointers using the
 * corresponding act_*_free functions.
 */

#ifndef ACT_CORE_H
#define ACT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque types */
typedef struct Params ActParams;
typedef struct PrivateKey ActPrivateKey;
typedef struct PublicKey ActPublicKey;
typedef struct PreIssuance ActPreIssuance;
typedef struct CreditToken ActCreditToken;
typedef struct PreRefund ActPreRefund;

/* Heap-allocated byte buffer. Caller must free with act_buffer_free. */
typedef struct {
    uint8_t *data;
    size_t len;
} ActBuffer;

/* Result of a spend operation. */
typedef struct {
    ActBuffer spend_proof_cbor;    /* CBOR SpendProof — free with act_buffer_free */
    ActPreRefund *pre_refund;      /* Opaque — free with act_pre_refund_free */
} ActSpendResult;

/* --- Memory management --- */
void act_buffer_free(ActBuffer buf);
void act_params_free(ActParams *ptr);
void act_private_key_free(ActPrivateKey *ptr);
void act_public_key_free(ActPublicKey *ptr);
void act_pre_issuance_free(ActPreIssuance *ptr);
void act_credit_token_free(ActCreditToken *ptr);
void act_pre_refund_free(ActPreRefund *ptr);

/* --- Params --- */
ActParams *act_params_new(
    const char *organization,
    const char *service,
    const char *deployment_id,
    const char *version
);

/* --- Key management --- */
ActPrivateKey *act_private_key_new(void);
ActPublicKey *act_public_key_from_private(const ActPrivateKey *sk);
ActBuffer act_public_key_to_cbor(const ActPublicKey *pk);
ActPublicKey *act_public_key_from_cbor(const uint8_t *data, size_t len);

/* --- Client: Issuance --- */
ActPreIssuance *act_pre_issuance_new(void);
ActBuffer act_issuance_request(const ActPreIssuance *pre, const ActParams *params);
ActCreditToken *act_complete_issuance(
    const ActPreIssuance *pre,
    const ActParams *params,
    const ActPublicKey *pk,
    const uint8_t *request_cbor, size_t request_len,
    const uint8_t *response_cbor, size_t response_len
);

/* --- Server: Issuance --- */
ActBuffer act_issue(
    const ActPrivateKey *sk,
    const ActParams *params,
    const uint8_t *request_cbor, size_t request_len,
    uint64_t credits
);

/* --- Client: Spending --- */
ActSpendResult act_spend(
    const ActCreditToken *token,
    const ActParams *params,
    uint64_t charge
);

/* --- Server: Spending --- */
ActBuffer act_refund(
    const ActPrivateKey *sk,
    const ActParams *params,
    const uint8_t *spend_proof_cbor, size_t spend_proof_len
);
ActBuffer act_spend_proof_nullifier(
    const uint8_t *spend_proof_cbor, size_t spend_proof_len
);

/* --- Client: Refund completion --- */
ActCreditToken *act_complete_refund(
    const ActPreRefund *pre_refund,
    const ActParams *params,
    const uint8_t *spend_proof_cbor, size_t spend_proof_len,
    const uint8_t *refund_cbor, size_t refund_len,
    const ActPublicKey *pk
);

/* --- CreditToken serialization --- */
ActBuffer act_credit_token_to_cbor(const ActCreditToken *token);
ActCreditToken *act_credit_token_from_cbor(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* ACT_CORE_H */
