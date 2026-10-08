// Compile with the real DriverKit SDK, whose shared_ptr counts are non-atomic.
#include "ASFWDriver/Common/AtomicSharedOwner.hpp"
#include <__config>
#if _LIBCPP_HAS_THREADS
#error "This regression must compile against DriverKit's threadless libc++ configuration"
#endif
struct Context { unsigned value; };
using Owner = ASFW::Common::AtomicSharedOwner<Context>;
extern "C" __attribute__((noinline)) void retainOwner(Owner* destination, const Owner* source) {
    *destination = *source;
}
extern "C" __attribute__((noinline)) void releaseOwner(Owner* owner) { owner->reset(); }
