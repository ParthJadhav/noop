import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Invariant I2 — a day's scores come from exactly ONE source. This proves the wired read path end to
/// end: two devices have HR for the SAME UTC day, the resolver picks the owner (the active strap wins
/// over an import), and reading the owner's HR returns ONLY the owner's samples — never the other
/// device's. Mirrors `IntelligenceEngine.resolveDayOwner` + the per-day stream read it feeds.
final class DayOwnerReadIntegrationTests: XCTestCase {

    /// 2026-06-15 00:00:00 UTC. The night window the engine reads spans [dayStart-30h, dayStart+12h];
    /// we seed HR squarely inside it (a few hours past midnight) under each device.
    private let dayStart = 1_781_481_600          // 2026-06-15 00:00:00 UTC
    private let day = "2026-06-15"

    /// Build candidates exactly as `IntelligenceEngine.resolveDayOwner` does, then resolve.
    private func resolveOwner(store: WhoopStore, registry: DeviceRegistryStore,
                              from: Int, to: Int) async throws -> String? {
        if let locked = try registry.dayOwner(day)?.deviceId { return locked }
        let activeId = try registry.activeDeviceId() ?? "my-whoop"
        var candidates: [DayOwnerResolver.Candidate] = []
        for d in try registry.all() where d.status != .archived {
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            let priority = d.id == activeId ? 0 : (isImport ? 2 : 1)
            let hasData = !((try? await store.hrSamples(deviceId: d.id, from: from, to: to, limit: 1)) ?? []).isEmpty
            candidates.append(.init(deviceId: d.id, priority: priority, hasData: hasData))
        }
        return DayOwnerResolver.resolve(day: day, lockedOwner: nil, candidates: candidates)
    }

    func testActiveStrapOwnsDayAndReadReturnsOnlyItsSamples() async throws {
        let store = try await WhoopStore.inMemory()    // migration v15 seeds active 'my-whoop'
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)

        // A second source: an Oura CLOUD IMPORT (priority 2), paired but not active.
        try registry.add(PairedDevice(id: "oura-import", brand: "Oura", model: "Oura (import)",
                                      sourceKind: .cloudImport, capabilities: [.hr, .sleep],
                                      status: .paired, addedAt: 1, lastSeenAt: 1))

        // Seed HR for BOTH devices on the SAME UTC day, with distinguishable bpm so the read's source
        // is unambiguous: WHOOP @ 55 bpm, Oura @ 99 bpm, both a few hours after midnight.
        let base = dayStart + 3 * 3_600
        let whoopHR = (0..<300).map { HRSample(ts: base + $0, bpm: 55) }
        let ouraHR  = (0..<300).map { HRSample(ts: base + $0, bpm: 99) }
        _ = try await store.insert(Streams(hr: whoopHR), deviceId: "my-whoop")
        _ = try await store.insert(Streams(hr: ouraHR),  deviceId: "oura-import")

        let from = dayStart - 30 * 3_600
        let to = dayStart + 12 * 3_600

        // I2 resolution: the active strap (priority 0) wins over the import (priority 2).
        let owner = try await resolveOwner(store: store, registry: registry, from: from, to: to)
        XCTAssertEqual(owner, "my-whoop", "the active strap must own a day it has data for")

        // Read the day's HR under the resolved owner — it must be PURELY the owner's samples.
        let read = try await store.hrSamples(deviceId: owner!, from: from, to: to, limit: 200_000)
        XCTAssertEqual(read.count, whoopHR.count)
        XCTAssertTrue(read.allSatisfy { $0.bpm == 55 }, "owner read leaked the other device's samples")
        XCTAssertFalse(read.contains { $0.bpm == 99 }, "Oura (non-owner) samples must never appear")
    }

    /// A locked dayOwnership override beats priority: even though the active WHOOP has data, a lock to
    /// the import makes the import own the day, and the read returns only the import's samples.
    func testLockedOwnerOverridesAndReadFollowsIt() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "oura-import", brand: "Oura", model: "Oura (import)",
                                      sourceKind: .cloudImport, capabilities: [.hr],
                                      status: .paired, addedAt: 1, lastSeenAt: 1))

        let base = dayStart + 3 * 3_600
        _ = try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 55) }), deviceId: "my-whoop")
        _ = try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 99) }), deviceId: "oura-import")

        try registry.setDayOwner(day: day, deviceId: "oura-import", locked: true)

        let from = dayStart - 30 * 3_600, to = dayStart + 12 * 3_600
        let owner = try await resolveOwner(store: store, registry: registry, from: from, to: to)
        XCTAssertEqual(owner, "oura-import", "a locked override must win over the active strap")

        let read = try await store.hrSamples(deviceId: owner!, from: from, to: to, limit: 200_000)
        XCTAssertTrue(read.allSatisfy { $0.bpm == 99 }, "read must follow the locked owner")
    }

    /// Single-device install (the default): only the seeded active 'my-whoop' is paired. The owner
    /// MUST resolve to 'my-whoop' so behaviour is byte-identical to the pre-I2 code.
    func testSingleDeviceResolvesToWhoopUnchanged() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)

        let base = dayStart + 3 * 3_600
        _ = try await store.insert(Streams(hr: (0..<300).map { HRSample(ts: base + $0, bpm: 55) }), deviceId: "my-whoop")

        let from = dayStart - 30 * 3_600, to = dayStart + 12 * 3_600
        let owner = try await resolveOwner(store: store, registry: registry, from: from, to: to)
        XCTAssertEqual(owner, "my-whoop", "single-device install must resolve to the seeded WHOOP")

        let read = try await store.hrSamples(deviceId: owner!, from: from, to: to, limit: 200_000)
        XCTAssertEqual(read.count, 300)
        XCTAssertTrue(read.allSatisfy { $0.bpm == 55 })
    }
}
