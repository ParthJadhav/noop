import SwiftUI
import StrandDesign

/// #590 — on-device storage diagnostics. iOS users saw "Documents & Data" balloon to ~19 GB after an
/// Apple Health import: the document picker's `asCopy:true` duplicate sat in `Documents/Inbox/` forever
/// and the WAL never truncated. AppModel now reclaims both automatically (Inbox cleanup on import +
/// launch, WAL truncate after each import); this screen makes the footprint VISIBLE and gives a manual
/// "Clean up now" escape hatch for anyone who already grew a backlog before the fix shipped.
///
/// Read-only otherwise: it shows the database size, the leftover Inbox size, and any stranded import
/// temp files. The button purges Inbox + temp and truncates the WAL — never touches live rows.
struct StorageView: View {
    @EnvironmentObject var model: AppModel

    @State private var report: AppModel.StorageReport?
    @State private var loading = true
    @State private var cleaning = false
    @State private var lastCleanedSummary: String?

    var body: some View {
        ScreenScaffold(title: "Storage",
                       subtitle: "Where NOOP's on-device space is going, and a one-tap clean-up.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                if loading && report == nil {
                    StatePill("Measuring…", tone: .accent, pulsing: true)
                        .staggeredAppear(index: 0)
                } else if let report {
                    breakdownCard(report).staggeredAppear(index: 0)
                    cleanUpCard(report).staggeredAppear(index: 1)
                } else {
                    DataPendingNote(title: "Storage unavailable",
                                    message: "Couldn't read the local store right now. Try again in a moment.",
                                    symbol: "internaldrive")
                        .staggeredAppear(index: 0)
                }
                explainerCard.staggeredAppear(index: 2)
            }
        }
        .task { await load() }
    }

    // MARK: - Cards

    private func breakdownCard(_ r: AppModel.StorageReport) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("On-device footprint")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                row(icon: "cylinder.split.1x2",
                    label: "Health database",
                    bytes: r.db,
                    tint: StrandPalette.accent)
                Divider().overlay(StrandPalette.hairline)
                row(icon: "tray.full",
                    label: "Leftover import copies",
                    bytes: r.inbox,
                    tint: r.inbox > 0 ? StrandPalette.statusWarning : StrandPalette.textTertiary,
                    note: r.inbox > 0 ? "Reclaimable" : nil)
                Divider().overlay(StrandPalette.hairline)
                row(icon: "clock.arrow.circlepath",
                    label: "Import temp files",
                    bytes: r.importTemp,
                    tint: r.importTemp > 0 ? StrandPalette.statusWarning : StrandPalette.textTertiary,
                    note: r.importTemp > 0 ? "Reclaimable" : nil)
            }
        }
    }

    private func cleanUpCard(_ r: AppModel.StorageReport) -> some View {
        let reclaimable = r.inbox + r.importTemp
        return StrandCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Clean up")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(reclaimable > 0
                     ? "There's about \(Self.format(reclaimable)) of leftover import scratch space to reclaim. This never removes your imported data."
                     : "Nothing to reclaim right now. NOOP already cleans up import scratch space automatically.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastCleanedSummary {
                    Text(lastCleanedSummary)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusPositive)
                }

                Button {
                    Task { await cleanUp() }
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        if cleaning { ProgressView().controlSize(.small) }
                        Text(cleaning ? "Cleaning up…" : "Clean up now")
                    }
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(cleaning || reclaimable == 0)
                .accessibilityLabel("Clean up leftover import files")
            }
        }
    }

    private var explainerCard: some View {
        DataPendingNote(
            title: "Why does this grow?",
            message: "When you import an Apple Health or WHOOP export, iOS hands NOOP a private copy of the file. NOOP reads it, saves your data into the health database, then deletes the copy. Older builds didn't delete every copy. This screen reclaims any that were left behind.",
            symbol: "questionmark.circle")
    }

    // MARK: - Row

    private func row(icon: String, label: LocalizedStringKey, bytes: Int64?,
                     tint: Color, note: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.headline)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let note {
                    Text(note)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Text(bytes.map(Self.format) ?? "—")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        let r = await model.storageReport()
        report = r
        loading = false
    }

    private func cleanUp() async {
        guard !cleaning else { return }
        cleaning = true
        let before = (report?.inbox ?? 0) + (report?.importTemp ?? 0)
        let r = await model.cleanUpStorage()
        let after = r.inbox + r.importTemp
        let freed = max(0, before - after)
        report = r
        lastCleanedSummary = freed > 0 ? String(localized: "Reclaimed \(Self.format(freed)).") : String(localized: "Already clean.")
        cleaning = false
    }

    /// Human byte size, decimal (matches iOS Settings' "Documents & Data" presentation).
    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }
}
