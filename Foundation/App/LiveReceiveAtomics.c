#include "LiveReceiveAtomics.h"
#include <stdatomic.h>
uint64_t RDLiveLoadAcquireU64(const uint64_t *address) {
  return atomic_load_explicit((const _Atomic uint64_t *)address, memory_order_acquire);
}
