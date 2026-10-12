// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
// Test-only negative control. Never linked into the app or driver.
// The runner requires a sanitizer diagnostic AND a nonzero exit for each mode.
#include <climits>
#include <cstring>
#include "ASFWDriver/Testing/HostDriverKitStubs.hpp"
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    if (std::strcmp(argv[1], "ubsan") == 0) {
        volatile int maximum = INT_MAX;
        volatile int one = 1;
        volatile int overflow = maximum + one;
        (void)overflow;
    } else if (std::strcmp(argv[1], "asan") == 0) {
        volatile int* value = new int(42);
        delete value;
        volatile int useAfterFree = *value;
        (void)useAfterFree;
    } else if (std::strcmp(argv[1], "overrelease") == 0) {
        auto* object = new OSObject;
        object->release();
        object->release(); // ASan must detect this even with NDEBUG.
    } else {
        return 2;
    }
    return 0; // A recovering sanitizer must cause the runner to reject this.
}
