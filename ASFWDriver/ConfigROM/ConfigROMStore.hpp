// Modified for RewindDV: reset-scoped, ownership-safe live Config-ROM export authority.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "../Discovery/DiscoveryTypes.hpp"

struct IOLock;

namespace ASFW::Discovery {

/**
 * Opaque authority issued only after ROMScanner has accepted a scan.
 *
 * The software reset epoch is independent from the finite IEEE 1394 wire
 * generation, so a late completion cannot regain live-export authority after
 * generation wrap. Callers must return the value unchanged to
 * PublishExportScan().
 */
struct ConfigROMExportAdmission {
    uint64_t resetEpoch{0};
    uint64_t scanSerial{0};
    Generation generation{0};
    std::vector<uint8_t> targetNodes;
};

/**
 * @class ConfigROMStore
 * @brief Generation-aware Config ROM cache with lookup/state management.
 *
 * Stores parsed IEEE 1212 / 1394 Configuration ROM objects, deduplicating them by
 * GUID (Extended Unique Identifier, EUI-64) and indexing them by generation and node ID.
 * Implements state management for tracking devices across bus resets, mirroring
 * Apple IOFireWireROMCache patterns.
 */
class ConfigROMStore {
  public:
    ConfigROMStore();
    ~ConfigROMStore();

    ConfigROMStore(const ConfigROMStore&) = delete;
    ConfigROMStore& operator=(const ConfigROMStore&) = delete;
    ConfigROMStore(ConfigROMStore&&) = delete;
    ConfigROMStore& operator=(ConfigROMStore&&) = delete;

    /**
     * @brief Inserts a parsed ROM into the store.
     *
     * Deduplicates by GUID (EUI-64) within the given generation.
     * @param rom The ConfigROM object to insert.
     */
    void Insert(const ConfigROM& rom);

    /**
     * @brief Starts live-export authority for an already accepted scan.
     *
     * This must be called by ROMScanner's accepted-admission callback, never
     * before its busy check. An empty target list denotes a full scan.
     */
    [[nodiscard]] std::optional<ConfigROMExportAdmission>
    BeginExportScan(Generation gen, const std::vector<uint8_t>& targetNodes);

    /**
     * @brief Atomically publishes the accepted results of one scan for export.
     *
     * Historical indexes are updated only when the admission still matches the
     * current software reset epoch and active scan. Full scans replace the live
     * export set; targeted scans replace only their requested nodes.
     */
    [[nodiscard]] bool PublishExportScan(const ConfigROMExportAdmission& admission,
                                         Generation completedGeneration,
                                         const std::vector<ConfigROM>& roms);

    /**
     * @brief Returns an owned copy of the currently export-authorized ROM.
     */
    [[nodiscard]] std::optional<ConfigROM>
    CopyExportableByNode(Generation gen, uint8_t nodeId) const;

    /**
     * @brief Returns an owned historical copy under the store lock.
     */
    [[nodiscard]] std::optional<ConfigROM>
    CopyByNode(Generation gen, uint8_t nodeId, bool allowSuspended) const;

    /**
     * @brief Looks up a Config ROM by generation and node ID.
     *
     * Returns the most recent ROM for that node in the specified generation.
     *
     * @param gen The IEEE 1394 bus generation.
     * @param nodeId The target node ID.
     * @return Pointer to the ConfigROM, or nullptr if not found.
     */
    const ConfigROM* FindByNode(Generation gen, uint8_t nodeId) const;

    /**
     * @brief Enhanced lookup by generation and node ID, with state filtering.
     *
     * @param gen The IEEE 1394 bus generation.
     * @param nodeId The target node ID.
     * @param allowSuspended If false, ignores ROMs in the Suspended state.
     * @return Pointer to the ConfigROM, or nullptr if not found/filtered out.
     */
    const ConfigROM* FindByNode(Generation gen, uint8_t nodeId, bool allowSuspended) const;

    /**
     * @brief Looks up the most recently cached ROM for a node across any generation.
     *
     * @param nodeId The target node ID.
     * @return Pointer to the ConfigROM, or nullptr if not found.
     */
    const ConfigROM* FindLatestForNode(uint8_t nodeId) const;

    /**
     * @brief Looks up a Config ROM by its 64-bit GUID.
     *
     * Returns the most recent ROM across all generations for this EUI-64.
     *
     * @param guid The 64-bit GUID (EUI-64).
     * @return Pointer to the ConfigROM, or nullptr if not found.
     */
    const ConfigROM* FindByGuid(Guid64 guid) const;

    /**
     * @brief Exports an immutable snapshot of all ROMs for a given generation.
     *
     * @param gen The target bus generation.
     * @return A vector of all active ConfigROMs in that generation.
     */
    std::vector<ConfigROM> Snapshot(Generation gen) const;

    /**
     * @brief Exports a snapshot of ROMs filtered by generation and state.
     *
     * @param gen The target bus generation.
     * @param state The required ROMState.
     * @return A vector of filtered ConfigROMs.
     */
    std::vector<ConfigROM> SnapshotByState(Generation gen, ROMState state) const;

    /**
     * @brief Clears all stored ROMs (e.g., on driver stop).
     */
    void Clear();

    // ========================================================================
    // State Management (Apple IOFireWireROMCache-inspired)
    // ========================================================================

    /**
     * @brief Marks all valid ROMs as suspended.
     *
     * Called when an IEEE 1394 bus reset occurs and a new generation begins.
     * @param newGen The newly started generation.
     */
    void SuspendAll();
    void SuspendAll(Generation newGen);

    /**
     * @brief Validates a ROM after a bus reset (device reappeared).
     *
     * @param guid The 64-bit GUID.
     * @param gen The current generation.
     * @param nodeId The new node ID of the device.
     */
    void ValidateROM(Guid64 guid, Generation gen, uint8_t nodeId);

    /**
     * @brief Marks a ROM as invalid (device disappeared or ROM content changed).
     *
     * @param guid The 64-bit GUID to invalidate.
     */
    void InvalidateROM(Guid64 guid);

    /**
     * @brief Removes all invalid ROMs from storage.
     */
    void PruneInvalid();

  private:
    // Packed key layout: generation in upper bits, node ID in low 8 bits.
    using GenNodeKey = uint64_t;
    static GenNodeKey MakeKey(Generation gen, uint8_t nodeId);

    struct ExportEntry {
        uint64_t resetEpoch{0};
        ConfigROM rom;
    };

    void InsertLocked(const ConfigROM& rom);
    void RevokeExportScopeLocked(const ConfigROMExportAdmission& admission);
    void AdvanceExportResetEpochLocked();
    void SuspendAllLocked(std::optional<Generation> newGen);

    mutable IOLock* lock_{nullptr};

    std::map<GenNodeKey, ConfigROM> romsByGenNode_;
    std::map<Guid64, ConfigROM> romsByGuid_;
    std::map<GenNodeKey, ExportEntry> exportableByGenNode_;

    // These counters are deliberately wider than the wire generation. They are
    // never reset during the lifetime of the store; saturation fails closed.
    uint64_t exportResetEpoch_{1};
    uint64_t nextExportScanSerial_{1};
    uint64_t activeExportScanSerial_{0};
    bool exportAuthoritySaturated_{false};
};

} // namespace ASFW::Discovery
