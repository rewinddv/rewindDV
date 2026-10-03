// Modified by Rewind Digital for rewindDV, 2026-09-30: independently authored
// interrupt presentation from public register facts, replacing prior decoders.
// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#include "DiagnosticLogger.hpp"

#include <cstdio>

namespace ASFW::Driver {
namespace {

// MANUFACTURER_REFERENCE: TI TSB82AA2-EP SCPS167A (September 2006),
// section 4.21, Table 4-16. Numeric event coordinates only; descriptions and
// output format are project-authored. Bit 31 belongs to mask control, not events.
// https://www.ti.com/lit/ds/symlink/tsb82aa2-ep.pdf
const char* DescribeBit(unsigned bit) {
    switch (bit) {
        case 0: return "request send completion";
        case 1: return "response send completion";
        case 2: return "request receive descriptor";
        case 3: return "response receive descriptor";
        case 4: return "request packet buffered";
        case 5: return "response packet buffered";
        case 6: return "stream transmit context";
        case 7: return "stream receive context";
        case 8: return "acknowledged write failed in host memory";
        case 9: return "lock reply lacked completion acknowledgment";
        case 15: return "self-identification retained completion";
        case 16: return "self-identification completion";
        case 17: return "bus reset entered";
        case 18: return "register access lacked PHY clock";
        case 19: return "PHY status interrupt";
        case 20: return "cycle counter transition";
        case 21: return "seconds counter bit-six transition";
        case 22: return "cycle start absent or predicted absent";
        case 23: return "received cycle time differs";
        case 24: return "controller operation halted by error";
        case 25: return "cycle interval overrun";
        case 26: return "PHY register byte available";
        case 27: return "tardy acknowledgment condition";
        case 29: return "software-triggered event";
        case 30: return "vendor-defined event";
        default: return nullptr;
    }
}

} // namespace

std::string DiagnosticLogger::DecodeInterruptEvents(uint32_t events) {
    char number[48];
    std::snprintf(number, sizeof(number), "irq=0x%08x; set=[", events);
    std::string result(number);
    uint32_t unknown = events;
    bool separator = false;
    for (unsigned bit = 0; bit < 32; ++bit) {
        const uint32_t mask = uint32_t{1} << bit;
        if ((events & mask) == 0) continue;
        const char* description = DescribeBit(bit);
        if (description == nullptr) continue;
        unknown &= ~mask;
        if (separator) result += ", ";
        std::snprintf(number, sizeof(number), "%u:", bit);
        result += number;
        result += description;
        separator = true;
    }
    std::snprintf(number, sizeof(number), "]; unknown=0x%08x", unknown);
    result += number;
    return result;
}

} // namespace ASFW::Driver
