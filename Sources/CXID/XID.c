#include "CXID.h"

#include <stdatomic.h>

static _Atomic(uint32_t) xid_counter;

void xid_initialize_counter(uint32_t seed) {
    atomic_store_explicit(&xid_counter, seed, memory_order_relaxed);
}

uint32_t xid_next_counter(void) {
    return atomic_fetch_add_explicit(
        &xid_counter,
        1,
        memory_order_relaxed
    ) + 1;
}
