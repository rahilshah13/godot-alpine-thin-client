#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "types.h"

#define CLIPBOARD_MAX_SIZE (1024 * 1024)  /* 1MB max clipboard */

/* ─────────────────────────────────────────────────────────────────────────────
 * Public API
 * ───────────────────────────────────────────────────────────────────────────── */

int clipboard_init(struct server *s) {
    (void)s;
    return 0;
}

void clipboard_cleanup(struct server *s) {
    (void)s;
}