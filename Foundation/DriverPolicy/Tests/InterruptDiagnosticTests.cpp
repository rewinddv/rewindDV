// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include "ASFWDriver/Diagnostics/DiagnosticLogger.hpp"
#include <cassert>
#include <cstdio>
#include <string>

using ASFW::Driver::DiagnosticLogger;

int main() {
    assert(DiagnosticLogger::DecodeInterruptEvents(0) ==
           "irq=0x00000000; set=[]; unknown=0x00000000");
    // Independent register fact mask: TI SCPS167A Table 4-16. These are event
    // bits, not IntMask bits; reserved/unknown observations must survive intact.
    constexpr uint32_t documented = 0x6fff83ff;
    for (unsigned bit = 0; bit < 32; ++bit) {
        const uint32_t value = uint32_t{1} << bit;
        const auto text = DiagnosticLogger::DecodeInterruptEvents(value);
        char raw[32];
        std::snprintf(raw, sizeof(raw), "irq=0x%08x;", value);
        assert(text.starts_with(raw));
        const bool known = (documented & value) != 0;
        assert((text.find(std::to_string(bit) + ":") != std::string::npos) == known);
        std::snprintf(raw, sizeof(raw), "unknown=0x%08x", known ? 0 : value);
        assert(text.ends_with(raw));
        assert(text == DiagnosticLogger::DecodeInterruptEvents(value));
    }
    assert(DiagnosticLogger::DecodeInterruptEvents(0x80020080) ==
           "irq=0x80020080; set=[7:stream receive context, 17:bus reset entered]; unknown=0x80000000");
    assert(DiagnosticLogger::DecodeInterruptEvents(0x60000001) ==
           "irq=0x60000001; set=[0:request send completion, 29:software-triggered event, 30:vendor-defined event]; unknown=0x00000000");
    const auto all = DiagnosticLogger::DecodeInterruptEvents(0xffffffff);
    assert(all.starts_with("irq=0xffffffff;"));
    assert(all.ends_with("unknown=0x90007c00"));
    assert(all.size() < 1200);
    for (uint32_t value : {0x12345678u, 0x55555555u, 0xaaaaaaaau, 0x90007c00u}) {
        char unknown[32];
        std::snprintf(unknown, sizeof(unknown), "unknown=0x%08x", value & ~documented);
        assert(DiagnosticLogger::DecodeInterruptEvents(value).ends_with(unknown));
    }
    std::puts("Interrupt diagnostics: zero, 32 single bits, mixed masks and deterministic text PASS");
}
