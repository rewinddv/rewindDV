// Copyright 2026 Rewind Digital, LLC
// SPDX-License-Identifier: Apache-2.0

#include "../../../ASFWDriver/Shared/SharedDataModels.hpp"
#include "../FoundationDriverPolicy.hpp"

#include <array>
#include <cassert>
#include <cstdint>
#include <cstddef>
#include <cstring>

int main() {
    using ASFW::Shared::AVCSubunitInfoWire;
    using ASFW::Shared::AVCUnitInfoWire;

    static_assert(sizeof(AVCUnitInfoWire) == 24);
    static_assert(sizeof(AVCSubunitInfoWire) == 4);

    using RewindDV::Foundation::DriverPolicy::DeckControlRequestWire;
    using RewindDV::Foundation::DriverPolicy::DeckControlResultWire;
    using RewindDV::Foundation::DriverPolicy::DeckResponseEventWire;
    static_assert(sizeof(DeckControlRequestWire) == 72);
    static_assert(offsetof(DeckControlRequestWire, driverInstanceID) == 40);
    static_assert(offsetof(DeckControlRequestWire, deviceIncarnation) == 48);
    static_assert(offsetof(DeckControlRequestWire, routeEpoch) == 56);
    static_assert(offsetof(DeckControlRequestWire, generation) == 64);
    static_assert(offsetof(DeckControlRequestWire, nodeID) == 68);
    using RewindDV::Foundation::DriverPolicy::FoundationRouteWire;
    static_assert(sizeof(FoundationRouteWire) == 48);
    static_assert(offsetof(FoundationRouteWire, driverInstanceID) == 16);
    static_assert(offsetof(FoundationRouteWire, deviceIncarnation) == 24);
    static_assert(offsetof(FoundationRouteWire, routeEpoch) == 32);
    static_assert(offsetof(FoundationRouteWire, generation) == 40);
    static_assert(offsetof(FoundationRouteWire, nodeID) == 44);
    static_assert(sizeof(DeckResponseEventWire) == 544);
    static_assert(sizeof(DeckControlResultWire) == 2324);
    static_assert(offsetof(DeckControlResultWire, routeState) == 64);
    static_assert(offsetof(DeckControlResultWire, fcpAttemptID) == 80);
    static_assert(offsetof(DeckControlResultWire, generation) == 112);
    static_assert(offsetof(DeckControlResultWire, nodeID) == 116);
    static_assert(offsetof(DeckControlResultWire, request) == 144);
    static_assert(offsetof(DeckControlResultWire, responseEvents) == 148);
    static_assert(offsetof(DeckResponseEventWire, classification) == 24);
    static_assert(offsetof(DeckResponseEventWire, bytes) == 32);

    using RewindDV::Foundation::DriverPolicy::InspectorCapabilitiesWire;
    using RewindDV::Foundation::DriverPolicy::InspectorDecodedWire;
    using RewindDV::Foundation::DriverPolicy::InspectorRequestWire;
    using RewindDV::Foundation::DriverPolicy::InspectorResultWire;
    static_assert(sizeof(InspectorCapabilitiesWire) == 40);
    static_assert(sizeof(InspectorRequestWire) == 72);
    static_assert(offsetof(InspectorRequestWire, operationID) == 8);
    static_assert(offsetof(InspectorRequestWire, guid) == 24);
    static_assert(offsetof(InspectorRequestWire, generation) == 56);
    static_assert(offsetof(InspectorRequestWire, nodeID) == 60);
    static_assert(offsetof(InspectorRequestWire, query) == 62);
    static_assert(offsetof(InspectorRequestWire, subunitPage) == 63);
    static_assert(offsetof(InspectorRequestWire, reserved) == 64);
    static_assert(sizeof(InspectorDecodedWire) == 32);
    static_assert(offsetof(InspectorDecodedWire, unitType) == 4);
    static_assert(offsetof(InspectorDecodedWire, subunits) == 10);
    static_assert(offsetof(InspectorDecodedWire, serialBusIsochronousInputPlugs) == 18);
    static_assert(sizeof(InspectorResultWire) == 1284);
    static_assert(offsetof(InspectorResultWire, generation) == 112);
    static_assert(offsetof(InspectorResultWire, query) == 116);
    static_assert(offsetof(InspectorResultWire, nodeID) == 148);
    static_assert(offsetof(InspectorResultWire, routeState) == 152);
    static_assert(offsetof(InspectorResultWire, decoded) == 156);
    static_assert(offsetof(InspectorResultWire, request) == 188);
    static_assert(offsetof(InspectorResultWire, responseEvents) == 196);

    using RewindDV::Foundation::DriverPolicy::TransportCapabilityCatalogEntryWire;
    using RewindDV::Foundation::DriverPolicy::TransportCapabilityCatalogWire;
    using RewindDV::Foundation::DriverPolicy::TransportCapabilityProbeRequestWire;
    using RewindDV::Foundation::DriverPolicy::TransportCapabilityResultWire;
    static_assert(sizeof(TransportCapabilityCatalogEntryWire) == 24);
    static_assert(offsetof(TransportCapabilityCatalogEntryWire, inquiry) == 16);
    static_assert(offsetof(TransportCapabilityCatalogEntryWire, control) == 20);
    static_assert(sizeof(TransportCapabilityCatalogWire) == 176);
    static_assert(offsetof(TransportCapabilityCatalogWire, entries) == 32);
    static_assert(sizeof(TransportCapabilityProbeRequestWire) == 72);
    static_assert(offsetof(TransportCapabilityProbeRequestWire, operationID) == 8);
    static_assert(offsetof(TransportCapabilityProbeRequestWire, guid) == 24);
    static_assert(offsetof(TransportCapabilityProbeRequestWire, generation) == 56);
    static_assert(offsetof(TransportCapabilityProbeRequestWire, nodeID) == 60);
    static_assert(offsetof(TransportCapabilityProbeRequestWire, command) == 64);
    static_assert(sizeof(TransportCapabilityResultWire) == 1264);
    static_assert(offsetof(TransportCapabilityResultWire, generation) == 112);
    static_assert(offsetof(TransportCapabilityResultWire, command) == 116);
    static_assert(offsetof(TransportCapabilityResultWire, nodeID) == 148);
    static_assert(offsetof(TransportCapabilityResultWire, routeState) == 152);
    static_assert(offsetof(TransportCapabilityResultWire, supportState) == 156);
    static_assert(offsetof(TransportCapabilityResultWire, controlAuthorization) == 160);
    static_assert(offsetof(TransportCapabilityResultWire, request) == 168);
    static_assert(offsetof(TransportCapabilityResultWire, responseEvents) == 176);

    AVCUnitInfoWire unit{};
    unit.guid = 0x0123456789ABCDEFULL;
    unit.nodeID = 0xFFC1;
    unit.vendorID = 0x00A0B0C0;
    unit.modelID = 0x10203040;
    unit.subunitCount = 1;

    std::array<uint8_t, sizeof(unit)> bytes{};
    std::memcpy(bytes.data(), &unit, sizeof(unit));

    // The existing same-host Swift parser reads the GUID at offset zero in
    // little-endian order. This fixture proves that all 64 bits are exported;
    // there is no source-backed truncation defect to patch in this slice.
    constexpr std::array<uint8_t, 8> guidBytes{
        0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
    };
    for (size_t i = 0; i < guidBytes.size(); ++i) {
        assert(bytes[i] == guidBytes[i]);
    }

    uint64_t parsedGuid = 0;
    for (size_t i = 0; i < guidBytes.size(); ++i) {
        parsedGuid |= static_cast<uint64_t>(bytes[i]) << (i * 8);
    }
    assert(parsedGuid == unit.guid);
    assert(bytes[8] == 0xC1);
    assert(bytes[9] == 0xFF);
    assert(bytes[18] == 1);
    return 0;
}
