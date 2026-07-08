

# NOOP Local Oura BLE Source — Architecture + Ordered Implementation Plan

Replaces the current "honest dead-end" `OuraProbeSource` (Strand/BLE/OuraProbeSource.swift + android `OuraProbeSource.kt`) with a real, WHOOP-isolated, clean-room **live Oura BLE source** that decodes the ring's own raw signals and HRV/sleep tags, runs **NOOP's own scoring**, and produces a NOOP Charge/Rest for an Oura day exactly like a WHOOP day. All protocol byte-facts are cited from the RE resources; no RE source is copied — we write our own framing/auth/decoders from the documented facts only.

## 0. Existing-code contracts the plan binds to (verified by reading the repo)

- **Live-source template (mirror this, NOT BLEManager):** `Strand/BLE/StandardHRSource.swift` + twin `android/.../ble/StandardHrSource.kt`. Owns its OWN `CBCentralManager` (queue-less → main-actor callbacks) / OWN `BluetoothGatt`+scanner; never imports `BLEManager`/`WhoopBleClient`. Injected surfaces only: `live: LiveState`, `persist`, `log`, `onBattery`. Batches samples (count 30 / 30 s). `Strand/BLE/HuamiHRSource.swift` is the precedent for a custom-UUID, multi-step-handshake, honest-fallback driver (publishes `needsPairing` instead of faking data).
- **Persist contract:** `WhoopStore.StreamStore.insert(_ streams: Streams, deviceId: String) async throws`. `Streams` (Packages/WhoopProtocol/.../Streams.swift) carries `hr, rr, spo2, skinTemp, resp, gravity, steps, ppgHr, events, battery`; every sample table is keyed `(deviceId, ts)` — isolation by registry `id`, no per-row source column. Android twin: `WhoopRepository.insert(StreamBatch, deviceId)`; the Android live `Streams`/`StreamBatch` (protocol/Streams.kt) currently carries only `hr/rr/events/battery` (spo2/skinTemp/steps/resp/gravity/ppgHr Room entities + DAO inserts exist, so the live batch gets extended here).
- **Pure mapping precedent:** `WhoopStore.StandardHRMapping.samples(fromHR:rr:at:)`. We add a parallel `OuraStreamMapping`.
- **Registry model:** `WhoopStore.PairedDevice` (`id`, `brand`, `model`, `peripheralId`, `sourceKind`, `capabilities: Set<Metric>`). `SourceKind` = `liveBLE, historyBLE, cloudImport, fileImport, ftms, huami, liveAppleWatch`. `Metric` = `hr, hrv, spo2, skinTemp, steps, sleep, strainLoad`. Android twins: `data/PairedDevice.kt` (string-backed `enum class SourceKind`), `data/DeviceRegistry.kt`.
- **Coordinator:** `Strand/BLE/SourceCoordinator.swift` + `android/.../ble/SourceCoordinator.kt`. `switchToStrap` routes by `sourceKind(for:)` in a `switch`: `.ftms → FTMSSource`, `.huami → HuamiHRSource`, default → `StandardHRSource`; exactly one non-WHOOP source live at a time (`tearDownNonWhoopSource()`). WHOOP path is a strict no-op for the single-WHOOP user.
- **Wizard:** `Strand/Screens/AddDeviceWizard.swift` (+ `android/.../ui/AddDeviceWizard.kt`). `DeviceType.oura` already exists, wired to the `OuraProbeSource` dead-end via `OuraPickList`; `finishAdd(makeActive:)` builds the `PairedDevice` per path.
- **Scoring is stream-driven, per-device:** `Packages/StrandAnalytics` `RecoveryScorer.recovery(hrv:..., sleepPerf:...)`, `restingHR(_ hr:[HRSample]...)`, `DayOwnerResolver`, `AnalyticsEngine`, `SleepStager`. Recovery needs HRV (RMSSD ms) + sleeping resting-HR + a sleep/rest composite; strain needs the HR stream — all off the per-device `Streams` + sleep sessions. So **if the live source lands real hr/rr + HRV + sleep-phase data under its deviceId, the existing engine scores the Oura day with zero scorer changes.**

**Honest-data invariant (hard):** Oura's own encrypted readiness/sleep scores are never read or surfaced. We decode only raw PPG/IBI/accel + the ring's open event tags (HR 0x55, IBI 0x44/0x60, RMSSD 0x5d, SpO2 0x6F/0x70/0x77, temp 0x46/0x75, sleep-phase 0x49/0x4B/0x4C/0x4E/0x4F/0x58) and compute NOOP's Charge/Rest ourselves. When a signal can't be read, the source stays at "—" (Huami precedent).

## 1. Clean-room protocol PACKAGE — `Packages/OuraProtocol/` (+ Kotlin `com.noop.oura.*`)

Structured like `Packages/WhoopProtocol` (swift-tools 5.9, `.iOS(.v16)/.macOS(.v13)`, `.target` + `.testTarget`, optional `oura-decode` executable mirroring `whoop-decode`). Pure value types only — zero CoreBluetooth / zero `android.bluetooth` — so every module is headless/JVM-testable (the repo can't run headless XCTest).

Swift modules under `Sources/OuraProtocol/`:
- `OuraGatt.swift` — UUIDs: service `98ED0001-A541-11E4-B6A0-0002A5D5C51B`, write `…0002`, notify `…0003`, Ring-5 extra `…0004/5/6`, MTU 247 (brief/known facts).
- `Framing.swift` — encode command frame `2f <opcode-lo> <opcode-hi> [payload]`; reassemble notification fragments → complete records (open_oura cheatsheet; ringverse BLE.md).
- `Auth.swift` — pure crypto state machine: `GetAuthNonce` (`2f012b`), accept 15-byte nonce, AES-128/ECB/PKCS7-pad with the install key, build `Authenticate` (`2f112d` + ciphertext); `InstallKey` (opcode `0x24`, 16-byte key, post-factory-reset). Key injected, never hardcoded (brief; open_ring PROTOCOL.md).
- `Commands.swift` — opcode builders incl. Ring-3 live-HR enable (relue): `2f0220` → `2f032202 03` → `2f032602 02`; subscribe-events / battery / fetch-buffered (relue heartbeat-monitoring.md; open_oura).
- `EventTags.swift` — tag dictionary enum: hr=0x55, ibi=0x44, ibiAmp=0x60, hrvRmssd=0x5d, spo2=0x6F/0x70/0x77, temp=0x46/0x75, sleepPhase∈{0x49,0x4B,0x4C,0x4E,0x4F,0x58}, ppg, motion, battery, met (ringverse oura/BLE.md; open_ring).
- `Decoders.swift` — pure per-tag byte→value decoders; each returns nil on a malformed/short record (open_ring PROTOCOL.md layouts).
- `OuraEvents.swift` — decoded structs the driver emits (OuraHR/OuraIBI/OuraHRV/OuraSpO2/OuraTemp/OuraSleepPhase/OuraBattery).
- `RingGen.swift` — `enum OuraRingGen { gen3, gen4, gen5 }` + per-gen caps/MTU/command-set + best-effort `recognise(advertisedName:)`/`from(model:)` (open_oura ring-5/ring-3; open_ring ring-4).
- `OuraDriver.swift` — public transport-agnostic state machine: `nextStep(after:) -> [Command]` (scan→auth→enable→stream) + `ingest(record:) -> [OuraEvent]`. Holds NO BLE handle; this is what makes the protocol headless-testable.
- `Sources/oura-decode/main.swift` — CLI replaying captured raw records → decoded events (mirrors whoop-decode).

Kotlin twin `android/.../oura/{OuraGatt,Framing,Auth,Commands,EventTags,Decoders,OuraEvents,RingGen,OuraDriver}.kt` — byte-for-byte parity, JVM-pure, JVM-tested; AES via `javax.crypto` `AES/ECB/PKCS5Padding`. Test targets carry golden fixtures (raw record → expected decoded event per tag), an auth known-vector test, framing-reassembly tests, and a Swift↔Kotlin parity test (mirrors `ParityTests`).

## 2. BLE TRANSPORT — `OuraLiveSource` (own central) + Kotlin twin (own GATT)

**Swift `Strand/BLE/OuraLiveSource.swift`** (replaces OuraProbeSource), `@MainActor final class`, mirrors StandardHRSource:
- OWN `CBCentralManager(delegate:self, queue:nil)`, `@preconcurrency CBCentralManagerDelegate/CBPeripheralDelegate`; never references BLEManager.
- Injected deps (parity): `live`, `deviceId`, `persist:(Streams)->Void`, `log`, `onBattery`, plus `ringGen: OuraRingGen` and `authKey: () -> Data?` (16-byte install key from Keychain; nil → drive the Huami-style honest `needsPairing` path).
- `@Published discovered:[DiscoveredRing]`, `scanning`, `batteryPct`, `needsPairing:String?`.
- Flow driven by the pure `OuraDriver`: scan (`scanForPeripherals(withServices:[OuraGatt.service])`, filter by RingGen.recognise) → connect (cached-by-identifier first, else scan-then-connect — exact StandardHRSource seenPeripherals/pendingConnectID/retrievePeripherals pattern) → discoverServices → notify on `…0003` → auth (write GetAuthNonce, compute+write Authenticate) → write gen-appropriate enable/subscribe → `didUpdateValueFor` → Framing.reassemble → OuraDriver.ingest → OuraStreamMapping → buffer → `persist(Streams)` (30/30s); live HR also to `live.heartRate`/`setRRIntervals`/`connected`; battery → `onBattery`. `stop()`/disconnect: cancel, clear batteryPct/needsPairing, flush, `live.connected=false`, reset loggedFirst* (idempotent).
- Logs self-prefixed `"Oura: "` into the shared exportable strap log (#421 parity): statuses/UUIDs/counts only, never a device address.

**Kotlin `android/.../ble/OuraLiveSource.kt`** (replaces OuraProbeSource.kt): own `BluetoothLeScanner`+`BluetoothGatt`, `@SuppressLint("MissingPermission")`, main-`Handler`, `guardedCallback(label){}` so a decode/binder throw degrades to "no data" not a crash-loop (#421 lesson), explicit CCCD writes, status-133 single auto-retry. Same closures `liveSink`/`persist:(StreamBatch,String)->Unit`/`log`/`onBattery` + `ringGen`/`authKey`, driving the JVM-pure `OuraDriver`.

**Isolation:** only shared surfaces are live/persist/log/onBattery — WHOOP's central/GATT untouched, no regression.

## 3. SourceKind / Coordinator / Wizard / DevicesView wiring (Swift AND Kotlin)

- **3a SourceKind.oura:** Swift add `case oura` to `SourceKind` (additive); Kotlin add `oura` to the string-backed `enum class SourceKind` (no DB migration).
- **3b Coordinator:** Swift add `ouraSource: OuraLiveSource?`, `case .oura: startOuraSource(id:)` in switchToStrap's switch, `startOuraSource` mirroring `startHuamiSource` (peripheralId→connect-by-uuid else scan; persist via storeHandle().insert(_,deviceId:); onBattery→live.setBattery; pass ringGen from the row's model + authKey from Keychain), and `ouraSource?.stop(); ouraSource=nil` in teardown. Kotlin: parallel `ouraSource` + `when` branch + teardown. `.oura` rides the existing WHOOP-pause / single-source edge for free.
- **3c Wizard:** Swift swap `@StateObject ouraScanner` from OuraProbeSource→OuraLiveSource (discovery-only, deviceId "scan-preview", no-op persist); real `prepInstructions(.oura)`; replace `OuraPickList` dead-end with a normal `DiscoveredRow` pick list (like HuamiPickList) feeding `@State pickedOura` + detected `ringGen`; `finishAdd` adds an `else if let pickedOura` block → `PairedDevice(id:"oura-<uuid>", brand:"Oura", model:ringGen.displayName, peripheralId:uuid, sourceKind:.oura, capabilities: gen-filtered set, status:.paired)`. Keep under Experimental heading with "Use file import" fallback when `needsPairing` is set. Kotlin: same edits in ui/AddDeviceWizard.kt.
- **3d DevicesView:** Swift `DevicesView.swift` + Kotlin `ui/DevicesScreen.kt`/`DataSourcesScreen.kt` — extend the generic capability/battery rendering keyed off brand=="Oura"/sourceKind==.oura with per-gen capability copy + a `needsPairing` honest-state row. No bespoke card type.

## 4. SCORING / STREAM contract — Oura day → NOOP Charge/Rest

Decoded events map onto the EXISTING `Streams` and persist under the ring's deviceId; existing analytics score the day unchanged. Glue lives in a pure testable `OuraStreamMapping` (WhoopStore, beside StandardHRMapping):

- HR 0x55 → `hr:[HRSample]` → RecoveryScorer.restingHR + strain HR stream.
- IBI 0x44/0x60 → `rr:[RRInterval]` → HRV/R-R analytics.
- HRV 0x5d → `events:[WhoopEvent(kind:"OURA_HRV", payload:["time_ms":…,"b1":…,"b2":…])]` raw units-neutral fields only (the b1/b2 byte to ms scale is not Tier-A, so no fabricated `rmssd_ms`); NOOP's scoring RMSSD comes from the `rr` IBI stream, never Oura's readiness.
- SpO2 0x6F/0x70/0x77 → `spo2:[SpO2Sample(raw_adc)]`.
- Temp 0x46/0x75 → `skinTemp:[SkinTempSample(raw_adc)]`.
- Sleep-phase tags → `events:[WhoopEvent(kind:"OURA_SLEEP_PHASE", payload:["phase":…])]` folded into a `sleepSession` for that deviceId → SleepStager/SleepStageTotals → the `sleepPerf` composite fed to recovery.
- Battery → `battery:[BatterySample]` + live onBattery.

`recovery(hrv: ourRMSSD, sleepPerf: ourSleepComposite, hrvBaseline:…)` = NOOP Charge; strain from the HR stream = NOOP Rest/strain — identical to a WHOOP day because DayOwnerResolver/AnalyticsEngine key off (deviceId, streams, sleepSession). Missing inputs leave sub-scores nil (honest), never faked. Android twin extends protocol/Streams.kt/StreamBatch with spo2/skinTemp/events (DAO inserts already exist) + a Kotlin OuraStreamMapping; sleep-phase events fold into the existing sleepSession Room table.

## 5. Ring-gen (3/4/5) identity + per-gen capability

- Carried on `PairedDevice.model` ("Oura Ring 3/4/5") — no schema change; `OuraRingGen.from(model:)` recovers it; `RingGen.capabilities` drives the registered capability set + DevicesView copy.
- Per-gen behaviour in RingGen/Commands: gen5 → MTU 247 + notify chars `…0004/5/6`; gen3 → relue live-HR triplet; enable/subscribe sets selected by gen. Detection at scan is best-effort, confirmed by the model the user picks. One transport handles all gens by swapping command sets, not code paths.

## Ordered file-by-file work breakdown (each unit independently buildable → safe to fan out)

**Phase A — clean-room package (pure, no BLE).** A1–A8 parallel; A9 composes them.
- A1 `Packages/OuraProtocol/Package.swift` + Sources/Tests skeleton (mirror WhoopProtocol). Build: `swift build`.
- A2 `OuraGatt.swift` (UUIDs+MTU). A3 `RingGen.swift`. A4 `EventTags.swift`. A5 `Framing.swift`. A6 `Auth.swift` (known-vector test). A7 `Commands.swift` (byte-exact). A8 `OuraEvents.swift`+`Decoders.swift` (golden fixtures). Each ships its own unit tests.
- A9 `OuraDriver.swift` + `Sources/oura-decode/main.swift` (driver-flow tests on fixtures).

**Phase A′ — Kotlin twin (parallel to A, JVM-pure).** A1′–A9′ one task per file under `android/.../oura/`, mirroring tests/fixtures. A10 Swift↔Kotlin parity test on shared fixtures.

**Phase B — mapping glue (pure; depends on A8 types).**
- B1 `Packages/WhoopStore/.../OuraStreamMapping.swift` (the §4 table) + tests beside StandardHRMappingTests.
- B1′ `android/.../data/OuraStreamMapping.kt` + extend protocol/Streams.kt/StreamBatch (spo2/skinTemp/events) + wire WhoopRepository.insert to existing DAO inserts (JVM tests).

**Phase C — registry plumbing (small).** C1 Swift `SourceKind.oura` in PairedDevice.swift. C1′ Kotlin `oura` in data/PairedDevice.kt.

**Phase D — transport (depends on A9, B1, C1).** D1 Swift `OuraLiveSource.swift` (replaces OuraProbeSource.swift) + Keychain install-key accessor. D1′ Kotlin `OuraLiveSource.kt` (replaces OuraProbeSource.kt) + key-store accessor.

**Phase E — coordinator (depends on D).** E1 Swift SourceCoordinator.swift edits. E1′ Kotlin SourceCoordinator.kt edits.

**Phase F — wizard + DevicesView (depends on D+C).** F1/F1′ AddDeviceWizard (swap scanner, real prep/pick/register). F2/F2′ DevicesView/DevicesScreen Oura capability card + needsPairing state.

**Phase G — cleanup.** G1 delete OuraProbeSource.swift/.kt + wizard refs once D/F land; keep the Oura file-import lane (StrandImport/OuraExportParser.swift) as documented fallback. G2 update ATTRIBUTION.md/protocol docs to cite RE resources facts-only.

**Verification (per build-env memory):** Phases A/B/C via SPM `swift test` (OuraProtocol, WhoopStore) + Android JVM tests; D/E/F via the live-sim screenshot harness; central build-verify of all three platforms once at the end (no per-lane gradle).

