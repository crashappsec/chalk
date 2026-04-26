/**
 * @file macho_endian.h
 * @brief Shared byte-swap helpers for stream and writer.
 */

#pragma once

#include <stdint.h>

static inline uint16_t
macho_swap16(uint16_t v)
{
    return (v >> 8) | (v << 8);
}

static inline uint32_t
macho_swap32(uint32_t v)
{
    return ((v >> 24) & 0x000000FF)
         | ((v >>  8) & 0x0000FF00)
         | ((v <<  8) & 0x00FF0000)
         | ((v << 24) & 0xFF000000);
}

static inline uint64_t
macho_swap64(uint64_t v)
{
    return ((v >> 56) & 0x00000000000000FF)
         | ((v >> 40) & 0x000000000000FF00)
         | ((v >> 24) & 0x0000000000FF0000)
         | ((v >>  8) & 0x00000000FF000000)
         | ((v <<  8) & 0x000000FF00000000)
         | ((v << 24) & 0x0000FF0000000000)
         | ((v << 40) & 0x00FF000000000000)
         | ((v << 56) & 0xFF00000000000000);
}
