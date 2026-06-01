#ifndef EJS_REFCOUNT_H
#define EJS_REFCOUNT_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    _Atomic(uint32_t) value;
} EJSRefCount;

static inline void ejs_refcount_init(EJSRefCount *ref_count, uint32_t initial_value) {
    atomic_init(&ref_count->value, initial_value);
}

static inline bool ejs_refcount_try_retain(EJSRefCount *ref_count) {
    uint32_t current = atomic_load_explicit(&ref_count->value, memory_order_acquire);
    while (current != 0u) {
        if (atomic_compare_exchange_weak_explicit(&ref_count->value,
                                                  &current,
                                                  current + 1u,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
            return true;
        }
    }
    return false;
}

static inline void ejs_refcount_retain(EJSRefCount *ref_count) {
    (void)atomic_fetch_add_explicit(&ref_count->value, 1u, memory_order_relaxed);
}

static inline bool ejs_refcount_release(EJSRefCount *ref_count) {
    return atomic_fetch_sub_explicit(&ref_count->value, 1u, memory_order_acq_rel) == 1u;
}

#endif /* EJS_REFCOUNT_H */
