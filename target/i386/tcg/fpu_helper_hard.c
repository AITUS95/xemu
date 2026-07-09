#include "qemu/osdep.h"

#if defined(XBOX) && (defined(__x86_64__) || defined(_M_X64)) && \
    defined(CONFIG_XEMU_HARD_FPU)
#define USE_HARD_FPU 1
#include "fpu_helper.c"
#endif
