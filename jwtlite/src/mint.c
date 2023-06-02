/* 
** mint.c -- mint and validate Chalk JWT tokens.
**
** We compress what we need to sign into one AES encryption, which
** dramatically reduces our overhead.
**
** There are definitely ways to speed this up more by improving the
** b64/hex code, but that cost is dwarfed by the crypto, etc.
**
** John Viega (john@crashoverride.com)
** Copyright 2023, Crash Override, Inc.
**/

#include <stdio.h>
#include "aes_x86.h"
#include "mint.h"

#ifndef likely
#define likely(x)       __builtin_expect(!!(x), 1)
#define unlikely(x)     __builtin_expect(!!(x), 0)
#endif

/* 
** Note that this code is currently Linux/x86-64 specific.  I may
** extend to ARM, and make work on Apple, but not yet.
**
** The thing keeping this from working on OS X is the use of
** getrandom().  The ASM should be the same.  I'll port it to OS X's
** CCRandomCopyBytes() at some point, probably when doing ARM.
**
**
** In the JWT Payload, we use the following claims:
**
** "sub" -- The user id, which for us is in UID format.
** "aud" -- A byte representing 'entitlements', hex encoded lower case.
**          This is meant for any future access control, etc.
** "jti" -- A 56-bit random number that is a essentially a nonce for the 
**          token minting.
**
** Note thatverything is always a fixed size for us, including the
** payload.
**
** We never work directly with the un-base64'd payload, but if we did,
** it would look like this:
**
** const char JSON_PAYLOAD_TEMPLATE =
** "{\n  \"sub\": \"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\",\n  " \
**     "\"jti\": \"XXXXXXXXXXXXXX\",\n  \"aud\": \"XX\"\n}";
**
** The X's above are the bytes that vary.
**
** Instead of working on the above template, we will encode or decode
** the pieces we need out of the base64 directly.
**
** B64 encoding turns 3 bytes into 4 bytes, so every 4th byte in the
** template is a boundary.  We can therefore encode / decode that
** overlap the X's by 1 or 2 bytes, if necessary.
**
** Luckily, the UID is properly aligned and is the right size, so we
** don't have to do that.  We can directly encode it and plop it in
** the right place.
**
** The JTI field starts at index 61 of the DECODED payload, so the
** 3-byte boundary start is the preceeding quote, which we will need
** to enode.  But, being 14 characters, it ends on a boundary.
**
** Similarly, the entitlements byte is hex encoded into a 2-byte
** value, and that value ends on a b64 boundary, but the start is the
** quote in front of it.
*/

void
init_minting(uint8_t *key, schedule_t *ctx) {
    aes128_init((uint8_t *)key, ctx);
}

/* Here, we extract 64 bits out of the non-dash characters of the UID
** into a single uint64_t. That constitutes half of the non-dash bits,
** or 16 of the actual bytes.
** 
** The UIDs we're extracting from are just random bits, but if there
w** were structure here, we'd want to be more selective. As is, we just
** jump to offset 19, where we only have one dash to deal with (The
** format is 8-4-4-4-12).
**
** We expect hex to be lower-cased. And, importantly, we do NOT check
** the length of the string.  Any wrapper API should do that checking.
*/

#define LOAD_NIBBLE()							       \
c =*p++;                                                                       \
if (c >= '0' && c <='9') { c = c - '0';  }                                     \
else {                                                                         \
  if (likely(c >= 'a' && c <= 'f')) { c = c - ('a' - 0xa); }                   \
  else { return false; }			                               \
}

static inline bool
mint_uid_to_bits(uint8_t *p, uint8_t *outloc) {
    uint64_t result = 0;
    uint8_t     c;

    p += UID_START_OFFSET;

    LOAD_NIBBLE(); result = c << 4;
    LOAD_NIBBLE(); *outloc++ = result | c;
    LOAD_NIBBLE(); result = c << 4;
    LOAD_NIBBLE(); *outloc++ = result | c;
    p++; // Skip the dash.
    LOAD_NIBBLE(); result = c << 4;
    LOAD_NIBBLE(); *outloc++ = result | c;
    LOAD_NIBBLE(); result = c << 4;
    LOAD_NIBBLE(); *outloc++ = result | c;
    LOAD_NIBBLE(); result = c << 4;
    LOAD_NIBBLE(); *outloc++ = result | c;
    LOAD_NIBBLE(); result = c << 4;
    LOAD_NIBBLE(); *outloc++ = result | c;
    LOAD_NIBBLE(); result = c << 4;
    LOAD_NIBBLE(); *outloc++ = result | c;
    LOAD_NIBBLE(); result = c << 4;
    LOAD_NIBBLE(); *outloc++ = result | c;

    return true;
}

static inline bool
byte_from_hex(uint8_t *p, uint8_t *outloc) {
   
   uint8_t c, result;
   
   LOAD_NIBBLE(); result  = c << 4;
   LOAD_NIBBLE(); result |= c;

   *outloc = result;

   return true;
}

const uint8_t hex_map[16] = {
    '0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'
};

static inline void
hex_encode_entitlement(uint8_t *p, uint8_t c) {
    *p++ = '"';
    *p++ = hex_map[c >> 4];
    *p++ = hex_map[c & 0x0f];
}

static inline void
hex_encode_jti(uint8_t *outp, uint8_t *inp) {
    *outp++ = '"';
    *outp++ = hex_map[inp[1] >> 4];
    *outp++ = hex_map[inp[1] & 0x0f];
    *outp++ = hex_map[inp[2] >> 4];
    *outp++ = hex_map[inp[2] & 0x0f];
    *outp++ = hex_map[inp[3] >> 4];
    *outp++ = hex_map[inp[3] & 0x0f];
    *outp++ = hex_map[inp[4] >> 4];
    *outp++ = hex_map[inp[4] & 0x0f];
    *outp++ = hex_map[inp[5] >> 4];
    *outp++ = hex_map[inp[5] & 0x0f];
    *outp++ = hex_map[inp[6] >> 4];
    *outp++ = hex_map[inp[6] & 0x0f];
    *outp++ = hex_map[inp[7] >> 4];
    *outp++ = hex_map[inp[7] & 0x0f];
}

static inline void
hex_encode_sig(uint8_t *outp, uint8_t *inp) {
    int i;
  
    for (i = 0; i < 16; i++) {
      *outp++ = hex_map[inp[i] >> 4];
      *outp++ = hex_map[inp[i] & 0x0f];
    }
}

static inline bool
hex_decode_sig(uint8_t *p, uint8_t *outp) {
    uint8_t c, cur;
    int i;
    for (i = 0; i < 32; i++) {
      LOAD_NIBBLE();
      cur = c << 4;
      LOAD_NIBBLE();
      *outp++ = cur | c;
    }
    *outp = 0;

    return true;
}

const uint8_t b64_map[64] = {
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
    'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd',
    'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's',
    't', 'u', 'v', 'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', '+', '/'
};

#define B64_ENC1()                                                             \
    x       = *inp++;                                                          \
    y       = *inp++;                                                          \
    z       = *inp++;                                                          \
    *outp++ = b64_map[x >> 2];                                                 \
    *outp++ = b64_map[((x & 0x03) << 4) | (y >> 4)];                           \
    *outp++ = b64_map[((y & 0x0f) << 2) | (z >> 6)];                           \
    *outp++ = b64_map[z & 0x3f];

/* Note that this decode implementation does NOT look for invalid
** bytes.  If they're invalid, the sig validation won't work anyway,
** unless they had the key and replaced 'A' bytes with non-64
** characters, in which case, so what and who cares, as they'd started
** with the actual token.
*/


const int rev_map[256] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3e, 0x00, 0x00, 0x00, 0x3f,
    0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
    0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12,
    0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24,
    0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
    0x31, 0x32, 0x33, /* auto-zero. */
};

#define B64_DEC1()                                                             \
    a      = rev_map[*inp++] << 2;                                             \
    b      = rev_map[*inp++];                                                  \
    c      = rev_map[*inp++];                                                  \
    d      = rev_map[*inp++];                                                  \
    *outp++ = a | (b >> 4);                                                    \
    *outp++ = (b << 4) | (c >> 2);                                             \
    *outp++ = (c << 6) | d;


static inline void
template_store_entitlement(uint8_t *outp, uint8_t *inp) {
    uint8_t x, y, z;
    
    outp += B64_AUD_VAL_OFFSET;
    B64_ENC1();
}

static inline void
template_store_jti(uint8_t *outp, uint8_t *inp) {
    uint8_t x, y, z;
    
    outp += B64_JTI_VAL_OFFSET;
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
}

static inline void
template_fill_jti_and_ent(uint8_t *outbuf, uint8_t *blockptr) {
    uint8_t hex_encoded_ent[4] = {0,};
    uint8_t hex_encoded_jti[JSON_JTI_LEN + 2]; // +1 for the leading quote.

    hex_encode_jti(hex_encoded_jti, blockptr);
    template_store_jti(outbuf, hex_encoded_jti);
    
    hex_encode_entitlement(hex_encoded_ent, blockptr[0]);
    template_store_entitlement(outbuf, hex_encoded_ent);
}

static inline void
template_fill_uid(uint8_t *outp, uint8_t *inp) {
    uint8_t x, y, z;
    
    outp += B64_UID_VAL_OFFSET;
    
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
}

static inline void
template_fill_signature(uint8_t *outp, uint8_t *rawsig) {
    uint8_t x, y, z;
    uint8_t hex_encoded_sig[B64_SIG_LEN + 1] = {0,};  // Need 1 pad byte.
    uint8_t *inp = hex_encoded_sig;

    hex_encode_sig(hex_encoded_sig, rawsig);

    outp += B64_SIG_OFFSET;

    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();
    B64_ENC1();    
    *outp = 0;
}

static inline void
token_to_uid(uint8_t *inp, uint8_t *outp) {
    uint8_t a, b, c, d;
    
    inp += B64_UID_VAL_OFFSET;
    
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
}

static inline void
token_extract_sig(uint8_t *inp, uint8_t *outp) {
    uint8_t a, b, c, d;

    inp += B64_SIG_OFFSET;

    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
}

static inline void
token_extract_rand_and_ent(uint8_t *token, uint8_t *blockptr) {
    uint8_t *inp, *outp;
    uint8_t extracted_ent[3];
    uint8_t extracted_jti[JSON_JTI_LEN + 1] = {0,}; // +1 for the leading "
    uint8_t a, b, c, d;

    inp  = token + B64_AUD_VAL_OFFSET;
    outp = extracted_ent;

    B64_DEC1();

    inp  = token + B64_JTI_VAL_OFFSET;
    outp = extracted_jti;

    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();
    B64_DEC1();

    byte_from_hex(extracted_ent + 1, blockptr++);
    byte_from_hex(extracted_jti + 1, blockptr++);
    byte_from_hex(extracted_jti + 3, blockptr++);
    byte_from_hex(extracted_jti + 5, blockptr++);
    byte_from_hex(extracted_jti + 7, blockptr++);
    byte_from_hex(extracted_jti + 9, blockptr++);
    byte_from_hex(extracted_jti + 11, blockptr++);
    byte_from_hex(extracted_jti + 13, blockptr++);
}

/* 
** Note that just because I'm in the habit of trying to maintain
** alignment, we go ahead and request 64 bytes from getrandom(), but
** then write the entitlement information over the first byte of that.
**
** Note that this call does NOT malloc() a token. To avoid lots of
** unneeded memory management overhead, any wrapper should try to keep
** one and only one token buffer per thread.
**
** Also, you're responsible for ensuring the uid and outbuf fields
** are the right size.
*/

const uint8_t *template = (uint8_t *)"ewogICJhbGciOiAiQ0hBTEtBUEkiLAogICJ0eXAiOiAiSldUIgp9.ewogICJzdWIiOiAiWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYIiwKICAianRpIjogIlhYWFhYWFhYWFhYWFhYIiwKICAiYXVkIjogIlhYIgp9.";

#if 0
void
print_hex64(uint8_t *label, uint8_t *s) {
  int i;
  
  printf("%s:\t", label);
  for(i = 0; i < 8; i++) {
    printf("%02x", (uint8_t)s[i]);
  }
  printf("\n");
}
#endif

void
jwt_mint(schedule_t *ctx, uint8_t *uid, uint8_t ent, uint8_t* outbuf) {
    
    uint8_t block[16];
    uint8_t ct[16];

    memcpy(outbuf, template, strlen((char *)template));

    mint_uid_to_bits(uid, block);
    getrandom(block + 8, sizeof(uint64_t), 0);
    block[8] = ent;

    aes128_encrypt(ctx, block, ct);
    
    template_fill_jti_and_ent(outbuf, (uint8_t *)(block + 8));
    template_fill_uid(outbuf, uid);          
    template_fill_signature(outbuf, (uint8_t *)ct);
    outbuf[TOKEN_LEN] = 0;
}

bool
jwt_validate(schedule_t *ctx, uint8_t *token) {
    uint8_t     uid[JSON_UID_LEN];
    uint8_t  block[16];
    // base32 decode gives us an extra byte at the end.    
    uint8_t     hex_extracted_sig[33];
    uint8_t     real_extracted_sig[16];
    uint8_t  calculated_sig[16];

    token_to_uid(token, uid);
    mint_uid_to_bits(uid, block);                 
    token_extract_rand_and_ent(token, (uint8_t *)&block[8]);
    token_extract_sig(token, hex_extracted_sig);
    hex_decode_sig(hex_extracted_sig, real_extracted_sig);
    aes128_encrypt(ctx, (uint8_t *)block, calculated_sig);

    return (bool)(!memcmp(real_extracted_sig, calculated_sig, 16));
}

// Tests.

void
test_b64(void) {
    uint8_t *enc =
        (uint8_t *)"ewogICJhbGciOiAiQ0hBTEtBUEkiLAogICJ0eXAiOiAiSldUIgp9";
    uint8_t *dec
        = (uint8_t *)"{\n  \"alg\": \"CHALKAPI\",\n  \"typ\": \"JWT\"\n}";
    uint8_t x, y, z;
    uint8_t outbuf [1024] = {0,};
    uint8_t outbuf2[1024] = {0,};
    uint8_t *inp = dec;
    uint8_t *outp = (uint8_t *)outbuf;

    while (outp < (outbuf + strlen((char *)enc))) {
        B64_ENC1();
    }

    *outp = 0;
    
    printf("KAT: %s\nGOT: %s\n", enc, outbuf);

    uint8_t a, b, c, d;
    outp = (uint8_t *)outbuf2;
    inp =  enc;

    while (outp < (outbuf2 + strlen((char *)dec))) {
        B64_DEC1();
    }

    *outp = 0;

    printf("KAT: %s\nGOT: %s\n", dec, outbuf2);    
}
