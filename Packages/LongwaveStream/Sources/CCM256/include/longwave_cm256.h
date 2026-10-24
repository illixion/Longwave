/*
 * The part of cm256's API that StreamFEC calls, as plain C.
 *
 * Upstream's cm256.h includes gf256.h, which includes <cstring>, so Swift
 * (which imports C modules in C mode) can't import it. This header repeats the
 * two structs and three functions verbatim, with identical layout, and the
 * vendored cm256.cpp defines them. Keep it in step with cm256.h when updating
 * (README.md).
 */
#ifndef LONGWAVE_CM256_H
#define LONGWAVE_CM256_H

#ifdef __cplusplus
extern "C" {
#endif

/* Must equal cm256.h's CM256_VERSION; cm256_init_ rejects any other value. */
#define CM256_VERSION 2

typedef struct cm256_encoder_params_t {
    int OriginalCount;   /* data blocks, < 256                               */
    int RecoveryCount;   /* parity blocks, < 256, OriginalCount + this <= 256 */
    int BlockBytes;      /* bytes per block, all blocks the same size        */
} cm256_encoder_params;

typedef struct cm256_block_t {
    void* Block;
    /* Data blocks: 0..OriginalCount-1. Parity: OriginalCount + its index. */
    unsigned char Index;
} cm256_block;

/* 0 on success. Builds the GF(256) tables; call once (StreamFEC does). */
extern int cm256_init_(int version);

/* Writes RecoveryCount * BlockBytes parity bytes end to end. 0 on success. */
extern int cm256_encode(cm256_encoder_params params, cm256_block* originals, void* recoveryBlocks);

/* `blocks` holds OriginalCount entries. Parity blocks are rebuilt in place and
 * relabelled with the data index they now hold. 0 on success. */
extern int cm256_decode(cm256_encoder_params params, cm256_block* blocks);

#ifdef __cplusplus
}
#endif

#endif
