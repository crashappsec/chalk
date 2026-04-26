/**
 * @file macho_common.h
 * @brief Foundational type definitions shared across the chalk macho
 *        codec.  Self-contained — no n00b headers required.
 */
#pragma once

#include <stdint.h>
#include <stdbool.h>

/// Domain-specific error codes.  Negative to avoid collision with
/// errno.  Used as the `err` payload of n00b_result_carrier_t.
typedef enum {
    MACHO_OK                = 0,
    MACHO_ERR_READ          = -100,
    MACHO_ERR_NOT_FOUND     = -101,
    MACHO_ERR_CORRUPTED     = -102,
    MACHO_ERR_PARSE         = -103,
    MACHO_ERR_NOT_SUPPORTED = -105,
    MACHO_ERR_OUT_OF_BOUNDS = -106,
} macho_error_t;

/// Forward declaration of the stream type — defined in macho_stream.h.
typedef struct macho_stream  macho_stream_t;
