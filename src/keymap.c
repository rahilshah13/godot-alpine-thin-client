/*
 * keymap.c - Keycode lookup and mapping stubs
 */
#include <stdint.h>
#include "types.h"

uint32_t keymapmod(uint32_t mod) {
    (void)mod;
    return 0;
}

const struct key_map *keymap_lookup(uint32_t keycode) {
    static struct key_map km;
    km.keycode = keycode & 0x7F;
    km.shift = 0;
    km.ctrl = 0;
    return &km;
}