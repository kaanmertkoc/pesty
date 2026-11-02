import AppKit
import Observation

extension Notification.Name {
    static let pestyStoreDidSave = Notification.Name("PestyStoreDidSave")
}

enum BarSource: Equatable {
    case history
    case pinboard(UUID)
}

/// Whether keyboard focus currently belongs to the native search field or
/// to the clip strip. Lets the key monitor and the search field agree on
/// who owns a given keystroke without probing AppKit's first-responder
/// chain from every call site.
enum BarInputMode: Equatable {
    case cards
    case search
}

@Observable
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore(screenshotDirectory: { Settings.shared.screenshotFolderURL })

    private(set) var history: [ClipItem] = []
    private(set) var pinboards: [Pinboard] = []

    private var undoStack = ClipUndoStack()
    /// True while a deletion can still be undone; drives the bar's Undo button.
    private(set) var hasUndoableDeletion = false
    private var undoExpirationWorkItem: DispatchWorkItem?

    var source: BarSource = .history {
        didSet { if source != oldValue { clearMultiSelection() } }
    }
    var barInputMode: BarInputMode = .cards
    var searchText: String = "" {
        didSet { if searchText != oldValue { clearMultiSelection() } }
    }
    var selectedID: UUID?
    private(set) var multiSelectedIDs: Set<UUID> = []
    private var selectionAnchorID: UUID?

    /// Bumped every time the bar is about to present. The hosting view is
    /// built once and cached, so the strip keeps its scroll offset across
    /// hide/show; selection alone cannot reset it because the newest clip is
    /// usually already selected and `onChange` never fires for equal values.
    private(set) var barPresentationToken = 0

    var historyLimit: Int {
        get { Settings.shared.historyLimit }
        set { Settings.shared.historyLimit = newValue; trimHistory() }
    }

    private let persistence: LocalStorePersistence
    private(set) var persistenceError: String?
    private(set) var screenshotExportError: String?
    @ObservationIgnored private let screenshotDirectory: () -> URL?
    private var canSave = true
    @ObservationIgnored private var imageSizes: [String: Int] = [:]
    @ObservationIgnored private var pendingImageDeletions: Set<String> = []

    private var storeURL: URL
    private var imagesDir: URL
    private var baseDir: URL
    private var saveWorkItem: DispatchWorkItem?

    nonisolated static var localBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pesty", isDirectory: true)
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// The on-disk store root (history JSON plus saved images), exposed so
    /// Settings can report how much space history actually uses.
    var dataDirectory: URL { baseDir }

    init(baseDirectory: URL = ClipboardStore.localBase,
         screenshotDirectory: @escaping () -> URL? = { nil }) {
        self.screenshotDirectory = screenshotDirectory
        let base = baseDirectory
        baseDir = base
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        storeURL = base.appendingPathComponent("store.json")
        persistence = LocalStorePersistence(url: base.appendingPathComponent("store.json"))
        prepareDirectories()
        load()
        persistence.didSave = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.persistenceError = error
                if error == nil {
                    self.purgeDeletedImages()
                    NotificationCenter.default.post(name: .pestyStoreDidSave, object: nil)
                }
            }
        }
        if canSave {
            let previousCount = history.count
            trimHistory()
            if history.count != previousCount { saveNow() }
            if persistenceError == nil { removeOrphanedImages() }
        }
    }

    private func prepareDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
    }

    var visibleItems: [ClipItem] {
        let base: [ClipItem]
        switch source {
        case .history:
            base = history
        case .pinboard(let id):
            base = pinboards.first(where: { $0.id == id })?.items ?? []
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { $0.searchableText.contains(q) }
    }

    var selectedItem: ClipItem? {
        guard let id = selectedID else { return nil }
        return visibleItems.first(where: { $0.id == id })
    }

    func addCaptured(_ item: ClipItem) {
        guard canSave else { deleteImageFile(item); return }
        if let idx = history.firstIndex(where: { $0.sameContent(as: item) }) {
            if item.imageFileName != history[idx].imageFileName { deleteImageFile(item) }
            var existing = history.remove(at: idx)
            existing.createdAt = item.createdAt
            history.insert(existing, at: 0)
            if existing.type == .image { _ = imagePathURL(for: existing) }
            if source == .history && searchText.isEmpty && multiSelectedIDs.isEmpty {
                selectedID = existing.id
                selectionAnchorID = existing.id
            }
            scheduleSave()
            return
        }
        history.insert(item, at: 0)
        trimHistory()
        if item.type == .image, history.contains(where: { $0.id == item.id }) {
            _ = imagePathURL(for: item)
        }
        if source == .history && searchText.isEmpty && multiSelectedIDs.isEmpty {
            selectedID = item.id
            selectionAnchorID = item.id
        }
        scheduleSave()
    }

    /// A Copy from the Paste Bar is an intentional use of an existing clip.
    /// Promote it explicitly because the clipboard monitor correctly ignores
    /// Pesty's own pasteboard writes, so a plain re-copy would otherwise leave
    /// the clip sitting wherever it already was in history.
    func promoteCopiedItem(_ item: ClipItem, at date: Date = .now) {
        if history.contains(where: { $0.sameContent(as: item) }) {
            var copied = item
            copied.createdAt = date
            addCaptured(copied)
            return
        }
        // A Pinboard card with no history twin: history gets its own copy, as
        // it would from any other app's copy, never the pinboard's UUID.
        addCaptured(independentCopy(of: item, createdAt: date))
    }

    func applyRetentionPolicy() { trimHistory(); scheduleSave() }

    func retentionRemovalCount(mode: HistoryRetentionMode, limit: Int, days: Int) -> Int {
        switch mode {
        case .itemCount:
            return max(0, history.count - max(20, limit))
        case .timeInterval:
            // days == 0 means "forever" - no age-based cutoff, just the safety cap.
            guard let cutoff = Self.retentionCutoff(daysAgo: days) else {
                return max(0, history.count - Self.timeRetentionSafetyCap)
            }
            let byAge = history.filter { $0.createdAt < cutoff }.count
            return byAge + max(0, (history.count - byAge) - Self.timeRetentionSafetyCap)
        }
    }

    private static let timeRetentionSafetyCap = ClipResourceLimits.maximumHistoryCount

    private static func retentionCutoff(daysAgo days: Int) -> Date? {
        guard days > 0 else { return nil }
        return Date().addingTimeInterval(-TimeInterval(days) * 86_400)
    }

    private func trimHistory() {
        let settings = Settings.shared
        let countLimit = settings.historyRetentionMode == .itemCount
            ? historyLimit : Self.timeRetentionSafetyCap
        let cutoff = settings.historyRetentionMode == .timeInterval
            ? Self.retentionCutoff(daysAgo: settings.historyRetentionDays) : nil
        let retained = ClipResourceLimits.retainedHistory(history, countLimit: countLimit,
                                                          cutoff: cutoff, imageSize: imageSize)
        let ids = Set(retained.map(\.id))
        let removed = history.filter { !ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        history = retained
        for item in removed { deleteImageFile(item) }
        if let sel = selectedID, !ids.contains(sel) { selectFirst() }
        reconcileMultiSelection()
    }

    private func imageSize(_ item: ClipItem) -> Int {
        guard let name = item.imageFileName, let url = imageURL(for: item) else { return 0 }
        if let size = imageSizes[name] { return size }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        imageSizes[name] = size
        return size
    }

    /// Deletes a clip from the collection currently on screen only. A Pinboard
    /// is an independently saved collection: deleting a card from history must
    /// not erase saved copies, and deleting a pinboard copy must not touch
    /// history or other pinboards, even for legacy clips that share an id.
    /// Deleting exactly what was removed also closes an image-file leak: the
    /// old cross-container removal deleted entries under two file names but
    /// cleaned up only one of them.
    func delete(_ item: ClipItem, permanently: Bool = false) {
        delete(items: [item], permanently: permanently)
    }

    /// A deletion stays undoable for five minutes unless `permanently` is
    /// set for this one (Option was held) or the setting says so for all.
    func delete(items: [ClipItem], permanently: Bool = false) {
        let ids = Set(items.map(\.id))
        guard !ids.isEmpty else { return }
        // Captured before removal so repeated deletes walk down the list
        // instead of snapping back to the newest clip every time.
        let deletedIndex = visibleItems.firstIndex(where: { ids.contains($0.id) })
        let selectionDeleted = selectedID.map { ids.contains($0) } ?? false
        let placements: [ClipPlacement]
        switch source {
        case .history:
            placements = Self.placements(of: ids, in: history, container: .history)
            history.removeAll { ids.contains($0.id) }
        case .pinboard(let boardID):
            guard let boardIndex = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
            placements = Self.placements(of: ids, in: pinboards[boardIndex].items, container: source)
            pinboards[boardIndex].items.removeAll { ids.contains($0.id) }
        }
        if permanently || Settings.shared.deletePermanently {
            for placement in placements { deleteImageFile(placement.item) }
        } else {
            for deletion in undoStack.push(placements, at: Date(), imageSize: imageSize) {
                for placement in deletion.placements { deleteImageFile(placement.item) }
            }
            refreshUndoState()
        }
        multiSelectedIDs.subtract(ids)
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        if selectionDeleted {
            let remaining = visibleItems
            if let index = deletedIndex, !remaining.isEmpty {
                selectedID = remaining[min(index, remaining.count - 1)].id
            } else {
                selectFirst()
            }
            selectionAnchorID = selectedID
        }
        reconcileMultiSelection()
        scheduleSave()
    }

    func clearHistory() {
        let old = history
        history.removeAll()
        selectedID = nil
        forgetDeletions()
        for item in old { deleteImageFile(item) }
        reconcileMultiSelection()
        scheduleSave()
    }

    private static func placements(of ids: Set<UUID>, in items: [ClipItem],
                                   container: BarSource) -> [ClipPlacement] {
        items.indices.compactMap { index in
            guard ids.contains(items[index].id) else { return nil }
            return ClipPlacement(container: container,
                                 index: index,
                                 item: items[index],
                                 predecessorID: index > 0 ? items[index - 1].id : nil,
                                 successorID: index + 1 < items.count ? items[index + 1].id : nil)
        }
    }

    /// Puts the newest deletion back where it was, every clip of a bulk
    /// delete at once, while its five-minute window is open.
    @discardableResult
    func undoLastDelete() -> Bool {
        refreshUndoState()
        guard let deletion = undoStack.pop(at: Date()) else { return false }
        var restored: [UUID] = []
        for placement in deletion.placements.sorted(by: { $0.index < $1.index }) {
            switch placement.container {
            case .history:
                if restore(placement, into: &history) { restored.append(placement.item.id) }
            case .pinboard(let boardID):
                guard let i = pinboards.firstIndex(where: { $0.id == boardID }) else {
                    deleteImageFile(placement.item)
                    continue
                }
                if restore(placement, into: &pinboards[i].items) { restored.append(placement.item.id) }
            }
        }
        refreshUndoState()
        trimHistory()
        if let id = restored.first(where: { id in visibleItems.contains(where: { $0.id == id }) }) {
            selectedID = id
            selectionAnchorID = id
        }
        reconcileMultiSelection()
        scheduleSave()
        return true
    }

    /// A clip copied again in the meantime is left as it is rather than doubled.
    private func restore(_ placement: ClipPlacement, into items: inout [ClipItem]) -> Bool {
        let item = placement.item
        if items.contains(where: { $0.id == item.id || $0.sameContent(as: item) }) {
            deleteImageFile(item)
            return false
        }
        items.insert(item, at: placement.restorationIndex(in: items))
        return true
    }

    /// Drops deletions whose window has closed, releasing the image files
    /// they kept, and arms a timer for the next one so the Undo button
    /// retires on time.
    private func refreshUndoState() {
        let now = Date()
        for deletion in undoStack.removeExpired(at: now) {
            for placement in deletion.placements { deleteImageFile(placement.item) }
        }
        hasUndoableDeletion = !undoStack.isEmpty
        undoExpirationWorkItem?.cancel()
        undoExpirationWorkItem = nil
        guard let expiration = undoStack.nextExpiration else { return }
        let work = DispatchWorkItem { [weak self] in self?.refreshUndoState() }
        undoExpirationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, expiration.timeIntervalSince(now)),
                                      execute: work)
    }

    /// Clear History and removing a Pinboard are the moments deleted content
    /// is expected to be gone for good, so nothing stays restorable. Quitting
    /// forgets as well, since the stack does not outlive the process and the
    /// image files it kept would otherwise be orphaned.
    func forgetDeletions() {
        for deletion in undoStack.removeAll() {
            for placement in deletion.placements { deleteImageFile(placement.item) }
        }
        refreshUndoState()
    }

    @discardableResult
    func addPinboard(name: String, colorHex: String = "#5B8DEF") -> Pinboard {
        let b = Pinboard(name: name, colorHex: colorHex)
        pinboards.append(b)
        scheduleSave()
        return b
    }

    func renamePinboard(_ id: UUID, to name: String) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        pinboards[i].name = name
        scheduleSave()
    }

    func deletePinboard(_ id: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        if case .pinboard(let cur) = source, cur == id { source = .history }
        let removedItems = pinboards[i].items
        pinboards.remove(at: i)
        forgetDeletions()
        for item in removedItems { deleteImageFile(item) }
        reconcileMultiSelection()
        scheduleSave()
    }

    func saveToPinboard(_ item: ClipItem, boardID: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == boardID }) else { return }
        if pinboards[i].items.contains(where: { $0.sameContent(as: item) }) { return }
        pinboards[i].items.insert(independentCopy(of: item, createdAt: item.createdAt), at: 0)
        scheduleSave()
    }

    /// A copy with its own UUID and its own image file, so no two containers
    /// ever share an identity or a file.
    private func independentCopy(of item: ClipItem, createdAt: Date) -> ClipItem {
        var copy = ClipItem(
            type: item.type,
            text: item.text,
            rtfData: item.rtfData,
            htmlData: item.htmlData,
            imageFileName: item.imageFileName,
            imageHash: item.imageHash,
            fileURLs: item.fileURLs,
            colorHex: item.colorHex,
            sourceBundleID: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            customTitle: item.customTitle,
            createdAt: createdAt)
        if let dup = duplicateImageFile(item) { copy.imageFileName = dup }
        return copy
    }

    func item(withID id: UUID) -> ClipItem? {
        if let item = history.first(where: { $0.id == id }) { return item }
        return pinboards.lazy.flatMap(\.items).first(where: { $0.id == id })
    }

    @discardableResult
    func updateTextContent(_ text: String, richTextData: Data? = nil, for item: ClipItem) -> Bool {
        guard [.text, .richText, .link].contains(item.type),
              ClipResourceLimits.acceptsText(text),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let richTextData = ClipResourceLimits.boundedRTF(richTextData)
        let type: ClipType = richTextData != nil ? .richText : (isWebLink(text) ? .link : .text)
        return updateContent(of: item) { existing in
            var updated = existing
            updated.type = type
            updated.text = text
            updated.rtfData = richTextData
            updated.htmlData = nil
            updated.colorHex = nil
            return updated
        }
    }

    @discardableResult
    func updateColorContent(_ hex: String, for item: ClipItem) -> Bool {
        guard item.type == .color, let color = NSColor(hex: hex) else { return false }
        let normalized = color.hexString
        return updateContent(of: item) { existing in
            var updated = existing
            updated.type = .color
            updated.text = nil
            updated.rtfData = nil
            updated.htmlData = nil
            updated.colorHex = normalized
            return updated
        }
    }

    private func updateContent(of item: ClipItem, transform: (ClipItem) -> ClipItem) -> Bool {
        var changed = false
        let now = Date()

        if let i = history.firstIndex(where: { $0.id == item.id }) {
            var updated = transform(history[i])
            if updated != history[i] {
                updated.createdAt = now
                history.remove(at: i)
                removeContentDuplicates(of: updated, in: &history)
                history.insert(updated, at: 0)
                changed = true
            }
        }

        for b in pinboards.indices {
            guard let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }) else { continue }
            var updated = transform(pinboards[b].items[i])
            if updated != pinboards[b].items[i] {
                updated.createdAt = now
                pinboards[b].items[i] = updated
                removeContentDuplicates(of: updated, in: &pinboards[b].items)
                changed = true
            }
        }

        guard changed else { return false }
        trimHistory()
        if selectedItem == nil { selectFirst() }
        reconcileMultiSelection()
        scheduleSave()
        return true
    }

    private func removeContentDuplicates(of item: ClipItem, in items: inout [ClipItem]) {
        let key = contentKey(item)
        let duplicates = items.filter { $0.id != item.id && contentKey($0) == key }
        guard !duplicates.isEmpty else { return }
        items.removeAll { $0.id != item.id && contentKey($0) == key }
        for duplicate in duplicates { deleteImageFile(duplicate) }
    }

    private func isWebLink(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(" "), !value.contains("\n"),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    func setTitle(_ title: String, for item: ClipItem) {
        if let i = history.firstIndex(where: { $0.id == item.id }) { history[i].customTitle = title }
        for b in pinboards.indices {
            if let i = pinboards[b].items.firstIndex(where: { $0.id == item.id }) {
                pinboards[b].items[i].customTitle = title
            }
        }
        scheduleSave()
    }

    func selectFirst() { selectedID = visibleItems.first?.id }

    var effectiveSelectionIDs: Set<UUID> {
        if !multiSelectedIDs.isEmpty { return multiSelectedIDs }
        return selectedID.map { [$0] } ?? []
    }

    func isSelected(_ id: UUID) -> Bool {
        if multiSelectedIDs.isEmpty { return selectedID == id }
        return multiSelectedIDs.contains(id)
    }

    func select(_ id: UUID) {
        selectedID = id
        selectionAnchorID = id
        multiSelectedIDs = []
    }

    func toggleSelection(_ id: UUID) {
        guard visibleItems.contains(where: { $0.id == id }) else { return }
        if multiSelectedIDs.isEmpty, let sel = selectedID, sel != id,
           visibleItems.contains(where: { $0.id == sel }) {
            multiSelectedIDs = [sel]
        }
        if multiSelectedIDs.contains(id) {
            multiSelectedIDs.remove(id)
            if selectedID == id { selectedID = multiSelectedIDs.first ?? visibleItems.first?.id }
            if selectionAnchorID == id { selectionAnchorID = selectedID }
            if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        } else {
            multiSelectedIDs.insert(id)
            selectedID = id
            if selectionAnchorID == nil { selectionAnchorID = id }
            if multiSelectedIDs.count == 1 { multiSelectedIDs = [] }
        }
    }

    func extendSelection(to id: UUID) {
        let items = visibleItems
        guard let targetIndex = items.firstIndex(where: { $0.id == id }) else { return }
        guard let anchor = selectionAnchorID ?? selectedID,
              let anchorIndex = items.firstIndex(where: { $0.id == anchor }) else {
            select(id)
            return
        }
        let range = items[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)]
        multiSelectedIDs = Set(range.map(\.id))
        selectedID = id
        selectionAnchorID = anchor
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
    }

    func clearMultiSelection() {
        multiSelectedIDs = []
        selectionAnchorID = selectedID
    }

    private func reconcileMultiSelection() {
        guard !multiSelectedIDs.isEmpty else { return }
        let visible = Set(visibleItems.map(\.id))
        multiSelectedIDs.formIntersection(visible)
        if multiSelectedIDs.count <= 1 { multiSelectedIDs = [] }
        if let anchor = selectionAnchorID, !visible.contains(anchor) {
            selectionAnchorID = selectedID
        }
        if let sel = selectedID, !visible.contains(sel) {
            selectedID = multiSelectedIDs.first ?? visibleItems.first?.id
        }
    }

    func prepareForBarPresentation() {
        applyRetentionPolicy()
        clearMultiSelection()
        barPresentationToken &+= 1
        selectFirst()
    }

    func moveSelection(by delta: Int) {
        clearMultiSelection()
        let items = visibleItems
        guard !items.isEmpty else { return }
        guard let id = selectedID, let idx = items.firstIndex(where: { $0.id == id }) else {
            selectedID = items.first?.id; return
        }
        let next = max(0, min(items.count - 1, idx + delta))
        selectedID = items[next].id
        selectionAnchorID = selectedID
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let name = item.imageFileName,
              name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasSuffix(".png") else { return nil }
        return imagesDir.appendingPathComponent(name)
    }

    /// The path offered to other apps. Previewing and history cleanup continue
    /// to use the private cache; exported screenshots are never pruned by Pesty.
    func imagePathURL(for item: ClipItem) -> URL? {
        guard let source = imageURL(for: item),
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        guard let directory = screenshotDirectory() else {
            screenshotExportError = nil
            return source
        }
        guard allowsScreenshotFolder(directory) else {
            screenshotExportError = "Choose a screenshot folder outside Pesty’s history folder."
            return nil
        }
        do {
            let saved = try ScreenshotFiles.save(source, in: directory)
            screenshotExportError = nil
            return saved
        } catch {
            screenshotExportError = "Could not save to the screenshot folder: \(error.localizedDescription) The image is still in Pesty’s history."
            return nil
        }
    }

    func allowsScreenshotFolder(_ directory: URL) -> Bool {
        guard directory.isFileURL else { return false }
        let chosen = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let history = baseDir.standardizedFileURL.resolvingSymlinksInPath().path
        return chosen != history && !chosen.hasPrefix(history + "/")
    }

    func clearScreenshotExportError() { screenshotExportError = nil }

    func loadImage(for item: ClipItem) -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        return NSImage(contentsOf: url)
    }

    func storeImageData(_ data: Data) -> String? {
        guard canSave, ClipResourceLimits.acceptsImage(data) else { return nil }
        let name = "\(UUID().uuidString).png"
        let url = imagesDir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            imageSizes[name] = data.count
            return name
        } catch { return nil }
    }

    private func duplicateImageFile(_ item: ClipItem) -> String? {
        guard let src = imageURL(for: item), FileManager.default.fileExists(atPath: src.path) else { return nil }
        let name = "\(UUID().uuidString).png"
        let dst = imagesDir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return name
        } catch {
            return nil
        }
    }

    private func deleteImageFile(_ item: ClipItem) {
        guard let name = item.imageFileName else { return }
        let stillUsed = history.contains { $0.imageFileName == name }
            || pinboards.contains { $0.items.contains { $0.imageFileName == name } }
            || undoStack.retainsImageFile(named: name)
        if stillUsed { return }
        pendingImageDeletions.insert(name)
        // Do not delete an image still referenced by the committed JSON or
        // an in-flight write. A crash during the debounce must not break it.
        guard !persistence.retainsImage(named: name), let url = imageURL(for: item) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            imageSizes.removeValue(forKey: name)
            pendingImageDeletions.remove(name)
        } catch { /* Retry after the next successful save. */ }
    }

    private func purgeDeletedImages() {
        for name in pendingImageDeletions {
            deleteImageFile(ClipItem(type: .image, imageFileName: name))
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let size = try storeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ClipResourceLimits.maximumStoreBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
            let data = try Data(contentsOf: storeURL)
            let snapshot = try JSONDecoder().decode(ClipboardSnapshot.self, from: data)
            history = snapshot.history
            pinboards = snapshot.pinboards
            persistence.preserveImages(in: snapshot)
            selectFirst()
        } catch {
            // A failed decode must never turn an existing history into an empty
            // file on the next capture or quit. Leave it available for recovery.
            canSave = false
            persistenceError = "Saved history could not be read. The original file is preserved at \(storeURL.path). Quit Pesty and move that file aside to start fresh."
        }
    }

    private func removeOrphanedImages() {
        let names = Set((history + pinboards.flatMap(\.items)).compactMap(\.imageFileName))
        guard let files = try? FileManager.default.contentsOfDirectory(at: imagesDir,
                                    includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" && !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func scheduleSave() {
        guard canSave else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistence.enqueue(ClipboardSnapshot(history: self.history, pinboards: self.pinboards))
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Used at shutdown and in tests to wait for the newest snapshot on disk.
    func saveNow() {
        guard canSave else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        persistenceError = persistence.flush(ClipboardSnapshot(history: history, pinboards: pinboards))
        if persistenceError == nil {
            purgeDeletedImages()
            NotificationCenter.default.post(name: .pestyStoreDidSave, object: nil)
        }
    }

    private func contentKey(_ item: ClipItem) -> String {
        switch item.type {
        case .image: return "img:" + (item.imageHash ?? item.imageFileName ?? item.id.uuidString)
        case .color: return "col:" + (item.colorHex ?? "")
        case .file:  return "file:" + item.fileURLs.joined(separator: "|")
        default:     return "txt:" + (item.text ?? "")
        }
    }

}
