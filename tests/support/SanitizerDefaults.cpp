// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 ASFireWire Project
// RewindDV adaptation of ASFireWire PR #128. Test binaries only.
// Keep findings fatal even when the runner supplies no sanitizer environment.
extern "C" const char* __asan_default_options() {
    return "abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1";
}
extern "C" const char* __ubsan_default_options() {
    return "halt_on_error=1:print_stacktrace=1";
}
