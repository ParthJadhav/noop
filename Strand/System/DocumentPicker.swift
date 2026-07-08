#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Async wrappers around `UIDocumentPickerViewController` for importing/exporting the database
/// backup on iOS. Each call presents the system picker from the active window and resumes a
/// continuation with the chosen URL (or `nil` if cancelled).
enum DocumentPicker {

    /// Present the picker to export `url` (saves a copy into Files / iCloud Drive). Returns the
    /// destination URL the user picked, or `nil` if cancelled.
    @MainActor
    static func export(_ url: URL) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = coordinator
            return picker
        }
    }

    /// Present the picker to import a file of one of `types`. `asCopy` is used so we receive a
    /// readable local copy in our sandbox (no security-scoped bookkeeping needed).
    @MainActor
    static func importFile(_ types: [UTType]) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            return picker
        }
    }

    /// Present a folder picker (Backup & Sync). Returns the chosen folder, or nil.
    ///
    /// To let the user actually SELECT a directory (not just dive into it), the picker must be built for
    /// OPENING the `.folder` content type with `asCopy: false`. The bare `forOpeningContentTypes:` form
    /// historically left Files' "Open"/"Select" greyed out for folders on some iOS builds (#859), because
    /// without the explicit `asCopy: false` the picker can resolve to a copy-in (import) presentation that
    /// only enables the button for files. Passing `asCopy: false` puts it in true open-in-place mode, where
    /// the directory itself is selectable and the button enables on a folder. The returned URL is
    /// security-scoped; the caller bookmarks it (see `FolderBackup.saveFolder`, which brackets the scoped
    /// access while minting the bookmark) so the chosen folder survives relaunch.
    ///
    /// `startingAt` (#1000a): an explicit starting directory — the caller's last-used folder when there
    /// is one, else our own Documents. Some iOS builds reportedly keep the Open/Select button disabled
    /// when the picker opens on its default "Recents"-style root; giving it a concrete `directoryURL`
    /// lands it on a real, selectable directory. HONESTY NOTE: we could not reproduce the dead button
    /// in-house and Apple documents `directoryURL` only as a hint, so on the affected iOS build this
    /// may or may not be the whole fix — which is why `BackupSyncView` now also surfaces a visible
    /// message when the picker comes back empty instead of failing silently.
    @MainActor
    static func pickFolder(startingAt root: URL? = nil) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            picker.directoryURL = root
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            return picker
        }
    }

    // MARK: - Presentation plumbing

    @MainActor
    private static func present(_ make: (Coordinator) -> UIDocumentPickerViewController) async -> URL? {
        guard let root = topViewController() else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let coordinator = Coordinator(continuation: continuation)
            let picker = make(coordinator)
            // Keep the coordinator alive for the lifetime of the picker.
            objc_setAssociatedObject(picker, &Coordinator.assocKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
            root.present(picker, animated: true)
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        static var assocKey = 0
        private let continuation: CheckedContinuation<URL?, Never>
        private var resumed = false

        init(continuation: CheckedContinuation<URL?, Never>) {
            self.continuation = continuation
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(nil)
        }

        private func finish(_ url: URL?) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: url)
        }
    }
}
#endif
