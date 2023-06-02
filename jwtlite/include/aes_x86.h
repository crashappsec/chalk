#ifndef __AES_NI_H__
#define __AES_NI_H__

// The AES is is all based off reference code, using the compiler
// intrinsics for the raw instructions.

#include <stdint.h>
#include <string.h>
#include <wmmintrin.h>

typedef struct {
    __m128i round_keys[20];
} schedule_t;

static __m128i
aes128_expand_inner(__m128i key, __m128i round_mask) {
    round_mask = _mm_shuffle_epi32(round_mask, _MM_SHUFFLE(3,3,3,3));
    key        = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key        = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    key        = _mm_xor_si128(key, _mm_slli_si128(key, 4));
    
    return _mm_xor_si128(key, round_mask);
}

#define aes128_expand(key, round_constant) \
    aes128_expand_inner(key, _mm_aeskeygenassist_si128(key, round_constant))


static void
aes128_init(uint8_t *enc_key, schedule_t *schedptr) {
    __m128i *key_schedule = (__m128i *)schedptr;
    
    key_schedule[0] = _mm_loadu_si128((const __m128i*) enc_key);
    key_schedule[1]  = aes128_expand(key_schedule[0], 0x01);
    key_schedule[2]  = aes128_expand(key_schedule[1], 0x02);
    key_schedule[3]  = aes128_expand(key_schedule[2], 0x04);
    key_schedule[4]  = aes128_expand(key_schedule[3], 0x08);
    key_schedule[5]  = aes128_expand(key_schedule[4], 0x10);
    key_schedule[6]  = aes128_expand(key_schedule[5], 0x20);
    key_schedule[7]  = aes128_expand(key_schedule[6], 0x40);
    key_schedule[8]  = aes128_expand(key_schedule[7], 0x80);
    key_schedule[9]  = aes128_expand(key_schedule[8], 0x1B);
    key_schedule[10] = aes128_expand(key_schedule[9], 0x36);
}

static void
aes128_encrypt(schedule_t *schedule, uint8_t *in, uint8_t *out) {
    __m128i* ks = (__m128i*)schedule;
    __m128i state;

    uint64_t *n = (uint64_t *)in;
    uint64_t a, b;

    a = n[0];
    b = n[1];
    
    state = _mm_loadu_si128((__m128i *) in);
    state = _mm_xor_si128       (state, ks[0]);     
    state = _mm_aesenc_si128    (state, ks[1]);
    state = _mm_aesenc_si128    (state, ks[2]);
    state = _mm_aesenc_si128    (state, ks[3]);
    state = _mm_aesenc_si128    (state, ks[4]);
    state = _mm_aesenc_si128    (state, ks[5]);
    state = _mm_aesenc_si128    (state, ks[6]);
    state = _mm_aesenc_si128    (state, ks[7]);
    state = _mm_aesenc_si128    (state, ks[8]);
    state = _mm_aesenc_si128    (state, ks[9]);
    state = _mm_aesenclast_si128(state, ks[10]);

    _mm_storeu_si128((__m128i *) out, state);

    n = (uint64_t *)out;
    a = n[0];
    b = n[1];
}

#endif
