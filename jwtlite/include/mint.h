/*
** The offsets below mark the start of where we need to drop our b64
** on top of the template.  This will always be:
**
** `ix * (4/3)`
**
** The first const is the base-64 encoded template for what we return.
** Groupings of 3 Xs get encoded to `WFhY`, and `"XX` gets encoded to
** `IlhY`.
**
** Note that the first line is the encoded HEADER, which, when decoded, is:
** `{\n  "alg": "CHALKAPI",\n  "typ": "JWT"\n}`
**
** Instead of separating out the bytes we hardcode the b64-encoded length
** of the header plus the dot after it as B64_PAYLOAD_OFFSET.
 */
#ifndef __MINT_H__
#define __MINT_H__

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <sys/random.h>

// None of these constants are meant to be configurable. They're just
// there to make the code easier to understand.

#define TEMPLATE_LEN       178 // the b64, not the json
// The unencoded signature 16 bytes, and we null-pad to 18 for b64
// chunking.
#define B64_SIG_LEN        44
#define JSON_UID_LEN       36
#define JSON_JTI_LEN       14
#define B64_PAYLOAD_OFFSET 53
#define B64_SIG_OFFSET     TEMPLATE_LEN
#define B64_UID_VAL_OFFSET (B64_PAYLOAD_OFFSET + 16)
#define B64_JTI_VAL_OFFSET (B64_PAYLOAD_OFFSET + 80)
#define B64_AUD_VAL_OFFSET (B64_PAYLOAD_OFFSET + 116)

// When we extract 64 bits from the UID, what byte do we start
// reading at?
#define UID_START_OFFSET   19


// Count the null in the length here.
#define TOKEN_LEN          (TEMPLATE_LEN + B64_SIG_LEN + 1)

void init_minting(uint8_t *, schedule_t *);
void jwt_mint(schedule_t *, uint8_t *, uint8_t, uint8_t *);
bool jwt_validate(schedule_t *, uint8_t *, uint8_t[JSON_UID_LEN]);

#endif
