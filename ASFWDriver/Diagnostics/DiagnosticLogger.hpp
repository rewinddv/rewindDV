// Modified by Rewind Digital for rewindDV, 2026-09-30: replace diagnostic
// implementation from public register facts; remove unused adapted decoders.
// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <string>

namespace ASFW::Driver {

class DiagnosticLogger {
public:
    // Pure presentation of an event snapshot. Always retains all 32 input bits.
    [[nodiscard]] static std::string DecodeInterruptEvents(uint32_t events);
};

} // namespace ASFW::Driver
