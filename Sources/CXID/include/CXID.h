#ifndef C_XID_H
#define C_XID_H

#include <stdint.h>

void xid_initialize_counter(uint32_t seed);
uint32_t xid_next_counter(void);

#endif
