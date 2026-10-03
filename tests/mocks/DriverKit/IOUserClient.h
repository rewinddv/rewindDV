// Modified by Rewind Digital for rewindDV, 2026-09-30: first-party host-test
// argument storage. This record is not a replica of the SDK ABI or class.
// Copyright 2026 Rewind Digital, LLC. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstdint>
#include <DriverKit/IOReturn.h>
class IOMemoryDescriptor;
class OSData;

// Public interface flag consumed by the driver's memory policy.
inline constexpr uint64_t kIOUserClientMemoryReadOnly = 1;

// Only fields accessed by the compiled host-test handlers. Deliberately grouped
// by storage kind, with value initialization; native builds use the installed SDK.
struct IOUserClientMethodArguments {
    uint32_t scalarInputCount = 0;
    uint32_t scalarOutputCount = 0;
    uint64_t* scalarInput = nullptr;
    uint64_t* scalarOutput = nullptr;
    void* structureInput = nullptr;
    OSData* structureOutput = nullptr;
    IOMemoryDescriptor* structureInputDescriptor = nullptr;
    IOMemoryDescriptor* structureOutputDescriptor = nullptr;
};
