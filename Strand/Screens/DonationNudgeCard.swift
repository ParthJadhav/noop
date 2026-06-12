import SwiftUI
import StrandDesign

// MARK: - Donation nudge (Today screen)
//
// A small, dismissible card that asks — at most once every 12 hours — whether NOOP is
// proving useful, and makes the honest economic case for a donation: a WHOOP membership
// costs $300–480 a year, NOOP is free and built by one person, and almost nobody donates.
//
// Deliberately a CARD in the Today flow, not a modal: it never blocks anything, never
// interrupts, and carries a permanent opt-out. The stats line is baked in at release time
// (see `DonationStats`) so the app stays fully offline — no network calls, ever.

/// Release-time-stamped community stats shown in the nudge. Refresh with
/// `Tools/update-donation-stats.sh` before each release (reads the GitHub release API and
/// the public donation-address explorers; the app itself NEVER touches the network).
enum DonationStats {
    /// Total release-asset downloads across all releases, rounded down to a friendly floor.
    static let downloads = 5_000
    /// Distinct on-chain donations received across the BTC + ETH addresses.
    static let donors = 7
    /// The canonical donations page (wiki).
    static let donateURL = URL(string: "https://github.com/NoopApp/noop/wiki/Donations")!
}

struct DonationNudgeCard: View {

    /// Unix seconds the nudge was last shown (0 = never). Stamped when the card renders.
    @AppStorage("noop.donate.lastShownTs") private var lastShownTs = 0.0
    /// Permanent opt-out ("Don't ask again").
    @AppStorage("noop.donate.optOut") private var optOut = false
    /// Session-local dismiss ("Later") so the card vanishes immediately on tap; the 12 h
    /// window is enforced by `lastShownTs` across launches.
    @State private var snoozedThisSession = false

    @Environment(\.openURL) private var openURL

    /// Whether the card should render right now: not opted out, not snoozed, and at least
    /// 12 h since it last appeared. First evaluation arms the timer instead of showing, so
    /// a brand-new install gets its first nudge after 12 h of real use, not on first launch.
    private var shouldShow: Bool {
        if optOut || snoozedThisSession { return false }
        let now = Date().timeIntervalSince1970
        if lastShownTs == 0 {
            // Arm on first sight; show from the next 12 h window on.
            DispatchQueue.main.async { lastShownTs = now }
            return false
        }
        return now - lastShownTs >= 12 * 3_600
    }

    var body: some View {
        if shouldShow {
            NoopCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.circle.fill")
                            .foregroundStyle(StrandPalette.accent)
                        Text("Enjoying NOOP?")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                    }
                    Text("A WHOOP membership runs $300–480 a year, for life. NOOP does this for free — one person, no servers, no subscription.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(DonationStats.downloads.formatted())+ downloads so far — \(DonationStats.donors) donors.")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("If it's saving you a subscription, one month of it — $30, $100, anything — genuinely keeps the project alive. Crypto only; the project stays anonymous.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button {
                            openURL(DonationStats.donateURL)
                            stamp()
                        } label: {
                            Label("Donate", systemImage: "heart.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)
                        Button("Later") { stamp() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Don't ask again") {
                            optOut = true
                        }
                        .buttonStyle(.plain)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityLabel("Don't ask about donations again")
                    }
                }
            }
            .onAppear { lastShownTs = Date().timeIntervalSince1970 }
        }
    }

    /// Snooze: hide immediately and restart the 12 h window from now.
    private func stamp() {
        lastShownTs = Date().timeIntervalSince1970
        snoozedThisSession = true
    }
}
