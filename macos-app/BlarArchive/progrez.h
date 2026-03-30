/* Stub progrez.h for macOS GUI app — the app uses NSProgressIndicator
 * instead of the terminal progress bar library. */
#ifndef PROGREZ_H
#define PROGREZ_H

#include <stdint.h>

typedef struct progrez_ctx progrez_ctx;

static inline progrez_ctx *progrez_create(const char *label) { (void)label; return (void*)0; }
static inline void progrez_destroy(progrez_ctx *ctx) { (void)ctx; }
static inline void progrez_set_identity(progrez_ctx *ctx, const char *a, const char *b) { (void)ctx; (void)a; (void)b; }
static inline void progrez_set_indeterminate(progrez_ctx *ctx) { (void)ctx; }
static inline void progrez_set_determinate(progrez_ctx *ctx, uint64_t a, uint64_t b) { (void)ctx; (void)a; (void)b; }
static inline void progrez_set_guess(progrez_ctx *ctx, uint64_t a, uint64_t b) { (void)ctx; (void)a; (void)b; }
static inline void progrez_update(progrez_ctx *ctx, uint64_t a, uint64_t b) { (void)ctx; (void)a; (void)b; }
static inline void progrez_finish(progrez_ctx *ctx) { (void)ctx; }
static inline void progrez_set_label(progrez_ctx *ctx, const char *l) { (void)ctx; (void)l; }
static inline void progrez_set_sparkline(progrez_ctx *ctx, _Bool e) { (void)ctx; (void)e; }
static inline void progrez_set_notify(progrez_ctx *ctx, _Bool e) { (void)ctx; (void)e; }
static inline void progrez_set_notify_after(progrez_ctx *ctx, uint32_t s) { (void)ctx; (void)s; }
static inline void progrez_set_interval_ms(progrez_ctx *ctx, uint32_t ms) { (void)ctx; (void)ms; }

#endif /* PROGREZ_H */
