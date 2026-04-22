import SwiftUI
import AppKit
import Combine
import ApplicationServices
import UniformTypeIdentifiers

private let mainWindowName = "AdvancedTodoMainWindow"
private let mainWindowFrameHistoryKey = "AdvancedTodoMainWindow.CustomFrame"
private let debugWindowTitle = "AdvancedTodo Debug"
private let checkpointBrowserNotification = Notification.Name("AdvancedTodo.OpenCheckpointBrowser")

private func isDebugWindow(_ window: NSWindow) -> Bool {
    window.title == debugWindowTitle
}

private func isMainAppWindow(_ window: NSWindow) -> Bool {
    if isDebugWindow(window) { return false }
    if window.frameAutosaveName == mainWindowName { return true }
    return window.identifier?.rawValue == mainWindowName
}

// MARK: - 1. Data Models & View Model

struct TodoItem: Identifiable, Equatable {
    var id: UUID
    var title: String
    var description: NSAttributedString // Supports rich text & images
    var dueDate: Date
    var isCompleted: Bool = false
    var completionDate: Date? = nil

    init(id: UUID = UUID(), title: String, description: NSAttributedString, dueDate: Date, isCompleted: Bool = false, completionDate: Date? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completionDate = completionDate
    }
}

struct NoteBoard: Identifiable, Equatable {
    var id: UUID
    var name: String
    var noteBody: NSAttributedString

    init(id: UUID = UUID(), name: String, noteBody: NSAttributedString = NSAttributedString(string: "")) {
        self.id = id
        self.name = name
        self.noteBody = noteBody
    }
}

struct TrashedNoteBoard: Identifiable, Equatable {
    var id: UUID
    var board: NoteBoard
    var deletedAt: Date

    init(id: UUID = UUID(), board: NoteBoard, deletedAt: Date = Date()) {
        self.id = id
        self.board = board
        self.deletedAt = deletedAt
    }
}

struct CheckpointRecord: Identifiable {
    var id: UUID
    var url: URL
    var createdAt: Date
    var snapshot: AppSnapshot

    init(url: URL, createdAt: Date, snapshot: AppSnapshot) {
        self.id = UUID()
        self.url = url
        self.createdAt = createdAt
        self.snapshot = snapshot
    }
}

final class TodoManager: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    private let storageURL: URL
    private let historyDirectoryURL: URL
    private let checkpointsDirectoryURL: URL
    private var isRestoring = false
    private var lastHistoryWriteAt = Date.distantPast
    private var checkpointWorkItem: DispatchWorkItem?
    private var didAttemptAccessibilityRepair = false
    private var accessibilityTrustPollTimer: Timer?
    private var didAutoRestartAfterAccessibilityGrant = false
    private let wasAccessibilityTrustedAtLaunch: Bool

    private let checkpointDelay: TimeInterval = 5
    private var lastDistractionPromptAt: Date?
    private var consecutiveShortsStrikes: Int = 0
    private var autoReopenTimer: Timer?
    private var windowClosedAt: Date?

    var todos: [TodoItem] = [] {
        didSet { stateDidChange() }
    }

    var selectedSidebarKey: String? = "todo" {
        didSet { stateDidChange() }
    }

    var noteBoards: [NoteBoard] = [
        NoteBoard(name: "Work"),
        NoteBoard(name: "Personal"),
        NoteBoard(name: "Ideas")
    ] {
        didSet { stateDidChange() }
    }

    var trashedNoteBoards: [TrashedNoteBoard] = [] {
        didSet { stateDidChange() }
    }

    var scrollAnchorTodoID: UUID? = nil {
        didSet { stateDidChange() }
    }

    var debugModeEnabled: Bool = false {
        didSet { stateDidChange() }
    }

    var blockerSettings: BlockerSettings = .default() {
        didSet { stateDidChange() }
    }

    var latestDetectedDistraction: String? = nil {
        didSet {
            if oldValue != latestDetectedDistraction {
                objectWillChange.send()
            }
        }
    }

    var blockerPromptNonce: Int = 0 {
        didSet {
            if oldValue != blockerPromptNonce {
                objectWillChange.send()
            }
        }
    }

    /// Incremented each time a tab is auto-closed. UI observes this to show brief feedback.
    var tabAutoClosedNonce: Int = 0 {
        didSet {
            if oldValue != tabAutoClosedNonce {
                objectWillChange.send()
            }
        }
    }

    /// Name of the last auto-closed distraction (e.g. "YouTube Shorts").
    var lastAutoClosedDistraction: String = "" {
        didSet {
            if oldValue != lastAutoClosedDistraction {
                objectWillChange.send()
            }
        }
    }

    var debugWindowSizeText: String = "" {
        didSet {
            if oldValue != debugWindowSizeText {
                objectWillChange.send()
            }
        }
    }

    var debugSidebarSizeText: String = "" {
        didSet {
            if oldValue != debugSidebarSizeText {
                objectWillChange.send()
            }
        }
    }

    var debugDetailSizeText: String = "" {
        didSet {
            if oldValue != debugDetailSizeText {
                objectWillChange.send()
            }
        }
    }

    init() {
        wasAccessibilityTrustedAtLaunch = AXIsProcessTrusted()

        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let directory = applicationSupport.appendingPathComponent("AdvancedTodo", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("state.json")
        historyDirectoryURL = directory.appendingPathComponent("state-history", isDirectory: true)
        checkpointsDirectoryURL = directory.appendingPathComponent("checkpoints", isDirectory: true)
        try? fileManager.createDirectory(at: historyDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: checkpointsDirectoryURL, withIntermediateDirectories: true)
        loadState()
        startWorkspaceObservation()
        
        // Auto-sync and prompt for accessibility permission on startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestAccessibilityPermissionIfNeeded()
            self?.syncAccessibilityPermission()
        }
    }

    var sortedTodos: [TodoItem] {
        todos.sorted { task1, task2 in
            if task1.isCompleted == task2.isCompleted {
                if task1.isCompleted {
                    return (task1.completionDate ?? Date.distantPast) > (task2.completionDate ?? Date.distantPast)
                }
                return task1.dueDate < task2.dueDate
            }
            return !task1.isCompleted && task2.isCompleted
        }
    }

    func add(todo: TodoItem) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            todos.append(todo)
        }
    }

    func toggleCompletion(for id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            todos[index].isCompleted.toggle()
            todos[index].completionDate = todos[index].isCompleted ? Date() : nil
        }
    }

    func update(todo: TodoItem) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        withAnimation {
            todos[index] = todo
        }
    }

    func delete(id: UUID) {
        guard let index = todos.firstIndex(where: { $0.id == id }) else { return }
        _ = withAnimation {
            todos.remove(at: index)
        }
    }

    func restoreScrollAnchorIfNeeded(_ targetID: UUID?) {
        guard scrollAnchorTodoID != targetID else { return }
        scrollAnchorTodoID = targetID
    }

    func selectBoard(_ boardID: UUID) {
        selectedSidebarKey = "board:\(boardID.uuidString)"
    }

    func selectedBoard() -> NoteBoard? {
        guard let key = selectedSidebarKey, key.hasPrefix("board:") else { return nil }
        let idString = String(key.dropFirst("board:".count))
        guard let id = UUID(uuidString: idString) else { return nil }
        return noteBoards.first(where: { $0.id == id })
    }

    func addBoard(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = cleanName.isEmpty ? "Untitled" : cleanName
        let board = NoteBoard(name: resolvedName)
        noteBoards.append(board)
        selectBoard(board.id)
    }

    func deleteBoard(_ boardID: UUID) {
        guard let index = noteBoards.firstIndex(where: { $0.id == boardID }) else { return }
        let board = noteBoards.remove(at: index)
        trashedNoteBoards.insert(TrashedNoteBoard(board: board), at: 0)
        if selectedSidebarKey == "board:\(boardID.uuidString)" {
            selectedSidebarKey = "todo"
        }
    }

    func restoreBoardFromTrash(_ trashID: UUID) {
        guard let index = trashedNoteBoards.firstIndex(where: { $0.id == trashID }) else { return }
        var restored = trashedNoteBoards.remove(at: index).board
        if noteBoards.contains(where: { $0.id == restored.id }) {
            restored.id = UUID()
        }
        restored.name = uniqueBoardName(restored.name)
        noteBoards.append(restored)
        selectBoard(restored.id)
    }

    func restoreBoardFromTrashAsCopy(_ trashID: UUID) {
        guard let item = trashedNoteBoards.first(where: { $0.id == trashID }) else { return }
        var copy = item.board
        copy.id = UUID()
        copy.name = uniqueBoardName(copy.name)
        noteBoards.append(copy)
        selectBoard(copy.id)
    }

    func permanentlyDeleteBoardFromTrash(_ trashID: UUID) {
        guard let index = trashedNoteBoards.firstIndex(where: { $0.id == trashID }) else { return }
        trashedNoteBoards.remove(at: index)
    }

    func emptyTrash() {
        trashedNoteBoards.removeAll()
    }

    func renameBoard(_ boardID: UUID, to newName: String) {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard let index = noteBoards.firstIndex(where: { $0.id == boardID }) else { return }
        noteBoards[index].name = cleaned
    }

    func moveBoards(fromOffsets: IndexSet, toOffset: Int) {
        noteBoards.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveBoard(from sourceID: UUID, before targetID: UUID) {
        guard sourceID != targetID,
              let sourceIndex = noteBoards.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = noteBoards.firstIndex(where: { $0.id == targetID }) else { return }

        var updated = noteBoards
        let source = updated.remove(at: sourceIndex)
        let insertionIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        updated.insert(source, at: insertionIndex)
        noteBoards = updated
    }

    func updateBoardName(_ boardID: UUID, name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        guard let index = noteBoards.firstIndex(where: { $0.id == boardID }) else { return }
        noteBoards[index].name = cleaned
    }

    func exportPackage(for sidebarKey: String) -> SidebarExportPackage? {
        if sidebarKey == "todo" {
            return SidebarExportPackage(
                sourceSidebarKey: "todo",
                displayName: "Todo",
                todos: todos.map(StoredTodo.init(todo:)),
                noteBoard: nil
            )
        }

        guard sidebarKey.hasPrefix("board:"),
              let boardID = UUID(uuidString: String(sidebarKey.dropFirst("board:".count))),
              let board = noteBoards.first(where: { $0.id == boardID }) else {
            return nil
        }

        return SidebarExportPackage(
            sourceSidebarKey: sidebarKey,
            displayName: board.name,
            todos: nil,
            noteBoard: StoredNoteBoard(board: board)
        )
    }

    func applyImportedPackage(_ package: SidebarExportPackage, mode: ImportMode, targetSidebarKey: String?) {
        if let importedTodos = package.todos {
            applyImportedTodos(importedTodos, mode: mode)
            return
        }

        guard let importedBoard = package.noteBoard else { return }
        applyImportedBoard(importedBoard.makeBoard(), mode: mode, targetSidebarKey: targetSidebarKey)
    }

    private func applyImportedTodos(_ imported: [StoredTodo], mode: ImportMode) {
        let mapped = imported.map { item -> TodoItem in
            var todo = item.makeTodo()
            if todos.contains(where: { $0.id == todo.id }) {
                todo.id = UUID()
            }
            return todo
        }

        switch mode {
        case .replace:
            todos = mapped
        case .merge, .create:
            todos.append(contentsOf: mapped)
        }
    }

    private func applyImportedBoard(_ importedBoard: NoteBoard, mode: ImportMode, targetSidebarKey: String?) {
        let targetBoardID: UUID? = {
            guard let key = targetSidebarKey, key.hasPrefix("board:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("board:".count)))
        }()

        switch mode {
        case .create:
            var newBoard = importedBoard
            newBoard.id = UUID()
            newBoard.name = uniqueBoardName(newBoard.name)
            noteBoards.append(newBoard)
            selectedSidebarKey = "board:\(newBoard.id.uuidString)"

        case .replace:
            guard let targetBoardID,
                  let index = noteBoards.firstIndex(where: { $0.id == targetBoardID }) else {
                var newBoard = importedBoard
                newBoard.id = UUID()
                newBoard.name = uniqueBoardName(newBoard.name)
                noteBoards.append(newBoard)
                selectedSidebarKey = "board:\(newBoard.id.uuidString)"
                return
            }
            var replacement = importedBoard
            replacement.id = targetBoardID
            noteBoards[index] = replacement
            selectedSidebarKey = "board:\(targetBoardID.uuidString)"

        case .merge:
            guard let targetBoardID,
                  let index = noteBoards.firstIndex(where: { $0.id == targetBoardID }) else {
                var newBoard = importedBoard
                newBoard.id = UUID()
                newBoard.name = uniqueBoardName(newBoard.name)
                noteBoards.append(newBoard)
                selectedSidebarKey = "board:\(newBoard.id.uuidString)"
                return
            }

            var merged = noteBoards[index]
            if merged.noteBody.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                merged.noteBody = importedBoard.noteBody
            } else if !importedBoard.noteBody.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let mergedText = NSMutableAttributedString(attributedString: merged.noteBody)
                mergedText.append(NSAttributedString(string: "\n\n--- Imported Content ---\n\n"))
                mergedText.append(importedBoard.noteBody)
                merged.noteBody = mergedText
            }
            noteBoards[index] = merged
            selectedSidebarKey = "board:\(targetBoardID.uuidString)"
        }
    }

    private func uniqueBoardName(_ base: String) -> String {
        let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = cleaned.isEmpty ? "Imported" : cleaned
        if !noteBoards.contains(where: { $0.name.caseInsensitiveCompare(seed) == .orderedSame }) {
            return seed
        }

        var counter = 2
        while true {
            let candidate = "\(seed) \(counter)"
            if !noteBoards.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
            counter += 1
        }
    }

    func updateBoardBody(_ boardID: UUID, body: NSAttributedString) {
        guard let index = noteBoards.firstIndex(where: { $0.id == boardID }) else { return }
        noteBoards[index].noteBody = body
    }

    func updateDebugWindowSize(_ size: CGSize) {
        debugWindowSizeText = "Window: \(Int(size.width)) x \(Int(size.height))"
    }

    func updateDebugSidebarSize(_ size: CGSize) {
        debugSidebarSizeText = "Sidebar: \(Int(size.width)) x \(Int(size.height))"
    }

    func updateDebugDetailSize(_ size: CGSize) {
        debugDetailSizeText = "Detail: \(Int(size.width)) x \(Int(size.height))"
    }

    private func stateDidChange() {
        guard !isRestoring else { return }
        objectWillChange.send()
        saveState()
        scheduleCheckpointWrite()
    }

    private func defaultBoards() -> [NoteBoard] {
        [
            NoteBoard(name: "Work"),
            NoteBoard(name: "Personal"),
            NoteBoard(name: "Ideas")
        ]
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        guard let snapshot = try? JSONDecoder().decode(AppSnapshot.self, from: data) else { return }

        applySnapshot(snapshot)
    }

    private func applySnapshot(_ snapshot: AppSnapshot) {

        isRestoring = true
        todos = snapshot.todos.map { $0.makeTodo() }
        noteBoards = snapshot.noteBoards?.map { $0.makeBoard() } ?? defaultBoards()
        trashedNoteBoards = snapshot.trashedNoteBoards?.map { $0.makeItem() } ?? []

        let legacyCategory = snapshot.selectedCategory
        if let selected = snapshot.selectedSidebarKey {
            selectedSidebarKey = selected
        } else if legacyCategory == "All" || legacyCategory == "Todo" || legacyCategory == "todo" {
            selectedSidebarKey = "todo"
        } else if let matched = noteBoards.first(where: { $0.name == legacyCategory }) {
            selectedSidebarKey = "board:\(matched.id.uuidString)"
        } else {
            selectedSidebarKey = "todo"
        }

        if selectedBoard() == nil && selectedSidebarKey != "todo" && selectedSidebarKey != "trash" {
            selectedSidebarKey = "todo"
        }

        scrollAnchorTodoID = snapshot.scrollAnchorTodoID
        debugModeEnabled = snapshot.debugModeEnabled ?? false
        blockerSettings = snapshot.blockerSettings ?? .default()
        isRestoring = false
    }

    private func saveState() {
        let snapshot = buildSnapshot()

        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        if let previousData = try? Data(contentsOf: storageURL) {
            let previousURL = storageURL.deletingLastPathComponent().appendingPathComponent("state.previous.json")
            try? previousData.write(to: previousURL, options: [.atomic])
        }

        try? data.write(to: storageURL, options: [.atomic])
        writeHistorySnapshotIfNeeded(data)
    }

    private func buildSnapshot() -> AppSnapshot {
        AppSnapshot(
            todos: todos.map(StoredTodo.init(todo:)),
            selectedCategory: selectedSidebarKey ?? "todo",
            scrollAnchorTodoID: scrollAnchorTodoID,
            mainWindowFrame: nil,
            selectedSidebarKey: selectedSidebarKey,
            noteBoards: noteBoards.map(StoredNoteBoard.init(board:)),
            trashedNoteBoards: trashedNoteBoards.map(StoredTrashedNoteBoard.init(item:)),
            blockerSettings: blockerSettings,
            debugModeEnabled: debugModeEnabled
        )
    }

    private func writeHistorySnapshotIfNeeded(_ data: Data) {
        let now = Date()
        guard now.timeIntervalSince(lastHistoryWriteAt) >= 15 else { return }
        lastHistoryWriteAt = now

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let historyFile = historyDirectoryURL.appendingPathComponent("state-\(timestamp).json")
        try? data.write(to: historyFile, options: [.atomic])

        let fileManager = FileManager.default
        let snapshots = (try? fileManager.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sorted = snapshots.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }

        if sorted.count > 40 {
            for url in sorted.dropFirst(40) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func forcePersistState() {
        saveState()
    }

    func currentSnapshot() -> AppSnapshot {
        buildSnapshot()
    }

    func setBlockerPermissionGranted(_ granted: Bool) {
        blockerSettings.appMonitoringPermissionGranted = granted
    }

    func setAccessibilityPermissionGranted(_ granted: Bool) {
        blockerSettings.accessibilityPermissionGranted = granted
    }

    /// Triggers the official macOS accessibility trust prompt when needed.
    /// This cannot auto-grant permission; users must approve it in System Settings.
    func requestAccessibilityPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else {
            blockerSettings.accessibilityPermissionGranted = true
            accessibilityTrustPollTimer?.invalidate()
            accessibilityTrustPollTimer = nil
            return
        }

        // If state says we were previously granted but trust is now missing,
        // repair stale TCC registration before showing the prompt again.
        repairStaleAccessibilityRegistrationIfNeeded()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trustedNow = AXIsProcessTrustedWithOptions(options)
        blockerSettings.accessibilityPermissionGranted = trustedNow
        startAccessibilityTrustPolling()

        if debugModeEnabled {
            print("[Blocker] Requested accessibility permission prompt. Trusted now: \(trustedNow)")
        }
    }

    private func startAccessibilityTrustPolling() {
        accessibilityTrustPollTimer?.invalidate()
        var remainingChecks = 120
        accessibilityTrustPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let trusted = AXIsProcessTrusted()
            let previouslyGranted = self.blockerSettings.accessibilityPermissionGranted
            if self.blockerSettings.accessibilityPermissionGranted != trusted {
                self.blockerSettings.accessibilityPermissionGranted = trusted
                if self.debugModeEnabled {
                    print("[Blocker] Accessibility trust poll update: \(trusted)")
                }
            }
            self.maybeAutoRestartAfterAccessibilityGrant(previouslyGranted: previouslyGranted, nowGranted: trusted)

            remainingChecks -= 1
            if trusted || remainingChecks <= 0 {
                timer.invalidate()
                self.accessibilityTrustPollTimer = nil
            }
        }
    }

    /// Best-effort cleanup for stale Accessibility entries left by old app builds.
    /// Uses `tccutil reset Accessibility <bundle-id>` once per launch.
    private func repairStaleAccessibilityRegistrationIfNeeded() {
        guard !didAttemptAccessibilityRepair else { return }
        didAttemptAccessibilityRepair = true

        guard !AXIsProcessTrusted(),
              let bundleID = Bundle.main.bundleIdentifier,
              !bundleID.isEmpty else {
            return
        }

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            if debugModeEnabled {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                print("[Blocker] Ran tccutil reset for Accessibility (\(bundleID)). Exit code: \(process.terminationStatus)")
                if !stderrText.isEmpty {
                    print("[Blocker] tccutil stderr: \(stderrText)")
                }
            }
        } catch {
            if debugModeEnabled {
                print("[Blocker] Failed to run tccutil reset for Accessibility: \(error.localizedDescription)")
            }
        }
    }
    
    /// Syncs the accessibility permission state with the actual system state.
    /// Call this on startup and after the user returns from System Settings.
    func syncAccessibilityPermission() {
        let actuallyGranted = AXIsProcessTrusted()
        let previouslyGranted = blockerSettings.accessibilityPermissionGranted
        if blockerSettings.accessibilityPermissionGranted != actuallyGranted {
            blockerSettings.accessibilityPermissionGranted = actuallyGranted
            if debugModeEnabled {
                print("[Blocker] Auto-synced accessibility permission: \(actuallyGranted)")
            }
        }
        maybeAutoRestartAfterAccessibilityGrant(previouslyGranted: previouslyGranted, nowGranted: actuallyGranted)
    }

    private func maybeAutoRestartAfterAccessibilityGrant(previouslyGranted: Bool, nowGranted: Bool) {
        guard !didAutoRestartAfterAccessibilityGrant,
              !wasAccessibilityTrustedAtLaunch,
              !previouslyGranted,
              nowGranted else {
            return
        }

        didAutoRestartAfterAccessibilityGrant = true
        if debugModeEnabled {
            print("[Blocker] Accessibility permission granted. Restarting app to apply permission-dependent behavior.")
        }

        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
        }
    }

    func addBlockedApp(_ app: String) {
        let cleaned = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !blockerSettings.blockedApps.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            blockerSettings.blockedApps.append(cleaned)
        }
    }

    func removeBlockedApp(at offsets: IndexSet) {
        blockerSettings.blockedApps.remove(atOffsets: offsets)
    }

    func addBlockedWebsite(_ website: String) {
        let cleaned = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !blockerSettings.blockedWebsites.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            blockerSettings.blockedWebsites.append(cleaned)
        }
    }

    func removeBlockedWebsite(at offsets: IndexSet) {
        blockerSettings.blockedWebsites.remove(atOffsets: offsets)
    }

    func addBlockedKeyword(_ keyword: String) {
        let cleaned = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !blockerSettings.blockedKeywords.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            blockerSettings.blockedKeywords.append(cleaned)
        }
    }

    func removeBlockedKeyword(at offsets: IndexSet) {
        blockerSettings.blockedKeywords.remove(atOffsets: offsets)
    }

    func addMotivationPhrase(_ phrase: String) {
        let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        blockerSettings.motivationalPhrases.append(cleaned)
    }

    func removeMotivationPhrase(at offsets: IndexSet) {
        blockerSettings.motivationalPhrases.remove(atOffsets: offsets)
    }

    func evaluateDistraction() {
        guard blockerSettings.isEnabled, blockerSettings.appMonitoringPermissionGranted else {
            latestDetectedDistraction = nil
            consecutiveShortsStrikes = 0
            return
        }

        guard let activeApp = NSWorkspace.shared.frontmostApplication else {
            latestDetectedDistraction = nil
            consecutiveShortsStrikes = 0
            return
        }

        // Skip our own app
        if activeApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            latestDetectedDistraction = nil
            return
        }

        let appName = (activeApp.localizedName ?? "").lowercased()
        let bundleID = (activeApp.bundleIdentifier ?? "").lowercased()

        if debugModeEnabled {
            print("[Blocker] Checking app: \(appName) (\(bundleID))")
        }

        // ── Layer 1: App name / bundle ID match ──────────────────────────────
        // App-level distractions (Discord, Steam, etc.) are not browser tabs —
        // we show the prompt but never auto-close them.
        if let match = blockerSettings.blockedApps.first(where: { blocked in
            let needle = blocked.lowercased()
            return appName.contains(needle) || bundleID.contains(needle)
        }) {
            latestDetectedDistraction = match
            consecutiveShortsStrikes = 0
            if debugModeEnabled {
                print("[Blocker] Layer 1 match (app): \(match)")
            }
            triggerPromptIfNeeded()
            return
        }

        if let match = blockerSettings.blockedKeywords.first(where: { keyword in
            appName.contains(keyword.lowercased()) || bundleID.contains(keyword.lowercased())
        }) {
            latestDetectedDistraction = match
            consecutiveShortsStrikes = 0
            if debugModeEnabled {
                print("[Blocker] Layer 1 match (keyword): \(match)")
            }
            triggerPromptIfNeeded()
            return
        }

        // ── Layer 2: Window titles via CGWindowList (no extra permission) ─────
        // This catches browser tabs showing distracting content.
        let isBrowser = DistractionDetector.isBrowserBundleID(bundleID)
        if debugModeEnabled {
            print("[Blocker] Is browser: \(isBrowser)")
        }
        if let windowMatch = DistractionDetector.checkWindowTitles(
            for: activeApp.processIdentifier,
            blockedWebsites: blockerSettings.blockedWebsites,
            blockedKeywords: blockerSettings.blockedKeywords,
            blockYouTubeVideos: blockerSettings.blockYouTubeVideos,
            isBrowser: isBrowser,
            debugMode: debugModeEnabled
        ) {
            latestDetectedDistraction = windowMatch
            if debugModeEnabled {
                print("[Blocker] Layer 2 match (window title): \(windowMatch)")
            }
            handleShortsStrike(match: windowMatch, pid: activeApp.processIdentifier)
            return
        }

        // ── Layer 3: AXUIElement focused window title (needs Accessibility) ───
        if blockerSettings.accessibilityPermissionGranted, AXIsProcessTrusted() {
            if let axMatch = DistractionDetector.checkAXWindowTitle(
                for: activeApp.processIdentifier,
                blockedWebsites: blockerSettings.blockedWebsites,
                blockedKeywords: blockerSettings.blockedKeywords,
                blockYouTubeVideos: blockerSettings.blockYouTubeVideos,
                debugMode: debugModeEnabled
            ) {
                latestDetectedDistraction = axMatch
                if debugModeEnabled {
                    print("[Blocker] Layer 3 match (AX title): \(axMatch)")
                }
                handleShortsStrike(match: axMatch, pid: activeApp.processIdentifier)
                return
            }
        } else if debugModeEnabled {
            print("[Blocker] Layer 3 skipped (accessibility not granted or not trusted)")
        }

        // Clean — reset strike counter
        if debugModeEnabled && latestDetectedDistraction != nil {
            print("[Blocker] No distraction detected, clearing state")
        }
        latestDetectedDistraction = nil
        consecutiveShortsStrikes = 0
    }

    /// Tracks consecutive "shorts-type" detections and auto-closes the tab on strike 2.
    private func handleShortsStrike(match: String, pid: pid_t) {
        let isShorts = DistractionDetector.isShortsTypeDistraction(match)

        if isShorts {
            consecutiveShortsStrikes += 1
            if consecutiveShortsStrikes >= 2 {
                consecutiveShortsStrikes = 0
                // Auto-close only if the user has enabled it AND accessibility is granted
                if blockerSettings.autoCloseTabsOnSecondStrike,
                   blockerSettings.accessibilityPermissionGranted,
                   AXIsProcessTrusted() {
                    DistractionDetector.closeDistractionTab(pid: pid)
                    lastAutoClosedDistraction = match
                    tabAutoClosedNonce += 1
                }
            }
        } else {
            consecutiveShortsStrikes = 0
        }

        triggerPromptIfNeeded()
    }

    private func triggerPromptIfNeeded() {
        let now = Date()
        let interval = TimeInterval(blockerSettings.blockDurationSeconds)
        if let last = lastDistractionPromptAt, now.timeIntervalSince(last) < interval {
            if debugModeEnabled {
                print("[Blocker] Prompt cooldown active. \(Int(interval - now.timeIntervalSince(last)))s remaining")
            }
            return
        }
        lastDistractionPromptAt = now
        blockerPromptNonce += 1
        if debugModeEnabled {
            print("[Blocker] Triggering prompt. Distraction: \(latestDetectedDistraction ?? "none")")
        }
    }

    /// Subscribe to workspace notifications so detection fires instantly on app switch,
    /// not just on the 6-second poll.
    func startWorkspaceObservation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceAppDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func workspaceAppDidActivate(_ notification: Notification) {
        evaluateDistraction()
    }
    
    /// Handles window close/minimize attempts with confirmation dialog
    func handleWindowCloseAttempt() -> Bool {
        guard blockerSettings.preventWindowClose else { return true }
        
        let alert = NSAlert()
        alert.messageText = "Close Todo Window?"
        alert.informativeText = "Are you sure you want to close the todo window? This might reduce your productivity focus."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Keep Open")
        
        if blockerSettings.autoReopenEnabled {
            alert.addButton(withTitle: "Close & Auto-Reopen")
        }
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn: // Close Anyway
            return true
            
        case .alertThirdButtonReturn: // Close & Auto-Reopen (if enabled)
            if blockerSettings.autoReopenEnabled {
                scheduleAutoReopen()
                return true
            }
            return false
            
        default: // Keep Open
            return false
        }
    }
    
    /// Schedules the window to reopen after the configured delay
    private func scheduleAutoReopen() {
        windowClosedAt = Date()
        let interval = TimeInterval(blockerSettings.autoReopenMinutes * 60)
        
        autoReopenTimer?.invalidate()
        autoReopenTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.reopenWindow()
        }
        
        if debugModeEnabled {
            print("[WindowManager] Scheduled auto-reopen in \(blockerSettings.autoReopenMinutes) minutes")
        }
    }
    
    /// Reopens the main window
    private func reopenWindow() {
        DispatchQueue.main.async {
            // Find and show the main window
            for window in NSApplication.shared.windows {
                if isMainAppWindow(window) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    break
                }
            }
            
            if self.debugModeEnabled {
                print("[WindowManager] Auto-reopened window")
            }
        }
        
        autoReopenTimer = nil
        windowClosedAt = nil
    }
    
    /// Cancels any pending auto-reopen
    func cancelAutoReopen() {
        autoReopenTimer?.invalidate()
        autoReopenTimer = nil
        windowClosedAt = nil
    }

    func scheduleCheckpointWrite() {
        checkpointWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.createCheckpointNow()
        }
        checkpointWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + checkpointDelay, execute: work)
    }

    func createCheckpointNow() {
        checkpointWorkItem?.cancel()
        checkpointWorkItem = nil

        let snapshot = buildSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = checkpointsDirectoryURL.appendingPathComponent("checkpoint-\(timestamp).json")
        try? data.write(to: url, options: [.atomic])
        trimCheckpointHistory(maxCount: 200)
    }

    private func trimCheckpointHistory(maxCount: Int) {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: checkpointsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sorted = urls.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate > rDate
        }

        for url in sorted.dropFirst(maxCount) {
            try? fileManager.removeItem(at: url)
        }
    }

    func loadCheckpointRecords() -> [CheckpointRecord] {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: checkpointsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let decoder = JSONDecoder()
        let records = urls.compactMap { url -> CheckpointRecord? in
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(AppSnapshot.self, from: data) else {
                return nil
            }

            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return CheckpointRecord(url: url, createdAt: date, snapshot: snapshot)
        }

        return records.sorted { $0.createdAt > $1.createdAt }
    }

    func restoreCheckpoint(_ record: CheckpointRecord) {
        applySnapshot(record.snapshot)
        saveState()
    }

    func revealCheckpointFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([checkpointsDirectoryURL])
    }

    func revealCheckpointFile(_ record: CheckpointRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.url])
    }
}

// MARK: - 1b. Distraction Detection Engine

/// Pure-function helpers for detecting distracting content.
/// Three layers: app identity → CGWindow titles → AXUIElement title.
enum DistractionDetector {

    // Known browser bundle ID fragments
    static let browserBundleFragments: [String] = [
        "safari", "chrome", "firefox", "arc", "edge", "brave", "opera",
        "vivaldi", "webkit", "browser", "chromium", "waterfox", "librewolf",
        "tor browser", "orion"
    ]

    static func isBrowserBundleID(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return browserBundleFragments.contains(where: { lower.contains($0) })
    }

    // ── Layer 2: CGWindowListCopyWindowInfo ───────────────────────────────────
    // Works without any special permission on non-sandboxed apps.
    // Returns the first matching blocked reason string, or nil if clean.
    static func checkWindowTitles(
        for pid: pid_t,
        blockedWebsites: [String],
        blockedKeywords: [String],
        blockYouTubeVideos: Bool,
        isBrowser: Bool,
        debugMode: Bool = false
    ) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            // Filter to windows owned by this process
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid else { continue }

            let rawTitle = (window[kCGWindowName as String] as? String) ?? ""
            let title = rawTitle.lowercased()
            guard !title.isEmpty else { continue }

            if debugMode {
                print("[Blocker] Layer 2 checking window: \(rawTitle)")
            }

            if let match = matchTitle(title, blockedWebsites: blockedWebsites, blockedKeywords: blockedKeywords, blockYouTubeVideos: blockYouTubeVideos) {
                return match
            }
        }
        return nil
    }

    // ── Layer 3: AXUIElement focused window title ─────────────────────────────
    // More reliable for the exact active tab. Requires Accessibility permission.
    static func checkAXWindowTitle(
        for pid: pid_t,
        blockedWebsites: [String],
        blockedKeywords: [String],
        blockYouTubeVideos: Bool,
        debugMode: Bool = false
    ) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let windowElement = focusedWindow else { return nil }

        var titleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let rawTitle = titleValue as? String else { return nil }

        if debugMode {
            print("[Blocker] Layer 3 checking AX window: \(rawTitle)")
        }

        let title = rawTitle.lowercased()
        return matchTitle(title, blockedWebsites: blockedWebsites, blockedKeywords: blockedKeywords, blockYouTubeVideos: blockYouTubeVideos)
    }

    // ── Shared matching logic ─────────────────────────────────────────────────
    static func matchTitle(
        _ title: String,
        blockedWebsites: [String],
        blockedKeywords: [String],
        blockYouTubeVideos: Bool
    ) -> String? {
        // YouTube Shorts — always blocked
        if title.contains("shorts") && (title.contains("youtube") || title.contains("yt")) {
            return "YouTube Shorts"
        }

        // YouTube videos (configurable)
        if blockYouTubeVideos && title.contains("youtube") && !title.contains("youtube music") {
            return "YouTube"
        }

        // Blocked websites — match domain fragments against window title
        for site in blockedWebsites {
            let needle = site.lowercased()
                .replacingOccurrences(of: "www.", with: "")
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            // Extract the base domain name for matching (e.g. "instagram.com" → "instagram")
            let baseName = needle.components(separatedBy: ".").first ?? needle
            if title.contains(baseName) || title.contains(needle) {
                return site
            }
        }

        // Blocked keywords
        for keyword in blockedKeywords {
            if title.contains(keyword.lowercased()) {
                return keyword
            }
        }

        return nil
    }

    // ── Shorts-type classification ────────────────────────────────────────────
    // Returns true for browser-tab distractions that can be safely closed
    // (short-form video, social feeds). Returns false for app-level distractions
    // like Discord or Steam that should never be force-closed.
    static func isShortsTypeDistraction(_ match: String) -> Bool {
        let lower = match.lowercased()
        let shortsPatterns = [
            "youtube shorts",
            "tiktok", "instagram", "reels",
            "twitter", "x.com", "reddit",
            "facebook", "snapchat", "threads",
            "twitch", "netflix", "primevideo",
            "disneyplus", "hulu", "9gag",
            "tumblr", "shorts"
        ]
        return shortsPatterns.contains(where: { lower.contains($0) })
    }

    // ── Auto-close the distracting browser tab ────────────────────────────────
    // Sends Cmd+W to the focused window of the given process via AXUIElement.
    // This closes the active tab in any browser without closing the whole app.
    // Requires Accessibility permission (AXIsProcessTrusted() == true).
    static func closeDistractionTab(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused window
        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let windowElement = focusedWindow else { return }

        // Verify the window title is still a shorts-type distraction before closing
        var titleValue: AnyObject?
        if AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
           let title = titleValue as? String {
            guard isShortsTypeDistraction(title.lowercased()) else { return }
        }

        // Post Cmd+W key event to the process to close the tab
        let cmdW = CGEvent(keyboardEventSource: nil, virtualKey: 0x0D, keyDown: true)
        cmdW?.flags = .maskCommand
        cmdW?.postToPid(pid)

        let cmdWUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x0D, keyDown: false)
        cmdWUp?.flags = .maskCommand
        cmdWUp?.postToPid(pid)
    }
}

// MARK: - 2. Native Rich Text Editor (Supports Images & Cmd+B, Cmd+I)

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    var backgroundColor: NSColor = .textBackgroundColor
    var drawsBorder: Bool = true

    static func toggleBold(in textView: NSTextView?) {
        applyTrait(.boldFontMask, to: textView)
    }

    static func toggleItalic(in textView: NSTextView?) {
        applyTrait(.italicFontMask, to: textView)
    }

    private static func applyTrait(_ trait: NSFontTraitMask, to textView: NSTextView?) {
        guard let textView else { return }

        let fontManager = NSFontManager.shared
        let storage = textView.textStorage
        let selectedRange = textView.selectedRange()
        let targetRange = selectedRange.length > 0 ? selectedRange : NSRange(location: 0, length: storage?.length ?? 0)

        let anchorFont: NSFont = {
            if selectedRange.length > 0,
               let storage,
               storage.length > 0,
               selectedRange.location < storage.length,
               let selectedFont = storage.attribute(.font, at: selectedRange.location, effectiveRange: nil) as? NSFont {
                return selectedFont
            }
            if let typingFont = textView.typingAttributes[.font] as? NSFont {
                return typingFont
            }
            return textView.font ?? NSFont.systemFont(ofSize: 14)
        }()
        let shouldRemoveTrait = fontManager.traits(of: anchorFont).contains(trait)

        if let storage, targetRange.length > 0 {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: targetRange, options: []) { value, range, _ in
                let baseFont = (value as? NSFont) ?? textView.font ?? NSFont.systemFont(ofSize: 14)
                let convertedFont = shouldRemoveTrait
                    ? fontManager.convert(baseFont, toNotHaveTrait: trait)
                    : fontManager.convert(baseFont, toHaveTrait: trait)
                storage.addAttribute(.font, value: convertedFont, range: range)
            }
            storage.endEditing()
        } else {
            let baseFont = (textView.typingAttributes[.font] as? NSFont) ?? textView.font ?? NSFont.systemFont(ofSize: 14)
            let convertedFont = shouldRemoveTrait
                ? fontManager.convert(baseFont, toNotHaveTrait: trait)
                : fontManager.convert(baseFont, toHaveTrait: trait)
            textView.typingAttributes[.font] = convertedFont
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        context.coordinator.bind(textView: textView)

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.usesFontPanel = true
        textView.isAutomaticTextCompletionEnabled = true
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.backgroundColor = backgroundColor
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = drawsBorder ? .bezelBorder : .noBorder

        // Provide native rich-text actions in contextual menu.
        let menu = NSMenu(title: "Text")
        let bold = NSMenuItem(title: "Bold", action: Selector(("toggleBoldface:")), keyEquivalent: "")
        bold.target = textView
        menu.addItem(bold)

        let italic = NSMenuItem(title: "Italic", action: Selector(("toggleItalics:")), keyEquivalent: "")
        italic.target = textView
        menu.addItem(italic)

        menu.addItem(.separator())

        let fonts = NSMenuItem(title: "Show Fonts", action: #selector(NSFontManager.orderFrontFontPanel(_:)), keyEquivalent: "")
        fonts.target = NSFontManager.shared
        menu.addItem(fonts)

        let colors = NSMenuItem(title: "Show Colors", action: #selector(NSApplication.orderFrontColorPanel(_:)), keyEquivalent: "")
        colors.target = NSApp
        menu.addItem(colors)

        textView.menu = menu

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.attributedString() != text {
            textView.textStorage?.setAttributedString(text)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        private var keyMonitor: Any?

        init(_ parent: RichTextEditor) { self.parent = parent }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }

        func bind(textView: NSTextView) {
            self.textView = textView
            guard keyMonitor == nil else { return }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let activeTextView = self.textView,
                      activeTextView.window != nil,
                      activeTextView.window?.firstResponder === activeTextView else {
                    return event
                }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "b" {
                    RichTextEditor.toggleBold(in: activeTextView)
                    self.parent.text = activeTextView.attributedString()
                    return nil
                }

                if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "i" {
                    RichTextEditor.toggleItalic(in: activeTextView)
                    self.parent.text = activeTextView.attributedString()
                    return nil
                }

                return event
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.attributedString()
        }
    }
}

// MARK: - 3. Main App UI & Layout

@main
struct AdvancedTodoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject var todoManager = TodoManager()
    @StateObject var updater = UpdateManager()
    @State private var didConfigureMainWindow = false
    @State private var didAutoCheckUpdatesOnLaunch = false
    @State private var windowDelegate: WindowCloseDelegate?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(todoManager)
                .environmentObject(updater)
                .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
                .onAppear {
                    if !didConfigureMainWindow {
                        setupFloatingWindow()
                        didConfigureMainWindow = true
                    }
                    if !didAutoCheckUpdatesOnLaunch {
                        didAutoCheckUpdatesOnLaunch = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            updater.checkForUpdates(showSheetWhileChecking: false, showPromptWhenUpdateFound: true)
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar) // Optional: cleaner look
        .onChange(of: scenePhase) { phase in
            if phase == .inactive || phase == .background {
                todoManager.forcePersistState()
            }
        }
        .commands {
            CommandMenu("Updates") {
                Button("Check For Updates") {
                    updater.checkForUpdates()
                }
            }
            CommandMenu("Format") {
                Button("Bold") {
                    RichTextEditor.toggleBold(in: NSApp.keyWindow?.firstResponder as? NSTextView)
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    RichTextEditor.toggleItalic(in: NSApp.keyWindow?.firstResponder as? NSTextView)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Show Fonts") {
                    NSFontManager.shared.orderFrontFontPanel(nil)
                }

                Button("Show Colors") {
                    NSApp.orderFrontColorPanel(nil)
                }
            }
            CommandMenu("Debug") {
                Toggle("Debug Mode", isOn: Binding(
                    get: { todoManager.debugModeEnabled },
                    set: { todoManager.debugModeEnabled = $0 }
                ))
                
                Button("Reset Window Size") {
                    resetWindowSize()
                }
            }
            CommandMenu("Checkpoints") {
                Button("Open Checkpoint Browser") {
                    NotificationCenter.default.post(name: checkpointBrowserNotification, object: nil)
                }

                Button("Create Checkpoint Now") {
                    todoManager.createCheckpointNow()
                }

                Button("Reveal Checkpoint Folder") {
                    todoManager.revealCheckpointFolder()
                }
            }
        }
    }

    var defaultWindowSize: CGSize {
        CGSize(width: 628, height: 679)
    }

    var minimumWindowSize: CGSize {
        CGSize(width: 220, height: 180)
    }

    func setupFloatingWindow() {
        // Create delegate once and store strong reference on both the scene and AppDelegate
        let delegate = WindowCloseDelegate(todoManager: todoManager)
        windowDelegate = delegate
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.windowDelegate = delegate
        }

        for window in NSApplication.shared.windows {
            if isDebugWindow(window) { continue }
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.identifier = NSUserInterfaceItemIdentifier(mainWindowName)
            window.setFrameAutosaveName(mainWindowName)
            window.minSize = minimumWindowSize

            // Set up window delegate for close/minimize interception
            if let todoWindow = window as? TodoWindow {
                todoWindow.todoManager = todoManager
            } else {
                window.delegate = delegate
            }

            // Frame was already restored by AppDelegate.applicationDidFinishLaunching
            // before the window was shown (no flash). Only guard against tiny frames here.
            let f = window.frame
            if f.width < minimumWindowSize.width || f.height < minimumWindowSize.height {
                window.setFrame(NSRect(x: 100, y: 100, width: defaultWindowSize.width, height: defaultWindowSize.height), display: true)
            }
        }
    }
    
    func resetWindowSize() {
        for window in NSApplication.shared.windows {
            if isDebugWindow(window) { continue }
            window.setFrame(NSRect(x: 100, y: 100, width: defaultWindowSize.width, height: defaultWindowSize.height), display: true)
            // Clear saved frame
            UserDefaults.standard.removeObject(forKey: mainWindowFrameHistoryKey)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Strong reference to prevent deallocation
    var windowDelegate: WindowCloseDelegate?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply saved window frame before the window becomes visible,
        // eliminating the resize flash on launch.
        applyInitialWindowFrame()
    }
    
    private func applyInitialWindowFrame() {
        guard let window = NSApplication.shared.windows.first(where: { !isDebugWindow($0) }) else { return }
        
        let minSize = NSSize(width: 220, height: 180)
        let defaultSize = NSRect(x: 100, y: 100, width: 628, height: 679)
        
        if let saved = UserDefaults.standard.string(forKey: mainWindowFrameHistoryKey), !saved.isEmpty {
            let rect = NSRectFromString(saved)
            if rect.width >= minSize.width && rect.height >= minSize.height {
                window.setFrame(rect, display: false) // false = don't flash
                return
            }
        }
        // Fall back to AppKit autosave, then default
        if !window.setFrameUsingName(mainWindowName) {
            window.setFrame(defaultSize, display: false)
        } else {
            let f = window.frame
            if f.width < minSize.width || f.height < minSize.height {
                window.setFrame(defaultSize, display: false)
            }
        }
    }
}

class WindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var todoManager: TodoManager?
    
    init(todoManager: TodoManager) {
        self.todoManager = todoManager
        super.init()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let manager = todoManager else { return true }
        return manager.handleWindowCloseAttempt()
    }
    
    // Override the miniaturize button action
    func windowWillMiniaturize(_ notification: Notification) {
        guard let manager = todoManager else { return }
        
        // Check if we should prevent miniaturization
        if !manager.handleWindowCloseAttempt() {
            // Cancel the miniaturization by posting a notification to undo it
            DispatchQueue.main.async {
                if let window = notification.object as? NSWindow {
                    window.deminiaturize(nil)
                }
            }
        }
    }
}

class TodoWindow: NSWindow {
    weak var todoManager: TodoManager?
    
    override func performClose(_ sender: Any?) {
        guard let manager = todoManager else {
            super.performClose(sender)
            return
        }
        
        if manager.handleWindowCloseAttempt() {
            super.performClose(sender)
        }
    }
    
    override func performMiniaturize(_ sender: Any?) {
        guard let manager = todoManager else {
            super.performMiniaturize(sender)
            return
        }
        
        if manager.handleWindowCloseAttempt() {
            super.performMiniaturize(sender)
        }
    }
}

final class BlockerPromptWindowController {
    private var window: NSWindow?
    private weak var manager: TodoManager?

    func show(manager: TodoManager) {
        self.manager = manager
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1200, height: 800)
        let width = screenRect.width * 0.75
        let height = screenRect.height * 0.75
        let originX = screenRect.midX - width / 2
        let originY = screenRect.midY - height / 2

        if window == nil {
            let root = BlockerPromptView(manager: manager) { [weak self] in
                self?.hide()
            }
            let host = NSHostingView(rootView: root)

            let promptWindow = NSWindow(
                contentRect: NSRect(x: originX, y: originY, width: width, height: height),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            promptWindow.title = "Focus Reminder"
            // Use .statusBar+1 so it floats above all other windows including
            // the main app window which is at .floating level.
            promptWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
            promptWindow.contentView = host
            promptWindow.isReleasedWhenClosed = false
            promptWindow.minSize = NSSize(width: 480, height: 360)
            window = promptWindow
        }

        window?.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct BlockerPromptView: View {
    @ObservedObject var manager: TodoManager
    let onDismiss: () -> Void
    @State private var now = Date()
    @State private var phraseIndex = 0
    @State private var visiblePhrase: String = ""
    @State private var showTabClosedBanner: Bool = false
    @State private var tabClosedBannerText: String = ""

    // Notebook brown palette
    private let notebookBrown = Color(red: 0.84, green: 0.75, blue: 0.62)
    private let cardBrown = Color(red: 0.96, green: 0.91, blue: 0.80)
    private let darkBrown = Color(red: 0.38, green: 0.26, blue: 0.14)

    private var topThreeTodos: [TodoItem] {
        manager.sortedTodos.filter { !$0.isCompleted }.prefix(3).map { $0 }
    }

    private var allPendingTodos: [TodoItem] {
        manager.sortedTodos.filter { !$0.isCompleted }
    }

    private var currentPhrase: String {
        let phrases = manager.blockerSettings.motivationalPhrases
        guard !phrases.isEmpty else { return "Focus on the next important step." }
        return phrases[phraseIndex % phrases.count]
    }

    var body: some View {
        ZStack {
            notebookBrown.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stay Focused")
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundColor(darkBrown)
                        if let distraction = manager.latestDetectedDistraction {
                            Text("Distraction detected: \(distraction)")
                                .font(.caption)
                                .foregroundColor(darkBrown.opacity(0.7))
                        }
                    }
                    Spacer()
                    Button("Resume Work") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(darkBrown)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

                // Motivational phrase with smooth fade
                ZStack {
                    Text(visiblePhrase)
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .foregroundColor(darkBrown)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .id(phraseIndex)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.7), value: phraseIndex)

                Divider()
                    .background(darkBrown.opacity(0.3))
                    .padding(.horizontal, 28)

                // Top 3 priorities — centred, prominent
                VStack(spacing: 10) {
                    Text("Top 3 Priorities")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundColor(darkBrown.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)

                    if topThreeTodos.isEmpty {
                        Text("No pending tasks — great work!")
                            .font(.headline)
                            .foregroundColor(darkBrown.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(topThreeTodos) { todo in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(urgencyColor(for: todo))
                                    .frame(width: 5)
                                    .frame(height: 44)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(todo.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(darkBrown)
                                        .lineLimit(1)
                                    Text(timeRemaining(for: todo, now: now))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(urgencyColor(for: todo))
                                }
                                Spacer()

                                Circle()
                                    .fill(urgencyColor(for: todo))
                                    .frame(width: 10, height: 10)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(cardBrown)
                                    .shadow(color: darkBrown.opacity(0.12), radius: 4, x: 0, y: 2)
                            )
                            .padding(.horizontal, 28)
                        }
                    }
                }

                Divider()
                    .background(darkBrown.opacity(0.3))
                    .padding(.horizontal, 28)
                    .padding(.top, 14)

                // All pending tasks list
                VStack(alignment: .leading, spacing: 6) {
                    Text("All Pending Tasks (\(allPendingTodos.count))")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundColor(darkBrown.opacity(0.7))
                        .padding(.horizontal, 28)
                        .padding(.top, 10)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(allPendingTodos) { todo in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(urgencyColor(for: todo))
                                        .frame(width: 7, height: 7)
                                    Text(todo.title)
                                        .font(.system(size: 13))
                                        .foregroundColor(darkBrown)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(timeRemaining(for: todo, now: now))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(urgencyColor(for: todo))
                                }
                                .padding(.horizontal, 28)
                                .padding(.vertical, 3)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            now = value
        }
        .onReceive(Timer.publish(every: 7, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.easeInOut(duration: 0.7)) {
                phraseIndex += 1
                visiblePhrase = currentPhrase
            }
        }
        .onAppear {
            visiblePhrase = currentPhrase
        }
        .onChange(of: manager.tabAutoClosedNonce) { _ in
            tabClosedBannerText = "Tab closed: \(manager.lastAutoClosedDistraction)"
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                showTabClosedBanner = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                withAnimation(.easeOut(duration: 0.4)) {
                    showTabClosedBanner = false
                }
            }
        }
        .overlay(alignment: .top) {
            if showTabClosedBanner {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white)
                    Text(tabClosedBannerText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color(red: 0.18, green: 0.12, blue: 0.06).opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                )
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func urgencyColor(for todo: TodoItem) -> Color {
        let delta = todo.dueDate.timeIntervalSince(now)
        if delta < 0 { return .red }
        if delta < 3600 { return .orange }
        if delta < 86400 * 3 { return Color(red: 0.85, green: 0.55, blue: 0.1) }
        return Color(red: 0.25, green: 0.55, blue: 0.25)
    }

    private func timeRemaining(for todo: TodoItem, now: Date) -> String {
        let delta = Int(todo.dueDate.timeIntervalSince(now))
        if delta <= 0 { return "Overdue" }
        let days = delta / 86400
        let hours = (delta % 86400) / 3600
        let mins = (delta % 3600) / 60
        let secs = delta % 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m \(secs)s" }
        return "\(mins)m \(secs)s"
    }
}

struct SidebarSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct DetailSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - 4. Content Views

struct ContentView: View {
    @EnvironmentObject var manager: TodoManager
    @EnvironmentObject var updater: UpdateManager
    @State private var showingAddSheet = false
    @State private var showingNewSidebarSheet = false
    @State private var newSidebarName = ""
    @State private var draggedBoardID: UUID?
    @State private var renameBoardID: UUID?
    @State private var renameBoardText = ""
    @State private var exportDocument = SidebarTransferDocument()
    @State private var exportDefaultFilename = "AdvancedTodo-sidebar"
    @State private var showingExporter = false
    @State private var importTargetSidebarKey: String?
    @State private var showingImporter = false
    @State private var pendingImportedPackage: SidebarExportPackage?
    @State private var pendingImportTargetSidebarKey: String?
    @State private var showingImportActionDialog = false
    @State private var pendingBoardDeletion: NoteBoard?
    @State private var showingSettingsSheet = false
    @State private var showingCheckpointBrowser = false
    @State private var checkpointRecords: [CheckpointRecord] = []
    @State private var selectedCheckpointID: UUID?
    @State private var latestSidebarSize: CGSize = .zero
    @State private var latestDetailSize: CGSize = .zero
    @State private var blockerPromptController = BlockerPromptWindowController()

    private let blockerPollingTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        sidebarSelectionRow(
                            title: "Todo",
                            isSelected: manager.selectedSidebarKey == "todo",
                            isDimmed: false
                        ) {
                            manager.selectedSidebarKey = "todo"
                        } menu: {
                            Button("Export Todo Sidebar") {
                                startExport(for: "todo")
                            }
                            Button("Import Into Todo") {
                                startImport(targetSidebarKey: "todo")
                            }
                        }

                        Divider()

                        ForEach(manager.noteBoards) { board in
                            sidebarSelectionRow(
                                title: board.name,
                                isSelected: manager.selectedSidebarKey == "board:\(board.id.uuidString)",
                                isDimmed: false
                            ) {
                                manager.selectedSidebarKey = "board:\(board.id.uuidString)"
                            } menu: {
                                Button("Rename") {
                                    renameBoardID = board.id
                                    renameBoardText = board.name
                                }
                                Button("Export Sidebar") {
                                    startExport(for: "board:\(board.id.uuidString)")
                                }
                                Button("Import Here") {
                                    startImport(targetSidebarKey: "board:\(board.id.uuidString)")
                                }
                                Button("Delete", role: .destructive) {
                                    pendingBoardDeletion = board
                                }
                            }
                            .onDrag {
                                draggedBoardID = board.id
                                return NSItemProvider(object: board.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: NoteBoardDropDelegate(
                                item: board,
                                manager: manager,
                                draggedBoardID: $draggedBoardID
                            ))
                        }
                        .onMove(perform: manager.moveBoards)

                        Divider()

                        sidebarSelectionRow(
                            title: "Trash (\(manager.trashedNoteBoards.count))",
                            isSelected: manager.selectedSidebarKey == "trash",
                            isDimmed: manager.trashedNoteBoards.isEmpty
                        ) {
                            manager.selectedSidebarKey = "trash"
                        } menu: {
                            Button("Empty Trash", role: .destructive) {
                                manager.emptyTrash()
                            }
                            .disabled(manager.trashedNoteBoards.isEmpty)
                        }
                    }
                }
                .navigationTitle("Sidebar")
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                if manager.debugModeEnabled {
                                    manager.updateDebugSidebarSize(proxy.size)
                                }
                            }
                            .onChange(of: proxy.size) { newSize in
                                if manager.debugModeEnabled {
                                    manager.updateDebugSidebarSize(newSize)
                                }
                            }
                            .preference(key: SidebarSizePreferenceKey.self, value: proxy.size)
                    }
                )

                Divider()

                HStack {
                    Button("+ New Note") {
                        newSidebarName = ""
                        showingNewSidebarSheet = true
                    }
                    Spacer()
                    Button("Import") {
                        startImport(targetSidebarKey: manager.selectedSidebarKey)
                    }
                    .help("Import an exported sidebar package")
                }
                .padding(10)
                .background(.ultraThinMaterial)
            }
        } detail: {
            VStack(spacing: 0) {
                if manager.selectedSidebarKey == "trash" {
                    TrashBoardsView()
                        .environmentObject(manager)
                        .frame(maxHeight: .infinity)
                } else {
                    todoListPanel
                        .frame(maxHeight: .infinity)

                    if let board = manager.selectedBoard() {
                        Divider()
                        NoteBoardEditorView(board: board)
                            .environmentObject(manager)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle("Tasks")
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            if manager.debugModeEnabled {
                                manager.updateDebugDetailSize(proxy.size)
                            }
                        }
                        .onChange(of: proxy.size) { newSize in
                            if manager.debugModeEnabled {
                                manager.updateDebugDetailSize(newSize)
                            }
                        }
                        .preference(key: DetailSizePreferenceKey.self, value: proxy.size)
                }
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 10) {
                        Button("New +") {
                            showingAddSheet = true
                        }

                        Button {
                            showingSettingsSheet = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("Open Settings")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddEditTodoView(todoToEdit: nil)
        }
        .sheet(isPresented: $showingNewSidebarSheet) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Note Sidebar")
                    .font(.headline)
                TextField("Sidebar name", text: $newSidebarName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") {
                        showingNewSidebarSheet = false
                    }
                    Spacer()
                    Button("Create") {
                        manager.addBoard(name: newSidebarName)
                        showingNewSidebarSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 320)
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsRootView()
                .environmentObject(manager)
        }
        .sheet(isPresented: Binding(
            get: { pendingBoardDeletion != nil },
            set: { if !$0 { pendingBoardDeletion = nil } }
        )) {
            if let board = pendingBoardDeletion {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Move Note Block To Trash")
                        .font(.title3.weight(.semibold))

                    Text("The selected note block will be moved to Trash. You can restore it later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Name:")
                            .fontWeight(.semibold)
                        Text(board.name)
                        Spacer()
                    }

                    HStack {
                        let plainContent = board.noteBody.string
                        Text("Characters:")
                            .fontWeight(.semibold)
                        Text("\(plainContent.count)")
                        Spacer()
                        Text("Lines:")
                            .fontWeight(.semibold)
                        Text("\(max(1, plainContent.components(separatedBy: .newlines).count))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ScrollView {
                        Text(board.noteBody.string.isEmpty ? "(No content)" : board.noteBody.string)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(minHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                    HStack {
                        Button("Cancel") {
                            pendingBoardDeletion = nil
                        }
                        Spacer()
                        Button("Move To Trash", role: .destructive) {
                            manager.deleteBoard(board.id)
                            pendingBoardDeletion = nil
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .frame(width: 520, height: 460)
            }
        }
        .sheet(isPresented: $showingCheckpointBrowser) {
            CheckpointBrowserView(
                records: checkpointRecords,
                currentSnapshot: manager.currentSnapshot(),
                selectedID: $selectedCheckpointID,
                onRefresh: reloadCheckpointRecords,
                onRevealFolder: { manager.revealCheckpointFolder() },
                onRevealSelected: {
                    if let record = checkpointRecords.first(where: { $0.id == selectedCheckpointID }) {
                        manager.revealCheckpointFile(record)
                    }
                },
                onRestoreSelected: {
                    if let record = checkpointRecords.first(where: { $0.id == selectedCheckpointID }) {
                        manager.restoreCheckpoint(record)
                        reloadCheckpointRecords()
                    }
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { renameBoardID != nil },
            set: { if !$0 { renameBoardID = nil } }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Note Sidebar")
                    .font(.headline)
                TextField("New name", text: $renameBoardText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") {
                        renameBoardID = nil
                    }
                    Spacer()
                    Button("Save") {
                        if let id = renameBoardID {
                            manager.renameBoard(id, to: renameBoardText)
                        }
                        renameBoardID = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 320)
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .advancedTodoSidebar,
            defaultFilename: exportDefaultFilename
        ) { _ in }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.advancedTodoSidebar, .json],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .confirmationDialog(
            "Import Options",
            isPresented: $showingImportActionDialog,
            titleVisibility: .visible
        ) {
            Button("Merge With Existing") {
                applyPendingImport(mode: .merge)
            }
            Button("Replace Existing") {
                applyPendingImport(mode: .replace)
            }
            Button("Create New From Import") {
                applyPendingImport(mode: .create)
            }
            Button("Cancel", role: .cancel) {
                clearPendingImport()
            }
        } message: {
            Text("Choose how the imported sidebar data should be applied.")
        }
        .sheet(isPresented: $updater.isPresentingSheet) {
            UpdateSheetView()
                .environmentObject(updater)
        }
        .alert("Update Available", isPresented: $updater.updatePromptVisible) {
            Button("Update") {
                updater.beginGuidedUpdateFromPrompt()
            }
            Button("Close", role: .cancel) {}
        } message: {
            if let info = updater.updateInfo {
                if let asset = info.asset {
                    Text("Version \(info.newVersion) is available (current: \(info.currentVersion)). Download \(asset.name) (\(asset.formattedSize)) and prepare install now?")
                } else {
                    Text("Version \(info.newVersion) is available (current: \(info.currentVersion)). Do you want to open the updater now?")
                }
            } else {
                Text("A new version is available. Do you want to update now?")
            }
        }
        .onPreferenceChange(SidebarSizePreferenceKey.self) { size in
            latestSidebarSize = size
            if manager.debugModeEnabled {
                manager.updateDebugSidebarSize(size)
            }
        }
        .onPreferenceChange(DetailSizePreferenceKey.self) { size in
            latestDetailSize = size
            if manager.debugModeEnabled {
                manager.updateDebugDetailSize(size)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  isMainAppWindow(window) else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: mainWindowFrameHistoryKey)
            if manager.debugModeEnabled {
                manager.updateDebugWindowSize(window.frame.size)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  isMainAppWindow(window) else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: mainWindowFrameHistoryKey)
        }
        .onChange(of: manager.debugModeEnabled) { enabled in
            if enabled {
                if let window = currentMainWindow() {
                    manager.updateDebugWindowSize(window.frame.size)
                }
                manager.updateDebugSidebarSize(latestSidebarSize)
                manager.updateDebugDetailSize(latestDetailSize)
            }
        }
        .onAppear {
            reloadCheckpointRecords()
            if manager.debugModeEnabled {
                if let window = currentMainWindow() {
                    manager.updateDebugWindowSize(window.frame.size)
                }
                manager.updateDebugSidebarSize(latestSidebarSize)
                manager.updateDebugDetailSize(latestDetailSize)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-sync permission when app becomes active (user might have granted it in System Settings)
            manager.syncAccessibilityPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: checkpointBrowserNotification)) { _ in
            reloadCheckpointRecords()
            showingCheckpointBrowser = true
        }
        .onReceive(blockerPollingTimer) { _ in
            manager.evaluateDistraction()
        }
        .onChange(of: manager.blockerPromptNonce) { _ in
            blockerPromptController.show(manager: manager)
        }
        .safeAreaInset(edge: .bottom) {
            if manager.debugModeEnabled {
                HStack {
                    Text(manager.debugWindowSizeText.isEmpty ? "Window: -" : manager.debugWindowSizeText)
                    Spacer()
                    Text(manager.debugSidebarSizeText.isEmpty ? "Sidebar: -" : manager.debugSidebarSizeText)
                    Spacer()
                    Text(manager.debugDetailSizeText.isEmpty ? "Detail: -" : manager.debugDetailSizeText)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
    }

    private func currentMainWindow() -> NSWindow? {
        if let named = NSApplication.shared.windows.first(where: { isMainAppWindow($0) }) {
            return named
        }

        if let keyWindow = NSApplication.shared.keyWindow, !isDebugWindow(keyWindow) {
            return keyWindow
        }

        return nil
    }

    private func startExport(for sidebarKey: String) {
        guard let package = manager.exportPackage(for: sidebarKey),
              let data = try? JSONEncoder().encode(package) else {
            return
        }
        exportDocument = SidebarTransferDocument(data: data)
        exportDefaultFilename = "\(package.displayName)-export"
        showingExporter = true
    }

    private func startImport(targetSidebarKey: String?) {
        importTargetSidebarKey = targetSidebarKey
        showingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result,
              let url = urls.first,
              let data = try? Data(contentsOf: url),
              let package = try? JSONDecoder().decode(SidebarExportPackage.self, from: data) else {
            return
        }

        pendingImportedPackage = package
        pendingImportTargetSidebarKey = importTargetSidebarKey
        showingImportActionDialog = true
    }

    private func applyPendingImport(mode: ImportMode) {
        guard let package = pendingImportedPackage else { return }
        manager.applyImportedPackage(package, mode: mode, targetSidebarKey: pendingImportTargetSidebarKey)
        clearPendingImport()
    }

    private func clearPendingImport() {
        pendingImportedPackage = nil
        pendingImportTargetSidebarKey = nil
        importTargetSidebarKey = nil
    }

    private func reloadCheckpointRecords() {
        checkpointRecords = manager.loadCheckpointRecords()
        if let selectedCheckpointID,
           checkpointRecords.contains(where: { $0.id == selectedCheckpointID }) {
            return
        }
        selectedCheckpointID = checkpointRecords.first?.id
    }

    private func sidebarSelectionRow<MenuContent: View>(title: String, isSelected: Bool, isDimmed: Bool, action: @escaping () -> Void, @ViewBuilder menu: @escaping () -> MenuContent) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(isSelected ? .headline : .body)
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            menu()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
    }

    private var todoListPanel: some View {
        ScrollViewReader { proxy in
            ZStack {
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(manager.sortedTodos) { todo in
                            TodoRow(todo: todo)
                                .environmentObject(manager)
                                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                                .id(todo.id)
                        }
                    }
                    .padding()
                }
            }
            .coordinateSpace(name: "todoScroll")
            .onAppear {
                restoreScrollPosition(using: proxy)
            }
            .onChange(of: manager.scrollAnchorTodoID) { _ in
                restoreScrollPosition(using: proxy)
            }
            .onPreferenceChange(TodoRowFramePreferenceKey.self) { frames in
                updateScrollAnchor(from: frames)
            }
        }
    }

    private func restoreScrollPosition(using proxy: ScrollViewProxy) {
        guard let scrollAnchor = manager.scrollAnchorTodoID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(scrollAnchor, anchor: .top)
        }
    }

    private func updateScrollAnchor(from frames: [UUID: CGRect]) {
        let visibleFrames = frames.filter { $0.value.maxY > 0 }
        guard let topMost = visibleFrames.min(by: { abs($0.value.minY) < abs($1.value.minY) })?.key else { return }
        manager.restoreScrollAnchorIfNeeded(topMost)
    }
}

struct NoteBoardEditorView: View {
    @EnvironmentObject var manager: TodoManager
    let board: NoteBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Board name",
                text: Binding(
                    get: {
                        manager.noteBoards.first(where: { $0.id == board.id })?.name ?? ""
                    },
                    set: { manager.updateBoardName(board.id, name: $0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.title3.weight(.semibold))

            RichTextEditor(
                text: Binding(
                    get: {
                        manager.noteBoards.first(where: { $0.id == board.id })?.noteBody ?? NSAttributedString(string: "")
                    },
                    set: { manager.updateBoardBody(board.id, body: $0) }
                ),
                backgroundColor: .white,
                drawsBorder: false
            )
            .id(board.id)
            .frame(maxHeight: .infinity)
        }
        .padding()
        .background(Color.white)
    }
}

struct TrashBoardsView: View {
    @EnvironmentObject var manager: TodoManager
    @State private var selectedTrashID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedTrashID) {
                ForEach(manager.trashedNoteBoards) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.board.name)
                            .font(.headline)
                        Text(item.deletedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
            }
            .frame(minWidth: 220, idealWidth: 260)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if let selected = manager.trashedNoteBoards.first(where: { $0.id == selectedTrashID }) {
                    Text(selected.board.name)
                        .font(.title3.weight(.semibold))

                    Text("Deleted \(selected.deletedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(selected.board.noteBody.string.isEmpty ? "(No content)" : selected.board.noteBody.string)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                    HStack {
                        Button("Restore") {
                            manager.restoreBoardFromTrash(selected.id)
                            selectedTrashID = manager.trashedNoteBoards.first?.id
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Restore As Copy") {
                            manager.restoreBoardFromTrashAsCopy(selected.id)
                        }

                        Button("Delete Permanently", role: .destructive) {
                            manager.permanentlyDeleteBoardFromTrash(selected.id)
                            selectedTrashID = manager.trashedNoteBoards.first?.id
                        }

                        Spacer()
                    }
                } else {
                    Text(manager.trashedNoteBoards.isEmpty ? "Trash is empty." : "Select a trashed note block to preview and restore.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(14)
        }
        .onAppear {
            selectedTrashID = manager.trashedNoteBoards.first?.id
        }
        .onChange(of: manager.trashedNoteBoards.count) { _ in
            if let selectedTrashID,
               manager.trashedNoteBoards.contains(where: { $0.id == selectedTrashID }) {
                return
            }
            self.selectedTrashID = manager.trashedNoteBoards.first?.id
        }
    }
}

struct CheckpointBrowserView: View {
    let records: [CheckpointRecord]
    let currentSnapshot: AppSnapshot
    @Binding var selectedID: UUID?
    let onRefresh: () -> Void
    let onRevealFolder: () -> Void
    let onRevealSelected: () -> Void
    let onRestoreSelected: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Checkpoint Browser")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
            .padding(12)

            Divider()

            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.createdAt.formatted(date: .abbreviated, time: .standard))
                                .font(.headline)
                            Text(record.url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(record.id)
                    }
                }
                .frame(minWidth: 290, idealWidth: 320)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    if let selected = records.first(where: { $0.id == selectedID }) {
                        HStack {
                            Text("Preview")
                                .font(.headline)
                            Spacer()
                            Text(selected.createdAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        CheckpointPreviewView(snapshot: selected.snapshot)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider()

                        CheckpointDiffView(currentSnapshot: currentSnapshot, checkpointSnapshot: selected.snapshot)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(records.isEmpty ? "No checkpoints yet." : "Select a checkpoint to preview.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(12)
            }

            Divider()

            HStack {
                Button("Refresh") { onRefresh() }
                Button("Reveal Folder") { onRevealFolder() }
                Button("Reveal Selected") { onRevealSelected() }
                    .disabled(records.first(where: { $0.id == selectedID }) == nil)
                Spacer()
                Button("Revert To Selected", role: .destructive) {
                    onRestoreSelected()
                }
                .disabled(records.first(where: { $0.id == selectedID }) == nil)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 1020, height: 680)
    }
}

struct CheckpointDiffView: View {
    let currentSnapshot: AppSnapshot
    let checkpointSnapshot: AppSnapshot

    private var currentBoardsByID: [UUID: StoredNoteBoard] {
        Dictionary(uniqueKeysWithValues: (currentSnapshot.noteBoards ?? []).map { ($0.id, $0) })
    }

    private var checkpointBoardsByID: [UUID: StoredNoteBoard] {
        Dictionary(uniqueKeysWithValues: (checkpointSnapshot.noteBoards ?? []).map { ($0.id, $0) })
    }

    private var currentTodosByID: [UUID: StoredTodo] {
        Dictionary(uniqueKeysWithValues: currentSnapshot.todos.map { ($0.id, $0) })
    }

    private var checkpointTodosByID: [UUID: StoredTodo] {
        Dictionary(uniqueKeysWithValues: checkpointSnapshot.todos.map { ($0.id, $0) })
    }

    var body: some View {
        let addedBoardIDs = Set(currentBoardsByID.keys).subtracting(checkpointBoardsByID.keys)
        let removedBoardIDs = Set(checkpointBoardsByID.keys).subtracting(currentBoardsByID.keys)
        let changedBoardIDs = Set(currentBoardsByID.keys).intersection(checkpointBoardsByID.keys).filter { id in
            let current = currentBoardsByID[id]
            let checkpoint = checkpointBoardsByID[id]
            return current?.name != checkpoint?.name || current?.noteBodyRTF != checkpoint?.noteBodyRTF
        }

        let addedTodoIDs = Set(currentTodosByID.keys).subtracting(checkpointTodosByID.keys)
        let removedTodoIDs = Set(checkpointTodosByID.keys).subtracting(currentTodosByID.keys)
        let changedTodoIDs = Set(currentTodosByID.keys).intersection(checkpointTodosByID.keys).filter { id in
            let current = currentTodosByID[id]
            let checkpoint = checkpointTodosByID[id]
            return current?.title != checkpoint?.title ||
                current?.descriptionRTF != checkpoint?.descriptionRTF ||
                current?.isCompleted != checkpoint?.isCompleted ||
                current?.dueDate != checkpoint?.dueDate
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Diff")
                .font(.headline)

            HStack {
                Text("Selection")
                    .fontWeight(.semibold)
                Spacer()
                Text("Current: \(currentSnapshot.selectedSidebarKey ?? "-")")
                Spacer()
                Text("Checkpoint: \(checkpointSnapshot.selectedSidebarKey ?? "-")")
            }
            .font(.caption)

            GroupBox("Boards") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Added: \(addedBoardIDs.count)")
                    Text("Removed: \(removedBoardIDs.count)")
                    Text("Modified: \(changedBoardIDs.count)")

                    ForEach(Array(addedBoardIDs), id: \.self) { id in
                        if let board = currentBoardsByID[id] {
                            Text("+ \(board.name)")
                                .foregroundStyle(.green)
                        }
                    }
                    ForEach(Array(removedBoardIDs), id: \.self) { id in
                        if let board = checkpointBoardsByID[id] {
                            Text("- \(board.name)")
                                .foregroundStyle(.red)
                        }
                    }
                    ForEach(Array(changedBoardIDs), id: \.self) { id in
                        if let current = currentBoardsByID[id], let checkpoint = checkpointBoardsByID[id] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("~ \(checkpoint.name) -> \(current.name)")
                                if current.noteBodyRTF != checkpoint.noteBodyRTF {
                                    Text("body changed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Todos") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Added: \(addedTodoIDs.count)")
                    Text("Removed: \(removedTodoIDs.count)")
                    Text("Modified: \(changedTodoIDs.count)")

                    ForEach(Array(addedTodoIDs), id: \.self) { id in
                        if let todo = currentTodosByID[id] {
                            Text("+ \(todo.title)")
                                .foregroundStyle(.green)
                        }
                    }
                    ForEach(Array(removedTodoIDs), id: \.self) { id in
                        if let todo = checkpointTodosByID[id] {
                            Text("- \(todo.title)")
                                .foregroundStyle(.red)
                        }
                    }
                    ForEach(Array(changedTodoIDs), id: \.self) { id in
                        if let current = currentTodosByID[id], let checkpoint = checkpointTodosByID[id] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("~ \(checkpoint.title) -> \(current.title)")
                                if current.isCompleted != checkpoint.isCompleted {
                                    Text("completion changed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct CheckpointPreviewView: View {
    let snapshot: AppSnapshot

    private var todoItems: [TodoItem] {
        snapshot.todos.map { $0.makeTodo() }
    }

    private var boards: [NoteBoard] {
        snapshot.noteBoards?.map { $0.makeBoard() } ?? []
    }

    private var selectedBoard: NoteBoard? {
        guard let key = snapshot.selectedSidebarKey,
              key.hasPrefix("board:"),
              let id = UUID(uuidString: String(key.dropFirst("board:".count))) else {
            return nil
        }
        return boards.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sidebar")
                    .font(.headline)
                Text("Todo")
                    .fontWeight(snapshot.selectedSidebarKey == "todo" ? .bold : .regular)
                ForEach(boards) { board in
                    Text(board.name)
                        .fontWeight(snapshot.selectedSidebarKey == "board:\(board.id.uuidString)" ? .bold : .regular)
                }
                if snapshot.selectedSidebarKey == "trash" {
                    Text("Trash")
                        .fontWeight(.bold)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 220, alignment: .topLeading)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Tasks")
                    .font(.headline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(todoItems.prefix(20)) { todo in
                            HStack {
                                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                                Text(todo.title)
                                    .strikethrough(todo.isCompleted, color: .primary)
                                Spacer()
                            }
                            .font(.subheadline)
                        }
                    }
                }

                if let selectedBoard {
                    Divider()
                    Text(selectedBoard.name)
                        .font(.headline)
                    ScrollView {
                        Text(selectedBoard.noteBody.string.isEmpty ? "(No content)" : selectedBoard.noteBody.string)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                }
            }
            .padding(10)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct SettingsRootView: View {
    @EnvironmentObject var manager: TodoManager
    @State private var selection: String? = "blocker"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Blocker", systemImage: "shield.lefthalf.filled").tag("blocker")
                Label("Window", systemImage: "macwindow").tag("window")
                Label("General", systemImage: "gearshape").tag("general")
            }
            .navigationTitle("Settings")
        } detail: {
            if selection == "blocker" {
                BlockerSettingsView()
                    .environmentObject(manager)
            } else if selection == "window" {
                WindowSettingsView()
                    .environmentObject(manager)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("General")
                        .font(.title2.bold())
                    Text("More settings coming soon.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - Window Settings View

struct WindowSettingsView: View {
    @EnvironmentObject var manager: TodoManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                VStack(alignment: .leading, spacing: 6) {
                    Text("Window")
                        .font(.title2.bold())
                    Text("Control how the todo window behaves when closed or minimized.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // ── Close / Minimize Prevention ──────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {

                        Toggle("Prevent accidental window closing", isOn: Binding(
                            get: { manager.blockerSettings.preventWindowClose },
                            set: { manager.blockerSettings.preventWindowClose = $0 }
                        ))
                        .font(.headline)

                        Text("When enabled, a confirmation dialog appears before the window is closed or minimized.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Toggle("Auto-reopen window after closing", isOn: Binding(
                            get: { manager.blockerSettings.autoReopenEnabled },
                            set: { manager.blockerSettings.autoReopenEnabled = $0 }
                        ))
                        .disabled(!manager.blockerSettings.preventWindowClose)

                        Text("Adds a \"Close & Auto-Reopen\" option to the confirmation dialog. The window will reopen automatically after the delay below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if manager.blockerSettings.autoReopenEnabled && manager.blockerSettings.preventWindowClose {
                            Divider()

                            HStack(spacing: 12) {
                                Text("Reopen after")
                                    .font(.subheadline)
                                Stepper(value: Binding(
                                    get: { manager.blockerSettings.autoReopenMinutes },
                                    set: { manager.blockerSettings.autoReopenMinutes = max(1, min(60, $0)) }
                                ), in: 1...60, step: 1) {
                                    Text("\(manager.blockerSettings.autoReopenMinutes) minute\(manager.blockerSettings.autoReopenMinutes == 1 ? "" : "s")")
                                        .monospacedDigit()
                                }
                            }

                            Text("Range: 1 – 60 minutes. Default is 5 minutes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct BlockerSettingsView: View {
    @EnvironmentObject var manager: TodoManager
    @State private var newApp = ""
    @State private var newSite = ""
    @State private var newKeyword = ""
    @State private var newPhrase = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Header ──────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("Focus Blocker")
                        .font(.title2.bold())
                    Text("When enabled, the app watches which app is in the foreground every 6 seconds. If a distracting app is detected, a full-screen focus reminder appears every 5 minutes showing your pending tasks and a motivational message.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // ── Master toggles ───────────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable Focus Blocker", isOn: Binding(
                            get: { manager.blockerSettings.isEnabled },
                            set: { manager.blockerSettings.isEnabled = $0 }
                        ))
                        .font(.headline)

                        Divider()

                        Toggle("App Monitoring Permission Granted", isOn: Binding(
                            get: { manager.blockerSettings.appMonitoringPermissionGranted },
                            set: { manager.setBlockerPermissionGranted($0) }
                        ))

                        Text("Allows reading the frontmost app name and bundle ID via NSWorkspace. No data leaves your device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        HStack(alignment: .top, spacing: 8) {
                            Toggle("Accessibility Permission Granted", isOn: Binding(
                                get: { manager.blockerSettings.accessibilityPermissionGranted },
                                set: { manager.setAccessibilityPermissionGranted($0) }
                            ))
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .font(.caption)
                        }

                        Text("Optional but recommended. Enables reading the exact focused window title via the Accessibility API — catches browser tabs more reliably. Grant in System Settings → Privacy & Security → Accessibility, then toggle this on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Toggle("Also block YouTube videos (not just Shorts)", isOn: Binding(
                            get: { manager.blockerSettings.blockYouTubeVideos },
                            set: { manager.blockerSettings.blockYouTubeVideos = $0 }
                        ))

                        Text("When on, any window titled 'YouTube' is treated as a distraction, not just Shorts. YouTube Music is excluded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Toggle("Auto-close tab on second strike", isOn: Binding(
                            get: { manager.blockerSettings.autoCloseTabsOnSecondStrike },
                            set: { manager.blockerSettings.autoCloseTabsOnSecondStrike = $0 }
                        ))

                        Text("When on, if a shorts-type distraction (YouTube Shorts, TikTok, Instagram Reels, etc.) is detected twice in a row, the browser tab is automatically closed with Cmd+W. Normal YouTube pages (home/feed/videos) only trigger the reminder popup and are not auto-closed. Requires Accessibility permission. Chat apps and standalone apps like Discord or Steam are never auto-closed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Block Duration")
                                .font(.headline)
                            
                            HStack {
                                Stepper(value: Binding(
                                    get: { manager.blockerSettings.blockDurationSeconds },
                                    set: { manager.blockerSettings.blockDurationSeconds = max(10, $0) }
                                ), in: 10...600, step: 10) {
                                    Text("\(manager.blockerSettings.blockDurationSeconds) seconds")
                                }
                            }
                            
                            Text("How long the blocker prompt stays on screen before you can be interrupted again. Default is 60 seconds (1 minute).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider()

                    }
                    .padding(4)
                }

                // ── Four lists side by side ──────────────────────────────────
                HStack(alignment: .top, spacing: 16) {
                    blockerListSection(
                        title: "Blocked Apps",
                        subtitle: "App names or bundle ID fragments (e.g. Discord, com.hnc.Discord)",
                        items: manager.blockerSettings.blockedApps,
                        placeholder: "App name or bundle ID",
                        newValue: $newApp,
                        onAdd: { manager.addBlockedApp(newApp); newApp = "" },
                        onDelete: manager.removeBlockedApp
                    )

                    blockerListSection(
                        title: "Blocked Websites",
                        subtitle: "Domain fragments matched against browser window titles (e.g. instagram.com)",
                        items: manager.blockerSettings.blockedWebsites,
                        placeholder: "Domain or URL fragment",
                        newValue: $newSite,
                        onAdd: { manager.addBlockedWebsite(newSite); newSite = "" },
                        onDelete: manager.removeBlockedWebsite
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    blockerListSection(
                        title: "Blocked Keywords",
                        subtitle: "Any app whose name or bundle ID contains these words is blocked (e.g. shorts, gaming)",
                        items: manager.blockerSettings.blockedKeywords,
                        placeholder: "Keyword",
                        newValue: $newKeyword,
                        onAdd: { manager.addBlockedKeyword(newKeyword); newKeyword = "" },
                        onDelete: manager.removeBlockedKeyword
                    )

                    blockerListSection(
                        title: "Motivational Phrases",
                        subtitle: "These rotate on the focus reminder popup every 7 seconds",
                        items: manager.blockerSettings.motivationalPhrases,
                        placeholder: "Add a phrase",
                        newValue: $newPhrase,
                        onAdd: { manager.addMotivationPhrase(newPhrase); newPhrase = "" },
                        onDelete: manager.removeMotivationPhrase
                    )
                }

                // ── Personalise note ─────────────────────────────────────────
                GroupBox("Personalise your blocklist") {
                    VStack(alignment: .leading, spacing: 8) {
                        researchRow(icon: "app.badge", text: "Add any game launcher you use that isn't in the list (e.g. Heroic, Lutris, Battle.net, GOG Galaxy).")
                        researchRow(icon: "globe", text: "Add any social or entertainment site you visit in a browser that isn't already covered.")
                        researchRow(icon: "quote.bubble", text: "Replace the default motivational phrases with ones that actually resonate with you — they hit harder when they're personal.")
                        researchRow(icon: "checkmark.shield", text: "Grant Accessibility permission to enable auto-close of distracting tabs on the second strike.")
                    }
                    .padding(4)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func blockerListSection(
        title: String,
        subtitle: String,
        items: [String],
        placeholder: String,
        newValue: Binding<String>,
        onAdd: @escaping () -> Void,
        onDelete: @escaping (IndexSet) -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                List {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.subheadline)
                    }
                    .onDelete(perform: onDelete)
                }
                .listStyle(.bordered)
                .frame(minHeight: 120, maxHeight: 200)

                HStack {
                    TextField(placeholder, text: newValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if !newValue.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty { onAdd() } }
                    Button("Add") { onAdd() }
                        .disabled(newValue.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func researchRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TodoRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct NoteBoardDropDelegate: DropDelegate {
    let item: NoteBoard
    let manager: TodoManager
    @Binding var draggedBoardID: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedBoardID else { return }
        manager.moveBoard(from: sourceID, before: item.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedBoardID = nil
        return true
    }
}

// MARK: - 5. Task Row & Live Timer

struct TodoRow: View {
    @EnvironmentObject var manager: TodoManager
    let todo: TodoItem
    @State private var currentTime = Date()
    @State private var showingEditSheet = false

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top) {
            Button(action: {
                manager.toggleCompletion(for: todo.id)
            }) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(todo.isCompleted ? .green : .primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(todo.title)
                    .font(.headline)
                    .strikethrough(todo.isCompleted, color: .primary)

                if !todo.isCompleted {
                    Text(timeRemainingString())
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.primary.opacity(0.8))
                } else {
                    Text("Completed")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            Spacer()
        }
        .padding()
        .background(backgroundColor)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TodoRowFramePreferenceKey.self,
                    value: [todo.id: proxy.frame(in: .named("todoScroll"))]
                )
            }
        )
        .onReceive(timer) { time in
            if !todo.isCompleted { currentTime = time }
        }
        .onTapGesture {
            showingEditSheet = true
        }
        .sheet(isPresented: $showingEditSheet) {
            AddEditTodoView(todoToEdit: todo)
        }
    }

    var backgroundColor: Color {
        if todo.isCompleted {
            return Color.green.opacity(0.2)
        }
        let daysLeft = Calendar.current.dateComponents([.day], from: currentTime, to: todo.dueDate).day ?? 0
        if daysLeft < 3 { return Color.red.opacity(0.3) }
        if daysLeft <= 7 { return Color.orange.opacity(0.3) }
        if daysLeft <= 14 { return Color.yellow.opacity(0.3) }
        return Color.green.opacity(0.3)
    }

    func timeRemainingString() -> String {
        let diff = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: currentTime, to: todo.dueDate)
        if currentTime >= todo.dueDate { return "Overdue" }

        var parts: [String] = []
        if let y = diff.year, y > 0 { parts.append("\(y) Year\(y > 1 ? "s" : "")") }
        if let M = diff.month, M > 0 { parts.append("\(M) Month\(M > 1 ? "s" : "")") }
        if let d = diff.day, d > 0 { parts.append("\(d) Day\(d > 1 ? "s" : "")") }
        if let h = diff.hour, h > 0 { parts.append("\(h) Hour\(h > 1 ? "s" : "")") }
        if let m = diff.minute, m > 0 { parts.append("\(m) Minute\(m > 1 ? "s" : "")") }
        if let s = diff.second, s > 0 { parts.append("\(s) Second\(s > 1 ? "s" : "")") }
        return parts.joined(separator: " | ")
    }
}

// MARK: - 6. Add/Edit Popup Window

struct AddEditTodoView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var manager: TodoManager

    var todoToEdit: TodoItem?

    @State private var title: String = ""
    @State private var description: NSAttributedString = NSAttributedString(string: "")
    @State private var dueDate: Date = Date()
    @State private var showDatePopover: Bool = false
    @State private var showDeleteAlert: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text(todoToEdit == nil ? "New Task" : "Edit Task")
                .font(.title2.bold())

            TextField("Task Title", text: $title)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.headline)

            HStack {
                Text("Due Date")
                Spacer()
                Button(action: { showDatePopover.toggle() }) {
                    Text(displayDueDate(dueDate: dueDate))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                    VStack(spacing: 12) {
                        DatePicker("Date", selection: $dueDate, displayedComponents: [.date])
                            .datePickerStyle(.graphical)
                            .frame(minWidth: 300, minHeight: 260)

                        DatePicker("Time", selection: $dueDate, displayedComponents: [.hourAndMinute])
                            .datePickerStyle(.field)
                            .padding(.horizontal)

                        AnalogClockTimePicker(date: $dueDate)
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(naturalLanguageDescription(for: dueDate))
                                .font(.headline)
                            Text(fullDateDescription(for: dueDate))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding([.leading, .trailing, .bottom])
                    }
                    .frame(width: 360)
                }
            }

            VStack(alignment: .leading) {
                Text("Description & Attachments (Images, Rich Text)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                RichTextEditor(text: $description)
                    .frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }

            HStack {
                if todoToEdit != nil {
                    Button("Delete") {
                        showDeleteAlert = true
                    }
                    .foregroundColor(.red)
                }

                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                Spacer()
                Button("Save") {
                    saveTask()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 450, height: 400)
        .onAppear(perform: setupInitialState)
        .alert("Delete Task", isPresented: $showDeleteAlert, actions: {
            Button("Delete", role: .destructive) {
                if let todo = todoToEdit {
                    manager.delete(id: todo.id)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }, message: {
            Text("Are you sure you want to delete this task?")
        })
    }

    func setupInitialState() {
        if let todo = todoToEdit {
            title = todo.title
            description = todo.description
            dueDate = todo.dueDate
        } else {
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = 23
            components.minute = 59
            if let defaultDate = calendar.date(from: components) {
                dueDate = defaultDate
            }
        }
    }

    func saveTask() {
        if let todo = todoToEdit {
            var updated = todo
            updated.title = title
            updated.description = description
            updated.dueDate = dueDate
            manager.update(todo: updated)
        } else {
            let newTodo = TodoItem(title: title, description: description, dueDate: dueDate)
            manager.add(todo: newTodo)
        }
        presentationMode.wrappedValue.dismiss()
    }

    // MARK: - Date helpers
    func naturalLanguageDescription(for date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: startNow, to: startDate).day ?? 0

        let weekday = DateFormatter.localizedString(from: date, dateStyle: .full, timeStyle: .none)

        if dayDiff < 0 {
            let d = abs(dayDiff)
            return d == 1 ? "Yesterday - \(weekday)" : "\(d) days ago - \(weekday)"
        }
        if dayDiff == 0 { return "Today - \(weekday)" }
        if dayDiff == 1 { return "Tomorrow - \(weekday)" }
        if dayDiff <= 6 { return "This \(weekday)" }
        if dayDiff <= 13 { return "Next \(weekday)" }
        if dayDiff <= 30 { return "In \(dayDiff) days - \(weekday)" }

        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        return df.string(from: date)
    }

    func fullDateDescription(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, d MMMM yyyy 'at' h:mm a"
        return df.string(from: date)
    }

    func displayDueDate(dueDate: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let dayDiff = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueDate)).day ?? 0
        let time = DateFormatter.localizedString(from: dueDate, dateStyle: .none, timeStyle: .short)
        if dayDiff == 0 { return "Today, \(time)" }
        if dayDiff == 1 { return "Tomorrow, \(time)" }
        return DateFormatter.localizedString(from: dueDate, dateStyle: .medium, timeStyle: .short)
    }
}

struct AnalogClockTimePicker: View {
    @Binding var date: Date

    private let clockSize: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visual Time Picker")
                .font(.subheadline.weight(.semibold))

            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                let center = CGPoint(x: size / 2, y: size / 2)
                let radius = size / 2
                let minuteAngle = angleForMinute()
                let hourAngle = angleForHour()
                let minuteTip = point(for: minuteAngle, length: radius * 0.78, in: size)
                let hourTip = point(for: hourAngle, length: radius * 0.55, in: size)

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white, Color.blue.opacity(0.08)],
                                center: .center,
                                startRadius: 10,
                                endRadius: radius
                            )
                        )
                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)

                    ForEach(0..<60, id: \.self) { tick in
                        let tickAngle = Double(tick) * 6
                        let isHourMark = tick % 5 == 0
                        let outer = point(for: tickAngle, length: radius * 0.92, in: size)
                        let inner = point(for: tickAngle, length: radius * (isHourMark ? 0.80 : 0.85), in: size)

                        Path { path in
                            path.move(to: inner)
                            path.addLine(to: outer)
                        }
                        .stroke(Color.primary.opacity(isHourMark ? 0.40 : 0.18), lineWidth: isHourMark ? 2.0 : 1.0)
                    }

                    Path { path in
                        path.move(to: center)
                        path.addLine(to: hourTip)
                    }
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))

                    Path { path in
                        path.move(to: center)
                        path.addLine(to: minuteTip)
                    }
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)

                    Circle()
                        .fill(Color.blue)
                        .frame(width: 24, height: 24)
                        .position(hourTip)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    setHour(from: value.location, in: size)
                                }
                        )

                    Circle()
                        .fill(Color.orange)
                        .frame(width: 20, height: 20)
                        .position(minuteTip)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    setMinute(from: value.location, in: size)
                                }
                        )
                }
                .frame(width: size, height: size)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Visual clock for setting due time")
                .accessibilityValue(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))
            }
            .frame(width: clockSize, height: clockSize)
            .frame(maxWidth: .infinity)

            Text("Drag blue handle for hour and orange handle for minute.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func angleForMinute() -> Double {
        let minute = Calendar.current.component(.minute, from: date)
        return Double(minute) * 6
    }

    private func angleForHour() -> Double {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let hour12 = hour % 12
        return Double(hour12) * 30 + Double(minute) * 0.5
    }

    private func point(for angleDegrees: Double, length: CGFloat, in size: CGFloat) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        let center = CGPoint(x: size / 2, y: size / 2)
        let x = center.x + length * CGFloat(sin(radians))
        let y = center.y - length * CGFloat(cos(radians))
        return CGPoint(x: x, y: y)
    }

    private func angle(from location: CGPoint, in size: CGFloat) -> Double {
        let center = CGPoint(x: size / 2, y: size / 2)
        let dx = Double(location.x - center.x)
        let dy = Double(center.y - location.y)
        var degrees = atan2(dx, dy) * 180 / .pi
        if degrees < 0 {
            degrees += 360
        }
        return degrees
    }

    private func setMinute(from location: CGPoint, in size: CGFloat) {
        let degrees = angle(from: location, in: size)
        let minute = Int(round(degrees / 6)) % 60
        updateDate(minute: minute)
    }

    private func setHour(from location: CGPoint, in size: CGFloat) {
        let degrees = angle(from: location, in: size)
        let hour12 = Int(round(degrees / 30)) % 12
        updateDate(hour12: hour12)
    }

    private func updateDate(hour12: Int? = nil, minute: Int? = nil) {
        let calendar = Calendar.current
        let currentHour24 = calendar.component(.hour, from: date)
        let currentMinute = calendar.component(.minute, from: date)

        let isPM = currentHour24 >= 12
        let resolvedHour24: Int = {
            guard let hour12 else { return currentHour24 }
            return (isPM ? 12 : 0) + hour12
        }()

        let resolvedMinute = minute ?? currentMinute

        if let updated = calendar.date(bySettingHour: resolvedHour24, minute: resolvedMinute, second: 0, of: date) {
            date = updated
        }
    }
}
