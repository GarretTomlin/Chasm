#pragma once
/* Chasm runtime — minimal arena allocator C header */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    uint8_t *base;
    size_t   used;
    size_t   cap;
} ChasmArena;

typedef struct {
    ChasmArena frame;
    ChasmArena script;
    ChasmArena persistent;
} ChasmCtx;

static inline void *chasm_alloc(ChasmArena *a, size_t n, size_t align) {
    size_t adj = (align - (a->used & (align - 1))) & (align - 1);
    if (a->used + adj + n > a->cap) return NULL;
    a->used += adj;
    void *p = a->base + a->used;
    a->used += n;
    return p;
}

static inline void chasm_clear_frame(ChasmCtx *ctx) {
    ctx->frame.used = 0;
}

/* Promote a scalar value to a longer-lived arena (primitive: no-op copy). */
#define chasm_promote_scalar(val) (val)
