import SwiftUI
import AppKit
import Combine
import ApplicationServices
import UniformTypeIdentifiers

private let mainWindowName = "AdvancedTodoMainWindow"
private let mainWindowFrameHistoryKey = "AdvancedTodoMainWindow.CustomFrame"
private let settingsWindowFrameAutosaveName = "AdvancedTodoSettingsWindow"
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

private enum SettingsSelection: String {
    case blockerGeneral
    case blockerReminder
    case blockerAutoClose
    case blockerWhitelist
    case window
    case general

    var blockerItem: BlockerSidebarItem? {
        switch self {
        case .blockerGeneral: return .general
        case .blockerReminder: return .reminder
        case .blockerAutoClose: return .autoClose
        case .blockerWhitelist: return .whitelist
        case .window, .general: return nil
        }
    }

    static func from(blockerItem: BlockerSidebarItem) -> SettingsSelection {
        switch blockerItem {
        case .general: return .blockerGeneral
        case .reminder: return .blockerReminder
        case .autoClose: return .blockerAutoClose
        case .whitelist: return .blockerWhitelist
        }
    }
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
    private var lastWarningAt: Date?          // when the first-stage warning was shown
    private var consecutiveShortsStrikes: Int = 0
    private var autoReopenTimer: Timer?
    private var windowClosedAt: Date?

    // MARK: - Focus Session State
    /// Current phase of the focus session timer
    var focusPhase: FocusPhase = .idle {
        didSet { objectWillChange.send() }
    }
    /// When the current phase started
    var focusPhaseStartedAt: Date? = nil {
        didSet { objectWillChange.send() }
    }
    /// Duration of the relax period in seconds
    var focusRelaxSeconds: Int = 0 {
        didSet { objectWillChange.send() }
    }
    /// Duration of the work period in seconds
    var focusWorkSeconds: Int = 0 {
        didSet { objectWillChange.send() }
    }
    /// Menu bar status item for countdown display
    private var menuBarItem: NSStatusItem?
    private var menuBarTimer: Timer?
    /// Whether the reminder popup should reopen (user closed it without choosing)
    var reminderReopenPending: Bool = false {
        didSet { objectWillChange.send() }
    }

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

    /// Incremented to trigger the first-stage warning toast (non-blocking).
    var distractionWarningNonce: Int = 0 {
        didSet {
            if oldValue != distractionWarningNonce {
                objectWillChange.send()
            }
        }
    }

    /// Name shown in the first-stage warning toast.
    var lastWarningDistraction: String = "" {
        didSet {
            if oldValue != lastWarningDistraction {
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
        startScreenTimeTracking()
        
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

        if selectedBoard() == nil && selectedSidebarKey != "todo" && selectedSidebarKey != "trash" && selectedSidebarKey != "reflections" && selectedSidebarKey != "screentime" {
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

        relaunchAppAfterExit(delay: 1.0)
    }

    private func relaunchAppAfterExit(delay: TimeInterval) {
        let helperURL = FileManager.default.temporaryDirectory.appendingPathComponent("advancedtodo-relaunch.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail

        APP_PATH="$1"
        DELAY="$2"

        sleep "$DELAY"
        open -n "$APP_PATH"
        """

        do {
            try script.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = [helperURL.path, Bundle.main.bundleURL.path, String(delay)]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
        } catch {
            if debugModeEnabled {
                print("[Blocker] Failed to schedule relaunch after accessibility grant: \(error.localizedDescription)")
            }
        }
    }

    private func containsBlockerItem(_ item: String, in list: [String]) -> Bool {
        list.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame })
    }

    @discardableResult
    private func insertBlockerItem(_ item: String, into list: inout [String]) -> String? {
        let cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !containsBlockerItem(cleaned, in: list) else { return nil }
        list.append(cleaned)
        return cleaned
    }

    func containsReminderApp(_ app: String) -> Bool {
        containsBlockerItem(app.trimmingCharacters(in: .whitespacesAndNewlines), in: blockerSettings.reminderApps)
    }

    func containsAutoCloseApp(_ app: String) -> Bool {
        containsBlockerItem(app.trimmingCharacters(in: .whitespacesAndNewlines), in: blockerSettings.autoCloseApps)
    }

    func containsReminderWebsite(_ website: String) -> Bool {
        containsBlockerItem(website.trimmingCharacters(in: .whitespacesAndNewlines), in: blockerSettings.reminderWebsites)
    }

    func containsAutoCloseWebsite(_ website: String) -> Bool {
        containsBlockerItem(website.trimmingCharacters(in: .whitespacesAndNewlines), in: blockerSettings.autoCloseWebsites)
    }

    @discardableResult
    func addBlockedApp(_ app: String) -> String? {
        insertBlockerItem(app, into: &blockerSettings.reminderApps)
    }

    func removeBlockedApp(at offsets: IndexSet) {
        blockerSettings.reminderApps.remove(atOffsets: offsets)
    }

    @discardableResult
    func addAutoCloseApp(_ app: String) -> String? {
        insertBlockerItem(app, into: &blockerSettings.autoCloseApps)
    }

    func removeAutoCloseApp(at offsets: IndexSet) {
        blockerSettings.autoCloseApps.remove(atOffsets: offsets)
    }

    @discardableResult
    func addBlockedWebsite(_ website: String) -> String? {
        insertBlockerItem(website, into: &blockerSettings.reminderWebsites)
    }

    func removeBlockedWebsite(at offsets: IndexSet) {
        blockerSettings.reminderWebsites.remove(atOffsets: offsets)
    }

    @discardableResult
    func addAutoCloseWebsite(_ website: String) -> String? {
        insertBlockerItem(website, into: &blockerSettings.autoCloseWebsites)
    }

    func removeAutoCloseWebsite(at offsets: IndexSet) {
        blockerSettings.autoCloseWebsites.remove(atOffsets: offsets)
    }

    @discardableResult
    func addBlockedKeyword(_ keyword: String) -> String? {
        insertBlockerItem(keyword, into: &blockerSettings.blockedKeywords)
    }

    func removeBlockedKeyword(at offsets: IndexSet) {
        blockerSettings.blockedKeywords.remove(atOffsets: offsets)
    }

    @discardableResult
    func addMotivationPhrase(_ phrase: String) -> String? {
        let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        blockerSettings.motivationalPhrases.append(cleaned)
        return cleaned
    }

    func removeMotivationPhrase(at offsets: IndexSet) {
        blockerSettings.motivationalPhrases.remove(atOffsets: offsets)
    }

    func resetBlockerOverviewSettingsToDefault() {
        let defaults = BlockerSettings.default()
        blockerSettings.isEnabled = defaults.isEnabled
        blockerSettings.blockYouTubeVideos = defaults.blockYouTubeVideos
        blockerSettings.blockDurationSeconds = defaults.blockDurationSeconds
    }

    func resetWindowSettingsToDefault() {
        let defaults = BlockerSettings.default()
        blockerSettings.preventWindowClose = defaults.preventWindowClose
        blockerSettings.autoReopenEnabled = defaults.autoReopenEnabled
        blockerSettings.autoReopenMinutes = defaults.autoReopenMinutes
    }

    func resetReminderAppsToDefault() {
        blockerSettings.reminderApps = BlockerSettings.default().reminderApps
    }

    func resetReminderWebsitesToDefault() {
        blockerSettings.reminderWebsites = BlockerSettings.default().reminderWebsites
    }

    func resetReminderCategoryToDefault() {
        let defaults = BlockerSettings.default()
        blockerSettings.reminderApps = defaults.reminderApps
        blockerSettings.reminderWebsites = defaults.reminderWebsites
    }

    func resetAutoCloseAppsToDefault() {
        blockerSettings.autoCloseApps = BlockerSettings.default().autoCloseApps
    }

    func resetAutoCloseWebsitesToDefault() {
        blockerSettings.autoCloseWebsites = BlockerSettings.default().autoCloseWebsites
    }

    func resetAutoCloseCategoryToDefault() {
        let defaults = BlockerSettings.default()
        blockerSettings.autoCloseApps = defaults.autoCloseApps
        blockerSettings.autoCloseWebsites = defaults.autoCloseWebsites
        blockerSettings.autoCloseEnabled = defaults.autoCloseEnabled
    }

    func resetBlockedKeywordsToDefault() {
        blockerSettings.blockedKeywords = BlockerSettings.default().blockedKeywords
    }

    func resetMotivationalPhrasesToDefault() {
        blockerSettings.motivationalPhrases = BlockerSettings.default().motivationalPhrases
    }

    func resetSharedBlockerSupportToDefault() {
        let defaults = BlockerSettings.default()
        blockerSettings.blockedKeywords = defaults.blockedKeywords
        blockerSettings.motivationalPhrases = defaults.motivationalPhrases
    }

    // MARK: - Whitelist management

    func containsWhitelistedApp(_ app: String) -> Bool {
        containsBlockerItem(app.trimmingCharacters(in: .whitespacesAndNewlines), in: blockerSettings.whitelistedApps)
    }

    func containsWhitelistedWebsite(_ website: String) -> Bool {
        containsBlockerItem(website.trimmingCharacters(in: .whitespacesAndNewlines), in: blockerSettings.whitelistedWebsites)
    }

    @discardableResult
    func addWhitelistedApp(_ app: String) -> String? {
        insertBlockerItem(app, into: &blockerSettings.whitelistedApps)
    }

    func removeWhitelistedApp(at offsets: IndexSet) {
        blockerSettings.whitelistedApps.remove(atOffsets: offsets)
    }

    @discardableResult
    func addWhitelistedWebsite(_ website: String) -> String? {
        insertBlockerItem(website, into: &blockerSettings.whitelistedWebsites)
    }

    func removeWhitelistedWebsite(at offsets: IndexSet) {
        blockerSettings.whitelistedWebsites.remove(atOffsets: offsets)
    }

    func resetWhitelistedAppsToDefault() {
        blockerSettings.whitelistedApps = BlockerSettings.default().whitelistedApps
    }

    func resetWhitelistedWebsitesToDefault() {
        blockerSettings.whitelistedWebsites = BlockerSettings.default().whitelistedWebsites
    }

    func resetWhitelistToDefault() {
        let defaults = BlockerSettings.default()
        blockerSettings.whitelistedApps = defaults.whitelistedApps
        blockerSettings.whitelistedWebsites = defaults.whitelistedWebsites
    }

    /// Returns true if the given app name or bundle ID is a Microsoft app that should never be blocked.
    private func isMicrosoftApp(appName: String, bundleID: String) -> Bool {
        let microsoftBundlePrefixes = [
            "com.microsoft.", "com.apple.dt.xcode" // keep Xcode safe too
        ]
        let microsoftNameFragments = [
            "microsoft", "ms teams", "onedrive", "visual studio"
        ]
        let lowerName = appName.lowercased()
        let lowerBundle = bundleID.lowercased()
        if microsoftBundlePrefixes.contains(where: { lowerBundle.hasPrefix($0) }) { return true }
        if microsoftNameFragments.contains(where: { lowerName.contains($0) }) { return true }
        return false
    }

    /// Returns true if the given app name or bundle ID is in the whitelist.
    private func isWhitelistedApp(appName: String, bundleID: String) -> Bool {
        let lower = appName.lowercased()
        let lowerBundle = bundleID.lowercased()
        return blockerSettings.whitelistedApps.contains(where: { entry in
            let needle = entry.lowercased()
            return lower.contains(needle) || lowerBundle.contains(needle)
        })
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

        // ── Whitelist check: skip whitelisted and Microsoft apps ──────────────
        if isMicrosoftApp(appName: appName, bundleID: bundleID) {
            if debugModeEnabled {
                print("[Blocker] Skipping Microsoft app: \(appName)")
            }
            latestDetectedDistraction = nil
            consecutiveShortsStrikes = 0
            return
        }

        if isWhitelistedApp(appName: appName, bundleID: bundleID) {
            if debugModeEnabled {
                print("[Blocker] Skipping whitelisted app: \(appName)")
            }
            latestDetectedDistraction = nil
            consecutiveShortsStrikes = 0
            return
        }

        // ── Layer 1: App name / bundle ID match ──────────────────────────────
        // App-level distractions (Discord, Steam, etc.) are not browser tabs —
        // we show the prompt but never auto-close them.
        if let match = blockerSettings.autoCloseApps.first(where: { blocked in
            let needle = blocked.lowercased()
            return appName.contains(needle) || bundleID.contains(needle)
        }) {
            latestDetectedDistraction = match
            if debugModeEnabled {
                print("[Blocker] Layer 1 match (auto-close app): \(match)")
            }
            handleAutoCloseStrike(match: match, pid: activeApp.processIdentifier) {
                DistractionDetector.closeDistractingApp(pid: activeApp.processIdentifier)
            }
            return
        }

        if let match = blockerSettings.reminderApps.first(where: { blocked in
            let needle = blocked.lowercased()
            return appName.contains(needle) || bundleID.contains(needle)
        }) {
            latestDetectedDistraction = match
            consecutiveShortsStrikes = 0
            if debugModeEnabled {
                print("[Blocker] Layer 1 match (reminder app): \(match)")
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
        // Only run for known browsers — non-browser apps don't have URLs in their titles.
        let isBrowser = DistractionDetector.isBrowserBundleID(bundleID)
        if debugModeEnabled {
            print("[Blocker] Is browser: \(isBrowser)")
        }
        if isBrowser, let windowMatch = DistractionDetector.checkWindowTitles(
            for: activeApp.processIdentifier,
            reminderWebsites: blockerSettings.reminderWebsites,
            autoCloseWebsites: blockerSettings.autoCloseWebsites,
            blockedKeywords: blockerSettings.blockedKeywords,
            blockYouTubeVideos: blockerSettings.blockYouTubeVideos,
            isBrowser: isBrowser,
            whitelistedWebsites: blockerSettings.whitelistedWebsites,
            debugMode: debugModeEnabled
        ) {
            latestDetectedDistraction = windowMatch.label
            if debugModeEnabled {
                print("[Blocker] Layer 2 match (window title): \(windowMatch.label) [\(windowMatch.action == .autoClose ? "auto-close" : "reminder")]")
            }
            handleWebsiteMatch(windowMatch, pid: activeApp.processIdentifier)
            return
        }

        // ── Layer 3: AXUIElement focused window title (needs Accessibility) ───
        if blockerSettings.accessibilityPermissionGranted, AXIsProcessTrusted() {
            if let axMatch = DistractionDetector.checkAXWindowTitle(
                for: activeApp.processIdentifier,
                reminderWebsites: blockerSettings.reminderWebsites,
                autoCloseWebsites: blockerSettings.autoCloseWebsites,
                blockedKeywords: blockerSettings.blockedKeywords,
                blockYouTubeVideos: blockerSettings.blockYouTubeVideos,
                whitelistedWebsites: blockerSettings.whitelistedWebsites,
                isBrowser: isBrowser,
                debugMode: debugModeEnabled
            ) {
                latestDetectedDistraction = axMatch.label
                if debugModeEnabled {
                    print("[Blocker] Layer 3 match (AX title): \(axMatch.label) [\(axMatch.action == .autoClose ? "auto-close" : "reminder")]")
                }
                handleWebsiteMatch(axMatch, pid: activeApp.processIdentifier)
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

    private func handleWebsiteMatch(_ match: DistractionDetector.MatchResult, pid: pid_t) {
        // ── Relax phase: do nothing at all — user is allowed to enjoy entertainment ──
        if focusPhase == .relaxing { return }

        if match.action == .autoClose {
            // During work phase, close immediately without waiting for 2 strikes
            if shouldForceCloseEntertainmentDuringWork() {
                if blockerSettings.autoCloseEnabled,
                   blockerSettings.accessibilityPermissionGranted,
                   AXIsProcessTrusted() {
                    DistractionDetector.closeDistractionTab(pid: pid)
                    lastAutoClosedDistraction = match.label
                    tabAutoClosedNonce += 1
                }
                consecutiveShortsStrikes = 0
                return
            }
            // Idle phase: two-stage warning → prompt
            handleAutoCloseStrike(match: match.label, pid: pid) {
                guard self.blockerSettings.accessibilityPermissionGranted,
                      AXIsProcessTrusted() else { return }
                DistractionDetector.closeDistractionTab(pid: pid)
            }
            return
        }

        consecutiveShortsStrikes = 0

        // ── Work phase: close reminder-only sites immediately too ──
        if shouldForceCloseEntertainmentDuringWork() {
            if blockerSettings.autoCloseEnabled,
               blockerSettings.accessibilityPermissionGranted,
               AXIsProcessTrusted() {
                DistractionDetector.closeDistractionTab(pid: pid)
                lastAutoClosedDistraction = match.label
                tabAutoClosedNonce += 1
            }
            return
        }

        // Idle phase: two-stage warning → prompt
        triggerWarningOrPrompt()
    }

    /// Tracks consecutive auto-close detections and performs configured close action on strike 2.
    private func handleAutoCloseStrike(match: String, pid: pid_t, closeAction: () -> Void) {
        // Relax phase: completely silent
        if focusPhase == .relaxing { return }

        consecutiveShortsStrikes += 1
        if consecutiveShortsStrikes >= 2 {
            consecutiveShortsStrikes = 0
            if blockerSettings.autoCloseEnabled {
                closeAction()
                lastAutoClosedDistraction = match
                tabAutoClosedNonce += 1
            }
        }

        triggerWarningOrPrompt()
    }

    /// Two-stage distraction response (idle phase only):
    ///   Stage 1 — show a non-blocking warning toast, start 60s clock.
    ///   Stage 2 — after 60s of continued distraction, show the full-screen timer picker.
    private func triggerWarningOrPrompt() {
        // Only active during idle (or celebrating — treat same as idle for prompting)
        guard focusPhase == .idle || focusPhase == .celebrating else { return }

        let now = Date()

        // ── Stage 2: full-screen prompt ──────────────────────────────────────
        // Fire if: a warning was already shown AND 60 s have elapsed since it.
        if let warnedAt = lastWarningAt, now.timeIntervalSince(warnedAt) >= 60 {
            // Respect the prompt cooldown so we don't spam if the user keeps
            // dismissing without choosing (reminderReopenPending handles that).
            let promptInterval = TimeInterval(blockerSettings.blockDurationSeconds)
            let promptReady = lastDistractionPromptAt.map { now.timeIntervalSince($0) >= promptInterval } ?? true

            if promptReady || (focusPhase == .idle && reminderReopenPending) {
                lastWarningAt = nil          // reset so next cycle starts fresh
                lastDistractionPromptAt = now
                reminderReopenPending = true
                blockerPromptNonce += 1
                if debugModeEnabled {
                    print("[Blocker] Stage 2 — showing full prompt. Distraction: \(latestDetectedDistraction ?? "none")")
                }
            }
            return
        }

        // ── Stage 1: warning toast ────────────────────────────────────────────
        // Fire only if no warning is currently pending.
        if lastWarningAt == nil {
            lastWarningAt = now
            lastWarningDistraction = latestDetectedDistraction ?? "a distraction"
            distractionWarningNonce += 1
            if debugModeEnabled {
                print("[Blocker] Stage 1 — showing warning toast. Distraction: \(latestDetectedDistraction ?? "none")")
            }
        }
        // If a warning is already pending and < 60 s have passed, do nothing —
        // just wait for the 60 s window to expire.
    }

    // Keep old name as a passthrough so call-sites that call triggerPromptIfNeeded directly still work
    private func triggerPromptIfNeeded() {
        triggerWarningOrPrompt()
    }

    /// Subscribe to workspace notifications so detection fires instantly on app switch,
    /// not just on the poll.
    func startWorkspaceObservation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceAppDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // Start the internal polling timer (adapts speed based on phase)
        startPollingTimer()
    }

    @objc private func workspaceAppDidActivate(_ notification: Notification) {
        evaluateDistraction()
    }

    // MARK: - Internal adaptive polling timer

    private var pollingTimer: Timer?

    /// Starts (or restarts) the polling timer at the correct interval for the current phase.
    /// Work phase → 1 s.  Everything else → 6 s.
    func startPollingTimer() {
        let interval: TimeInterval = (focusPhase == .working) ? 1.0 : 6.0
        // Don't restart if already running at the right interval
        if let existing = pollingTimer, abs(existing.timeInterval - interval) < 0.01 { return }
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.evaluateDistraction()
        }
        RunLoop.main.add(pollingTimer!, forMode: .common)
        if debugModeEnabled {
            print("[Blocker] Polling timer set to \(interval)s (phase: \(focusPhase))")
        }
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

    // MARK: - Focus Session Management

    /// Start a focus session: relax for relaxSeconds, then work for workSeconds.
    func startFocusSession(relaxSeconds: Int, workSeconds: Int) {
        focusRelaxSeconds = relaxSeconds
        focusWorkSeconds = workSeconds
        focusPhaseStartedAt = Date()
        focusPhase = .relaxing
        reminderReopenPending = false   // user made a choice — stop re-opening
        lastWarningAt = nil             // reset warning clock
        lastDistractionPromptAt = Date() // suppress prompt during session
        startMenuBarCountdown()
        startPollingTimer()             // relax → 6 s polling
    }

    /// Called when the relax timer expires — transition to work phase.
    func beginWorkPhase() {
        focusPhaseStartedAt = Date()
        focusPhase = .working
        startMenuBarCountdown()
        startPollingTimer()             // work → 1 s polling
    }

    /// Called when the work timer expires — show celebration.
    func beginCelebrationPhase() {
        focusPhase = .celebrating
        stopMenuBarCountdown()
        // Show the prompt again for the celebration screen
        blockerPromptNonce += 1
    }

    /// Save a reflection and return to idle.
    func saveReflection(description: String, rating: Int) {
        let entry = ReflectionEntry(
            workDescription: description,
            rating: max(1, min(5, rating)),
            relaxMinutes: focusRelaxSeconds / 60,
            workMinutes: focusWorkSeconds / 60
        )
        blockerSettings.reflections.insert(entry, at: 0)
        endFocusSession()
    }

    /// End the session and return to idle.
    func endFocusSession() {
        focusPhase = .idle
        focusPhaseStartedAt = nil
        focusRelaxSeconds = 0
        focusWorkSeconds = 0
        reminderReopenPending = false
        lastWarningAt = nil
        stopMenuBarCountdown()
        lastDistractionPromptAt = nil
        startPollingTimer()             // back to 6 s polling
    }

    /// Seconds remaining in the current phase.
    func focusSecondsRemaining(now: Date) -> Int {
        guard let start = focusPhaseStartedAt else { return 0 }
        let elapsed = Int(now.timeIntervalSince(start))
        switch focusPhase {
        case .relaxing:
            return max(0, focusRelaxSeconds - elapsed)
        case .working:
            return max(0, focusWorkSeconds - elapsed)
        default:
            return 0
        }
    }

    private func startMenuBarCountdown() {
        stopMenuBarCountdown()
        if menuBarItem == nil {
            menuBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        updateMenuBarTitle()
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let remaining = self.focusSecondsRemaining(now: Date())
            self.updateMenuBarTitle()
            if remaining <= 0 {
                DispatchQueue.main.async {
                    switch self.focusPhase {
                    case .relaxing:
                        self.beginWorkPhase()
                    case .working:
                        self.beginCelebrationPhase()
                    default:
                        break
                    }
                }
            }
        }
    }

    private func updateMenuBarTitle() {
        let remaining = focusSecondsRemaining(now: Date())
        let mins = remaining / 60
        let secs = remaining % 60
        let timeStr = String(format: "%d:%02d", mins, secs)
        switch focusPhase {
        case .relaxing:
            menuBarItem?.button?.title = "😌 Relax \(timeStr)"
        case .working:
            menuBarItem?.button?.title = "💪 Work \(timeStr)"
        case .celebrating:
            menuBarItem?.button?.title = "🎉 Done!"
        case .idle:
            menuBarItem?.button?.title = ""
        }
    }

    private func stopMenuBarCountdown() {
        menuBarTimer?.invalidate()
        menuBarTimer = nil
        if let item = menuBarItem {
            NSStatusBar.system.removeStatusItem(item)
            menuBarItem = nil
        }
    }

    /// During work phase, any entertainment detection triggers immediate close (no prompt cooldown).
    func shouldForceCloseEntertainmentDuringWork() -> Bool {
        return focusPhase == .working
    }

    /// Add an app or website to the whitelist from the reminder popup.
    func addToWhitelistFromReminder(name: String, isWebsite: Bool) {
        reminderReopenPending = false   // user made a choice
        lastWarningAt = nil
        if isWebsite {
            addWhitelistedWebsite(name)
        } else {
            addWhitelistedApp(name)
        }
    }

    func deleteReflection(at offsets: IndexSet) {
        blockerSettings.reflections.remove(atOffsets: offsets)
    }

    // MARK: - Screen Time Tracking

    private var screenTimeTimer: Timer?
    private let screenTimeSampleInterval: TimeInterval = 30

    /// Start the 30-second screen-time sampling timer.
    func startScreenTimeTracking() {
        guard screenTimeTimer == nil else { return }
        screenTimeTimer = Timer.scheduledTimer(
            withTimeInterval: screenTimeSampleInterval,
            repeats: true
        ) { [weak self] _ in
            self?.recordScreenTimeSample()
        }
        RunLoop.main.add(screenTimeTimer!, forMode: .common)
    }

    /// Record one 30-second sample for the current frontmost app.
    private func recordScreenTimeSample() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Skip our own app
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        let appName  = app.localizedName ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""

        let isEntertainment = isEntertainmentApp(appName: appName, bundleID: bundleID)
        let isWork = focusPhase == .working

        let sample = AppUsageSample(
            appName: appName,
            bundleID: bundleID,
            timestamp: Date(),
            durationSeconds: Int(screenTimeSampleInterval),
            isEntertainment: isEntertainment,
            isWork: isWork
        )

        blockerSettings.screenTimeSamples.append(sample)
        pruneOldScreenTimeSamples()
    }

    /// Keep only the last 7 days of samples to avoid unbounded growth.
    private func pruneOldScreenTimeSamples() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        blockerSettings.screenTimeSamples.removeAll { $0.timestamp < cutoff }
    }

    /// Returns true if the app is classified as entertainment.
    private func isEntertainmentApp(appName: String, bundleID: String) -> Bool {
        let lower = appName.lowercased()
        let lowerBundle = bundleID.lowercased()
        // Check reminder/auto-close lists
        let inReminder = blockerSettings.reminderApps.contains(where: {
            let n = $0.lowercased(); return lower.contains(n) || lowerBundle.contains(n)
        })
        let inAutoClose = blockerSettings.autoCloseApps.contains(where: {
            let n = $0.lowercased(); return lower.contains(n) || lowerBundle.contains(n)
        })
        // Check keywords
        let inKeyword = blockerSettings.blockedKeywords.contains(where: {
            lower.contains($0.lowercased()) || lowerBundle.contains($0.lowercased())
        })
        return inReminder || inAutoClose || inKeyword
    }

    // MARK: - Screen Time Aggregation

    /// Returns samples for a specific calendar day.
    func screenTimeSamples(for date: Date) -> [AppUsageSample] {
        let cal = Calendar.current
        return blockerSettings.screenTimeSamples.filter {
            cal.isDate($0.timestamp, inSameDayAs: date)
        }
    }

    /// Total seconds the computer was actively used on a given day.
    func totalComputerSeconds(for date: Date) -> Int {
        screenTimeSamples(for: date).reduce(0) { $0 + $1.durationSeconds }
    }

    /// Total entertainment seconds on a given day.
    func entertainmentSeconds(for date: Date) -> Int {
        screenTimeSamples(for: date).filter { $0.isEntertainment }.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Total work-phase seconds on a given day.
    func workSeconds(for date: Date) -> Int {
        screenTimeSamples(for: date).filter { $0.isWork }.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Per-app aggregated usage for a given day, sorted by total time descending.
    func appUsage(for date: Date) -> [DailyAppUsage] {
        let samples = screenTimeSamples(for: date)
        var map: [String: DailyAppUsage] = [:]
        let dayStart = Calendar.current.startOfDay(for: date)

        for s in samples {
            let key = s.bundleID.isEmpty ? s.appName : s.bundleID
            if map[key] == nil {
                map[key] = DailyAppUsage(date: dayStart, appName: s.appName, bundleID: s.bundleID)
            }
            map[key]!.totalSeconds         += s.durationSeconds
            if s.isEntertainment { map[key]!.entertainmentSeconds += s.durationSeconds }
            if s.isWork          { map[key]!.workSeconds          += s.durationSeconds }
        }
        return map.values.sorted { $0.totalSeconds > $1.totalSeconds }
    }

    /// 24 hourly buckets for the activity graph on a given day.
    func hourlyBuckets(for date: Date) -> [HourlyBucket] {
        var buckets = (0..<24).map { HourlyBucket(hour: $0, totalSeconds: 0, entertainmentSeconds: 0, workSeconds: 0) }
        for s in screenTimeSamples(for: date) {
            let hour = Calendar.current.component(.hour, from: s.timestamp)
            buckets[hour].totalSeconds         += s.durationSeconds
            if s.isEntertainment { buckets[hour].entertainmentSeconds += s.durationSeconds }
            if s.isWork          { buckets[hour].workSeconds          += s.durationSeconds }
        }
        return buckets
    }

    /// The last 7 days available in the samples (most recent first).
    func screenTimeDays() -> [Date] {
        let cal = Calendar.current
        var seen = Set<String>()
        var days: [Date] = []
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        for s in blockerSettings.screenTimeSamples.sorted(by: { $0.timestamp > $1.timestamp }) {
            let key = fmt.string(from: s.timestamp)
            if seen.insert(key).inserted {
                days.append(cal.startOfDay(for: s.timestamp))
            }
        }
        return days
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

    enum MatchAction {
        case reminder
        case autoClose
    }

    struct MatchResult {
        let label: String
        let action: MatchAction
    }

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
        reminderWebsites: [String],
        autoCloseWebsites: [String],
        blockedKeywords: [String],
        blockYouTubeVideos: Bool,
        isBrowser: Bool,
        whitelistedWebsites: [String] = [],
        debugMode: Bool = false
    ) -> MatchResult? {
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

            if let match = matchTitle(
                title,
                reminderWebsites: reminderWebsites,
                autoCloseWebsites: autoCloseWebsites,
                blockedKeywords: blockedKeywords,
                blockYouTubeVideos: blockYouTubeVideos,
                whitelistedWebsites: whitelistedWebsites
            ) {
                return match
            }
        }
        return nil
    }

    // ── Layer 3: AXUIElement focused window title ─────────────────────────────
    // More reliable for the exact active tab. Requires Accessibility permission.
    static func checkAXWindowTitle(
        for pid: pid_t,
        reminderWebsites: [String],
        autoCloseWebsites: [String],
        blockedKeywords: [String],
        blockYouTubeVideos: Bool,
        whitelistedWebsites: [String] = [],
        isBrowser: Bool = false,
        debugMode: Bool = false
    ) -> MatchResult? {
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

        // ── URL-bar reading: ONLY for known browsers ──────────────────────────
        // Never walk the AX tree of coding apps, terminals, etc. — they have
        // text fields whose content can accidentally match domain names.
        if isBrowser, let urlString = readBrowserURLFromAX(appElement: appElement, debugMode: debugMode) {
            let lowerURL = urlString.lowercased()
            if debugMode {
                print("[Blocker] Layer 3 browser URL: \(urlString)")
            }

            // Normalise the URL once: strip scheme and www for clean matching
            let normURL = lowerURL
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")

            // Whitelist check on URL
            for site in whitelistedWebsites {
                let needle = normaliseHost(site)
                if normURL.contains(needle) { return nil }
            }

            // YouTube Shorts — URL contains /shorts/ (handle www. prefix too)
            if normURL.hasPrefix("youtube.com/shorts") || normURL.contains("/shorts/") && normURL.contains("youtube") {
                return MatchResult(label: "YouTube Shorts", action: .autoClose)
            }

            // Check auto-close websites against URL (full needle match only)
            for site in autoCloseWebsites {
                let needle = normaliseHost(site)
                if urlMatchesSite(normURL, needle: needle) {
                    return MatchResult(label: site, action: .autoClose)
                }
            }

            // Check reminder websites against URL (full needle match only)
            for site in reminderWebsites {
                let needle = normaliseHost(site)
                if urlMatchesSite(normURL, needle: needle) {
                    return MatchResult(label: site, action: .reminder)
                }
            }

            // URL was read successfully but didn't match anything — clean.
            return nil
        }

        // No URL available (non-browser or URL read failed) — fall back to title matching.
        // Only run title matching for browsers; non-browser apps should never be matched
        // by website rules (they don't have URLs).
        guard isBrowser else { return nil }

        let title = rawTitle.lowercased()
        return matchTitle(
            title,
            reminderWebsites: reminderWebsites,
            autoCloseWebsites: autoCloseWebsites,
            blockedKeywords: blockedKeywords,
            blockYouTubeVideos: blockYouTubeVideos,
            whitelistedWebsites: whitelistedWebsites
        )
    }

    /// Strips scheme and www prefix from a site string for clean matching.
    static func normaliseHost(_ site: String) -> String {
        site.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
    }

    /// Returns true when a normalised URL string (no scheme, no www) contains
    /// the given site needle as a proper host match.
    static func urlMatchesSite(_ normURL: String, needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        // Path-based needles like "youtube.com/shorts" — direct substring is fine
        // because the path makes them specific enough.
        if needle.contains("/") {
            return normURL.contains(needle)
        }
        // Bare domain like "reddit.com", "tiktok.com" — require host boundary so
        // "x.com" doesn't match "example.com" or "ox.com".
        // The normalised URL starts with the host, so check for exact prefix or
        // preceded by a dot (subdomain) or slash.
        return normURL.hasPrefix(needle) ||
               normURL.contains(".\(needle)") ||
               normURL.contains("/\(needle)")
    }

    /// Attempts to read the current URL from a browser's address bar via AX API.
    /// Works with Safari, Chrome, Firefox, Arc, and most Chromium-based browsers.
    static func readBrowserURLFromAX(appElement: AXUIElement, debugMode: Bool = false) -> String? {
        // Strategy 1: Look for a toolbar/address bar with AXURLField or AXTextField role
        // that contains a URL value. Different browsers expose this differently.

        // Try to get all windows
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let frontWindow = windows.first else { return nil }

        return findURLInElement(frontWindow, depth: 0, maxDepth: 8, debugMode: debugMode)
    }

    private static func findURLInElement(_ element: AXUIElement, depth: Int, maxDepth: Int, debugMode: Bool) -> String? {
        guard depth <= maxDepth else { return nil }

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Only inspect text fields and URL fields
        if role == "AXTextField" || role == "AXComboBox" || role == "AXURLField" {
            var valueRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
               let value = valueRef as? String {
                let lower = value.lowercased()
                // Must look like an actual URL — require scheme or www prefix.
                // This prevents file paths, code snippets, etc. from being treated as URLs.
                if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
                    return value
                }
            }
        }

        // Recurse into children
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            if let found = findURLInElement(child, depth: depth + 1, maxDepth: maxDepth, debugMode: debugMode) {
                return found
            }
        }
        return nil
    }

    // ── Shared matching logic ─────────────────────────────────────────────────
    // Used by Layer 2 (CGWindow titles) for browser windows only.
    // Layer 3 uses URL-based matching instead (more accurate).
    static func matchTitle(
        _ title: String,
        reminderWebsites: [String],
        autoCloseWebsites: [String],
        blockedKeywords: [String],
        blockYouTubeVideos: Bool,
        whitelistedWebsites: [String] = []
    ) -> MatchResult? {
        // Whitelist check
        for site in whitelistedWebsites {
            if titleContainsSite(title, site: site) { return nil }
        }

        // YouTube Shorts — title must contain both "youtube" and "shorts" as distinct words
        if titleContainsWord(title, word: "youtube") &&
           (titleContainsWord(title, word: "shorts") || title.contains("#shorts")) {
            return MatchResult(label: "YouTube Shorts", action: .autoClose)
        }

        // YouTube videos (configurable)
        if blockYouTubeVideos && titleContainsWord(title, word: "youtube") && !title.contains("youtube music") {
            return MatchResult(label: "YouTube", action: .reminder)
        }

        // Auto-close websites
        for site in autoCloseWebsites {
            if titleContainsSite(title, site: site) {
                return MatchResult(label: site, action: .autoClose)
            }
        }

        // Reminder websites
        for site in reminderWebsites {
            if titleContainsSite(title, site: site) {
                return MatchResult(label: site, action: .reminder)
            }
        }

        // Blocked keywords
        for keyword in blockedKeywords {
            let kw = keyword.lowercased()
            // Only match keywords that are at least 5 chars to avoid single-letter false positives
            if kw.count >= 5, title.contains(kw) {
                return MatchResult(label: keyword, action: .reminder)
            }
        }

        return nil
    }

    /// Returns true if the window title clearly belongs to the given site.
    /// Uses the full domain name (e.g. "youtube") not just the TLD-stripped base,
    /// and requires it to appear as a recognisable word in the title.
    private static func titleContainsSite(_ title: String, site: String) -> Bool {
        let needle = normaliseHost(site)
        // For path-based entries like "youtube.com/shorts" split on "/" and check all parts
        let parts = needle.components(separatedBy: "/").filter { !$0.isEmpty }
        guard let domain = parts.first else { return false }

        // Extract the meaningful domain word — the part before the first "."
        // e.g. "youtube.com" → "youtube", "x.com" → "x", "reddit.com" → "reddit"
        let domainWord = domain.components(separatedBy: ".").first ?? domain

        // Very short domain words (1-2 chars like "x") are too ambiguous for title matching.
        // They should only be matched via URL (Layer 3), not window title.
        guard domainWord.count >= 3 else { return false }

        // Require the domain word to appear as a recognisable token in the title.
        // We check for word-boundary-like conditions: preceded/followed by space, dash,
        // pipe, dot, or at start/end of string.
        guard titleContainsWord(title, word: domainWord) else { return false }

        // If the site has a path component (e.g. "youtube.com/shorts"), also require
        // all path parts to appear in the title.
        if parts.count > 1 {
            let pathParts = parts.dropFirst()
            return pathParts.allSatisfy { part in
                part.isEmpty || titleContainsWord(title, word: part)
            }
        }
        return true
    }

    /// Returns true if `word` appears in `text` as a recognisable token
    /// (surrounded by non-alphanumeric characters or at string boundaries).
    private static func titleContainsWord(_ text: String, word: String) -> Bool {
        guard !word.isEmpty else { return false }
        guard text.contains(word) else { return false }
        // Walk through all occurrences and check boundaries
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: word, options: .caseInsensitive, range: searchRange) {
            let beforeOK = range.lowerBound == text.startIndex ||
                !text[text.index(before: range.lowerBound)].isLetter
            let afterOK  = range.upperBound == text.endIndex ||
                !text[range.upperBound].isLetter
            if beforeOK && afterOK { return true }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
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

        // Try URL-based verification first (most accurate for YouTube Shorts)
        if let urlString = readBrowserURLFromAX(appElement: appElement) {
            let lowerURL = urlString.lowercased()
            // Only close if the URL is still a distraction (not a work page)
            let isStillDistraction = lowerURL.contains("youtube.com/shorts") ||
                lowerURL.contains("tiktok.com") ||
                lowerURL.contains("instagram.com") ||
                lowerURL.contains("twitter.com") ||
                lowerURL.contains("x.com") ||
                lowerURL.contains("reddit.com") ||
                lowerURL.contains("facebook.com") ||
                lowerURL.contains("snapchat.com") ||
                lowerURL.contains("threads.net") ||
                lowerURL.contains("twitch.tv") ||
                lowerURL.contains("netflix.com") ||
                lowerURL.contains("primevideo.com") ||
                lowerURL.contains("disneyplus.com") ||
                lowerURL.contains("hulu.com") ||
                lowerURL.contains("9gag.com") ||
                lowerURL.contains("tumblr.com")
            guard isStillDistraction else { return }
        } else {
            // Fall back to title-based verification
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(windowElement as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                guard isShortsTypeDistraction(title.lowercased()) else { return }
            }
        }

        // Post Cmd+W key event to the process to close the tab
        let cmdW = CGEvent(keyboardEventSource: nil, virtualKey: 0x0D, keyDown: true)
        cmdW?.flags = .maskCommand
        cmdW?.postToPid(pid)

        let cmdWUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x0D, keyDown: false)
        cmdWUp?.flags = .maskCommand
        cmdWUp?.postToPid(pid)
    }

    static func closeDistractingApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        _ = app.terminate()
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
                        // Wait 3 s so the window is fully visible before showing any update prompt
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
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

// MARK: - Blocker Prompt Window Controller (Full-Screen Intelligent Timer)

final class BlockerPromptWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var manager: TodoManager?

    func show(manager: TodoManager) {
        self.manager = manager

        // Use the full screen frame (not visibleFrame) so we cover the menu bar area too
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        if window == nil {
            let root = BlockerPromptView(manager: manager) { [weak self] in
                self?.hide()
            }
            let host = NSHostingView(rootView: root)

            let promptWindow = NSWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            // Float above everything — higher than .statusBar so it covers the menu bar
            promptWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
            promptWindow.contentView = host
            promptWindow.isReleasedWhenClosed = false
            promptWindow.isOpaque = true
            promptWindow.hasShadow = false
            promptWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            promptWindow.delegate = self
            window = promptWindow
        }

        window?.setFrame(screenFrame, display: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    // Prevent the user from closing the window via keyboard shortcuts
    // when they haven't made a choice yet (idle phase).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let mgr = manager else { return true }
        // Allow close only if a session is already running or we're celebrating
        return mgr.focusPhase != .idle
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(manager: TodoManager) {
        let rootView = SettingsRootView()
            .environmentObject(manager)

        let hostingController = NSHostingController(rootView: rootView)

        if let window {
            window.contentViewController = hostingController
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("AdvancedTodoSettingsWindow")
        window.title = "Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName(settingsWindowFrameAutosaveName)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        if let closedWindow = notification.object as? NSWindow, closedWindow == window {
            window = nil
        }
    }
}

// MARK: - Blocker Prompt View (Intelligent Focus Timer)

struct BlockerPromptView: View {
    @ObservedObject var manager: TodoManager
    let onDismiss: () -> Void

    @State private var now = Date()
    @State private var showTabClosedBanner = false
    @State private var tabClosedBannerText = ""

    // Deep navy background palette
    private let bgColor       = Color(red: 0.06, green: 0.07, blue: 0.12)
    private let cardColor     = Color(red: 0.10, green: 0.12, blue: 0.20)
    private let accentBlue    = Color(red: 0.25, green: 0.55, blue: 1.00)
    private let accentGreen   = Color(red: 0.20, green: 0.80, blue: 0.45)
    private let accentOrange  = Color(red: 1.00, green: 0.60, blue: 0.15)
    private let textPrimary   = Color.white
    private let textSecondary = Color.white.opacity(0.65)

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            switch manager.focusPhase {
            case .idle:
                sessionPickerView
            case .relaxing:
                activeTimerView(phase: .relaxing)
            case .working:
                activeTimerView(phase: .working)
            case .celebrating:
                CelebrationReflectionView(manager: manager, onDismiss: onDismiss)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            now = value
        }
        .onChange(of: manager.tabAutoClosedNonce) { _ in
            tabClosedBannerText = "Closed: \(manager.lastAutoClosedDistraction)"
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { showTabClosedBanner = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                withAnimation(.easeOut(duration: 0.4)) { showTabClosedBanner = false }
            }
        }
        .overlay(alignment: .top) {
            if showTabClosedBanner {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.white)
                    Text(tabClosedBannerText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.red.opacity(0.85)))
                .padding(.top, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // ── Session Picker ────────────────────────────────────────────────────────

    private var sessionPickerView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(accentOrange)

                Text("Distraction Detected")
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .foregroundColor(textPrimary)

                if let distraction = manager.latestDetectedDistraction {
                    Text("You opened: \(distraction)")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(textSecondary)
                }

                Text("Choose a focus plan to continue")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(textSecondary)
                    .padding(.top, 4)
            }

            Spacer().frame(height: 60)

            VStack(spacing: 20) {
                sessionOptionCard(relaxMins: 10, workMins: 30, icon: "🌿", label: "Quick Break",      color: accentGreen)
                sessionOptionCard(relaxMins: 20, workMins: 40, icon: "⚡️", label: "Standard Session", color: accentBlue)
                sessionOptionCard(relaxMins: 30, workMins: 60, icon: "🔥", label: "Deep Work",        color: accentOrange)
            }
            .frame(maxWidth: 700)

            Spacer().frame(height: 40)

            if let distraction = manager.latestDetectedDistraction {
                Button {
                    let isWebsite = distraction.contains(".") ||
                        ["youtube","tiktok","reddit","instagram","twitter","netflix","twitch"]
                            .contains(where: { distraction.lowercased().contains($0) })
                    manager.addToWhitelistFromReminder(name: distraction, isWebsite: isWebsite)
                    onDismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 20))
                        Text("This isn't entertainment — add \"\(distraction)\" to whitelist")
                            .font(.system(size: 20, weight: .medium))
                    }
                    .foregroundColor(textSecondary)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(cardColor)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("You must choose a plan to dismiss this screen.")
                .font(.system(size: 16))
                .foregroundColor(textSecondary.opacity(0.6))
                .padding(.bottom, 30)
        }
        .padding(.horizontal, 60)
    }

    private func sessionOptionCard(relaxMins: Int, workMins: Int, icon: String, label: String, color: Color) -> some View {
        Button {
            manager.startFocusSession(relaxSeconds: relaxMins * 60, workSeconds: workMins * 60)
            onDismiss()
        } label: {
            HStack(spacing: 24) {
                Text(icon).font(.system(size: 48))

                VStack(alignment: .leading, spacing: 6) {
                    Text(label)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(textPrimary)
                    HStack(spacing: 16) {
                        Label("Relax \(relaxMins) min", systemImage: "moon.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(color)
                        Text("→").font(.system(size: 20)).foregroundColor(textSecondary)
                        Label("Work \(workMins) min", systemImage: "bolt.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(textPrimary)
                    }
                }

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(color)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(cardColor)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.45), lineWidth: 2))
            )
        }
        .buttonStyle(.plain)
    }

    // ── Active Timer View ─────────────────────────────────────────────────────

    private func activeTimerView(phase: FocusPhase) -> some View {
        let isRelax = phase == .relaxing
        let phaseColor  = isRelax ? accentGreen : accentOrange
        let phaseIcon   = isRelax ? "moon.fill"  : "bolt.fill"
        let phaseLabel  = isRelax ? "RELAX TIME"  : "WORK TIME"
        let phaseSubtitle = isRelax
            ? "Enjoy your break — entertainment is allowed"
            : "Stay focused — entertainment is being blocked"

        let remaining     = manager.focusSecondsRemaining(now: now)
        let totalSeconds  = isRelax ? manager.focusRelaxSeconds : manager.focusWorkSeconds
        let progress      = totalSeconds > 0 ? Double(totalSeconds - remaining) / Double(totalSeconds) : 0.0
        let mins = remaining / 60
        let secs = remaining % 60
        let timeString = String(format: "%d:%02d", mins, secs)

        return VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 14) {
                Image(systemName: phaseIcon).font(.system(size: 40)).foregroundColor(phaseColor)
                Text(phaseLabel)
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .foregroundColor(phaseColor)
            }

            Spacer().frame(height: 20)

            Text(timeString)
                .font(.system(size: 120, weight: .bold, design: .monospaced))
                .foregroundColor(textPrimary)
                .monospacedDigit()

            Spacer().frame(height: 24)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)).frame(height: 16)
                    RoundedRectangle(cornerRadius: 8).fill(phaseColor)
                        .frame(width: geo.size.width * CGFloat(progress), height: 16)
                        .animation(.linear(duration: 1), value: progress)
                }
            }
            .frame(height: 16)
            .frame(maxWidth: 700)

            Spacer().frame(height: 28)

            Text(phaseSubtitle)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(textSecondary)

            if !isRelax {
                Spacer().frame(height: 16)
                Text("Any entertainment tab will be closed instantly.")
                    .font(.system(size: 20))
                    .foregroundColor(accentOrange.opacity(0.85))
            }

            Spacer()

            if isRelax {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill").foregroundColor(accentOrange)
                    Text("After relax: \(manager.focusWorkSeconds / 60) min work session begins automatically")
                        .font(.system(size: 18))
                        .foregroundColor(textSecondary)
                }
                .padding(.bottom, 40)
            }
        }
        .padding(.horizontal, 80)
    }
}

// MARK: - Celebration & Reflection View

struct CelebrationReflectionView: View {
    @ObservedObject var manager: TodoManager
    let onDismiss: () -> Void

    @State private var workDescription = ""
    @State private var rating = 3

    private let bgColor       = Color(red: 0.06, green: 0.07, blue: 0.12)
    private let cardColor     = Color(red: 0.10, green: 0.12, blue: 0.20)
    private let accentGreen   = Color(red: 0.20, green: 0.80, blue: 0.45)
    private let textPrimary   = Color.white
    private let textSecondary = Color.white.opacity(0.65)

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    Text("🎉").font(.system(size: 80))
                    Text("Work Session Complete!")
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .foregroundColor(textPrimary)
                    Text("You completed \(manager.focusWorkSeconds / 60) minutes of focused work.")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(textSecondary)
                }

                Spacer().frame(height: 50)

                VStack(alignment: .leading, spacing: 20) {
                    Text("Document Your Progress")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(textPrimary)

                    Text("What did you accomplish during this work session?")
                        .font(.system(size: 20))
                        .foregroundColor(textSecondary)

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.15), lineWidth: 1))
                        if workDescription.isEmpty {
                            Text("Describe what you worked on...")
                                .font(.system(size: 18))
                                .foregroundColor(Color.white.opacity(0.3))
                                .padding(16)
                        }
                        TextEditor(text: $workDescription)
                            .font(.system(size: 18))
                            .foregroundColor(textPrimary)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(10)
                    }
                    .frame(height: 140)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Rate this session")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(textPrimary)
                        HStack(spacing: 16) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    rating = star
                                } label: {
                                    Image(systemName: star <= rating ? "star.fill" : "star")
                                        .font(.system(size: 40))
                                        .foregroundColor(star <= rating ? .yellow : Color.white.opacity(0.3))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                            Text(ratingLabel)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(textSecondary)
                        }
                    }

                    HStack {
                        Spacer()
                        Button {
                            manager.saveReflection(description: workDescription, rating: rating)
                            onDismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 22))
                                Text("Submit & Close").font(.system(size: 22, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 16)
                            .background(RoundedRectangle(cornerRadius: 16).fill(accentGreen))
                        }
                        .buttonStyle(.plain)
                        .disabled(workDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(workDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)

                        Button {
                            manager.endFocusSession()
                            onDismiss()
                        } label: {
                            Text("Skip")
                                .font(.system(size: 18))
                                .foregroundColor(textSecondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(cardColor)
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(accentGreen.opacity(0.3), lineWidth: 1.5))
                )
                .frame(maxWidth: 760)

                Spacer()
            }
            .padding(.horizontal, 80)
        }
    }

    private var ratingLabel: String {
        switch rating {
        case 1: return "Rough"
        case 2: return "Okay"
        case 3: return "Good"
        case 4: return "Great"
        case 5: return "Amazing!"
        default: return ""
        }
    }
}

// MARK: - Reflections View

struct ReflectionsView: View {
    @EnvironmentObject var manager: TodoManager

    @State private var showSessionPicker = false
    @State private var relaxMinutes: Int = 10
    @State private var workMinutes: Int = 30

    private let accentGreen  = Color(red: 0.20, green: 0.80, blue: 0.45)
    private let accentBlue   = Color(red: 0.25, green: 0.55, blue: 1.00)
    private let accentOrange = Color(red: 1.00, green: 0.60, blue: 0.15)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reflections")
                        .font(.title2.bold())
                    Text("\(manager.blockerSettings.reflections.count) session\(manager.blockerSettings.reflections.count == 1 ? "" : "s") logged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if manager.focusPhase == .relaxing || manager.focusPhase == .working {
                    // Show live badge when a session is already running
                    activeSessionBadge
                } else {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            showSessionPicker.toggle()
                        }
                    } label: {
                        Label(
                            showSessionPicker ? "Cancel" : "Start Session",
                            systemImage: showSessionPicker ? "xmark.circle" : "play.circle.fill"
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(showSessionPicker ? .secondary : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(showSessionPicker
                                      ? Color.secondary.opacity(0.15)
                                      : accentGreen)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // ── Session Picker Panel ──────────────────────────────────────────
            if showSessionPicker {
                sessionPickerPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // ── Reflections List ──────────────────────────────────────────────
            if manager.blockerSettings.reflections.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No reflections yet.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Complete a focus session to log your first reflection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !showSessionPicker && manager.focusPhase == .idle {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                showSessionPicker = true
                            }
                        } label: {
                            Label("Start your first session", systemImage: "play.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(accentGreen))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(manager.blockerSettings.reflections) { entry in
                        reflectionRow(entry)
                    }
                    .onDelete { offsets in
                        manager.deleteReflection(at: offsets)
                    }
                }
                .listStyle(.inset)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: showSessionPicker)
    }

    // ── Session Picker Panel ──────────────────────────────────────────────────

    private var sessionPickerPanel: some View {
        VStack(alignment: .leading, spacing: 14) {

            Text("Plan your session")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)

            // Quick presets
            HStack(spacing: 8) {
                presetButton(label: "Quick",    icon: "🌿", relax: 10, work: 30, color: accentGreen)
                presetButton(label: "Standard", icon: "⚡️", relax: 20, work: 40, color: accentBlue)
                presetButton(label: "Deep",     icon: "🔥", relax: 30, work: 60, color: accentOrange)
            }
            .padding(.horizontal, 16)

            Divider().padding(.horizontal, 16)

            // Relax row — slider + editable text field
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "moon.fill")
                        .foregroundColor(accentGreen)
                        .frame(width: 18)
                    Text("Relax")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 40, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(relaxMinutes) },
                        set: { relaxMinutes = max(1, min(180, Int($0))) }
                    ), in: 5...60, step: 5)
                    .tint(accentGreen)
                    // Editable minute field — syncs with slider
                    HStack(spacing: 3) {
                        TextField("", value: $relaxMinutes, formatter: minuteFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .onChange(of: relaxMinutes) { v in
                                relaxMinutes = max(1, min(180, v))
                            }
                        Text("min")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 62, alignment: .trailing)
                }

                // Work row — slider + editable text field
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(accentOrange)
                        .frame(width: 18)
                    Text("Work")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 40, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(workMinutes) },
                        set: { workMinutes = max(1, min(480, Int($0))) }
                    ), in: 10...120, step: 5)
                    .tint(accentOrange)
                    HStack(spacing: 3) {
                        TextField("", value: $workMinutes, formatter: minuteFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .onChange(of: workMinutes) { v in
                                workMinutes = max(1, min(480, v))
                            }
                        Text("min")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 62, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)

            // Summary row + launch button
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your plan")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Label("\(relaxMinutes)m relax", systemImage: "moon.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(accentGreen)
                        Text("→")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("\(workMinutes)m work", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(accentOrange)
                    }
                }

                Spacer()

                Button {
                    manager.startFocusSession(
                        relaxSeconds: relaxMinutes * 60,
                        workSeconds:  workMinutes  * 60
                    )
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        showSessionPicker = false
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill").font(.system(size: 11))
                        Text("Begin Session").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(accentGreen))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Formatter that accepts whole-number minutes and rejects non-numeric input.
    private var minuteFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 1
        f.maximum = 480
        f.allowsFloats = false
        return f
    }

    private func presetButton(label: String, icon: String, relax: Int, work: Int, color: Color) -> some View {
        let isSelected = relaxMinutes == relax && workMinutes == work
        return Button {
            relaxMinutes = relax
            workMinutes  = work
        } label: {
            HStack(spacing: 6) {
                Text(icon).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .bold))
                    Text("\(relax)m / \(work)m")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? color.opacity(0.15) : Color(NSColor.windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(isSelected ? color : Color.secondary.opacity(0.2), lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // ── Active session badge ──────────────────────────────────────────────────

    private var activeSessionBadge: some View {
        let isRelax = manager.focusPhase == .relaxing
        let color   = isRelax ? accentGreen : accentOrange
        let label   = isRelax ? "Relaxing…"  : "Working…"
        return HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.12))
        )
    }

    // ── Reflection row ────────────────────────────────────────────────────────

    private func reflectionRow(_ entry: ReflectionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= entry.rating ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundColor(star <= entry.rating ? .yellow : .secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                Label("\(entry.relaxMinutes)m relax", systemImage: "moon.fill")
                    .font(.caption).foregroundColor(accentGreen)
                Label("\(entry.workMinutes)m work", systemImage: "bolt.fill")
                    .font(.caption).foregroundStyle(.primary)
            }
            if !entry.workDescription.isEmpty {
                Text(entry.workDescription)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Screen Time View

struct ScreenTimeView: View {
    @EnvironmentObject var manager: TodoManager
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var now = Date()

    private let accentGreen  = Color(red: 0.20, green: 0.80, blue: 0.45)
    private let accentOrange = Color(red: 1.00, green: 0.60, blue: 0.15)
    private let accentRed    = Color(red: 0.90, green: 0.25, blue: 0.25)
    private let accentBlue   = Color(red: 0.25, green: 0.55, blue: 1.00)

    // ── Computed stats for selected day ──────────────────────────────────────
    private var totalSecs: Int        { manager.totalComputerSeconds(for: selectedDay) }
    private var entertainSecs: Int    { manager.entertainmentSeconds(for: selectedDay) }
    private var workSecs: Int         { manager.workSeconds(for: selectedDay) }
    private var otherSecs: Int        { max(0, totalSecs - entertainSecs - workSecs) }
    private var entertainPct: Double  { totalSecs > 0 ? Double(entertainSecs) / Double(totalSecs) : 0 }
    private var workPct: Double       { totalSecs > 0 ? Double(workSecs)      / Double(totalSecs) : 0 }
    private var appUsage: [DailyAppUsage] { manager.appUsage(for: selectedDay) }
    private var hourly: [HourlyBucket]   { manager.hourlyBuckets(for: selectedDay) }
    private var days: [Date]             { manager.screenTimeDays() }

    /// Health colour: green = mostly work / low entertainment,
    /// orange = moderate entertainment, red = high entertainment / low work.
    private var healthColor: Color {
        if entertainPct < 0.25 { return accentGreen }
        if entertainPct < 0.50 { return accentOrange }
        return accentRed
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDay)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Time")
                        .font(.title2.bold())
                    Text(isToday ? "Today" : selectedDay.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Day picker
                if days.count > 1 {
                    Picker("Day", selection: $selectedDay) {
                        ForEach(days, id: \.self) { day in
                            Text(dayLabel(day)).tag(day)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if totalSecs == 0 {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statCards
                        activityGraph
                        appBreakdown
                    }
                    .padding(16)
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { v in
            now = v
            // Refresh today's data every minute
            if isToday { selectedDay = Calendar.current.startOfDay(for: Date()) }
        }
    }

    // ── Empty state ───────────────────────────────────────────────────────────
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No data yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Screen time is recorded every 30 seconds while the app is running.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // ── Three stat cards ──────────────────────────────────────────────────────
    private var statCards: some View {
        HStack(spacing: 12) {
            statCard(
                icon: "desktopcomputer",
                title: "Computer Use",
                value: formatDuration(totalSecs),
                subtitle: "over 24 hours",
                color: accentBlue
            )
            statCard(
                icon: "tv.fill",
                title: "Entertainment",
                value: formatDuration(entertainSecs),
                subtitle: String(format: "%.0f%% of total", entertainPct * 100),
                color: healthColor
            )
            statCard(
                icon: "bolt.fill",
                title: "Focus Work",
                value: formatDuration(workSecs),
                subtitle: String(format: "%.0f%% of total", workPct * 100),
                color: workPct > 0.3 ? accentGreen : accentOrange
            )
        }
    }

    private func statCard(icon: String, title: String, value: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.2), lineWidth: 1))
        )
    }

    // ── Hourly activity graph ─────────────────────────────────────────────────
    private var activityGraph: some View {
        let maxSecs = hourly.map { $0.totalSeconds }.max() ?? 1
        let currentHour = Calendar.current.component(.hour, from: now)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity Throughout the Day")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // Legend
                HStack(spacing: 10) {
                    legendDot(color: accentBlue,   label: "Other")
                    legendDot(color: accentOrange,  label: "Entertainment")
                    legendDot(color: accentGreen,   label: "Work")
                }
                .font(.system(size: 10))
            }

            GeometryReader { geo in
                let barW = (geo.size.width - CGFloat(23) * 3) / 24
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(hourly, id: \.hour) { bucket in
                        let total = CGFloat(bucket.totalSeconds)
                        let maxH  = geo.size.height - 18
                        let totalH = maxSecs > 0 ? (total / CGFloat(maxSecs)) * maxH : 0
                        let entertainH = total > 0 ? (CGFloat(bucket.entertainmentSeconds) / total) * totalH : 0
                        let workH      = total > 0 ? (CGFloat(bucket.workSeconds)          / total) * totalH : 0
                        let otherH     = max(0, totalH - entertainH - workH)

                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            // Stacked bar: work (bottom) → entertainment → other (top)
                            VStack(spacing: 0) {
                                Rectangle().fill(accentBlue.opacity(0.7)).frame(height: otherH)
                                Rectangle().fill(accentOrange.opacity(0.85)).frame(height: entertainH)
                                Rectangle().fill(accentGreen.opacity(0.9)).frame(height: workH)
                            }
                            .frame(width: barW)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .opacity(isToday && bucket.hour > currentHour ? 0.25 : 1)

                            // Hour label every 4 hours
                            Text(bucket.hour % 4 == 0 ? "\(bucket.hour)" : "")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(height: 14)
                        }
                    }
                }
            }
            .frame(height: 110)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
    }

    // ── Per-app breakdown ─────────────────────────────────────────────────────
    private var appBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App Breakdown")
                .font(.system(size: 13, weight: .semibold))

            if appUsage.isEmpty {
                Text("No app data for this day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let topTotal = appUsage.first?.totalSeconds ?? 1
                ForEach(appUsage.prefix(15)) { usage in
                    appRow(usage, topTotal: topTotal)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private func appRow(_ usage: DailyAppUsage, topTotal: Int) -> some View {
        let barFraction = topTotal > 0 ? CGFloat(usage.totalSeconds) / CGFloat(topTotal) : 0
        let color: Color = usage.entertainmentSeconds > usage.workSeconds
            ? (Double(usage.entertainmentSeconds) / Double(max(1, usage.totalSeconds)) > 0.5 ? accentOrange : accentBlue)
            : accentGreen

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                // App icon placeholder
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(0.2))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Text(String(usage.appName.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(color)
                    )

                Text(usage.appName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text(formatDuration(usage.totalSeconds))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Health dot
                Circle()
                    .fill(usage.entertainmentSeconds > usage.workSeconds ? healthColorFor(usage) : accentGreen)
                    .frame(width: 8, height: 8)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.7))
                        .frame(width: geo.size.width * barFraction, height: 5)
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 3)
    }

    private func healthColorFor(_ usage: DailyAppUsage) -> Color {
        let pct = Double(usage.entertainmentSeconds) / Double(max(1, usage.totalSeconds))
        if pct < 0.25 { return accentGreen }
        if pct < 0.50 { return accentOrange }
        return accentRed
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60  { return "\(seconds)s" }
        let m = seconds / 60
        let h = m / 60
        let rem = m % 60
        if h > 0 { return "\(h)h \(rem)m" }
        return "\(m)m"
    }

    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date)     { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
    @State private var showingCheckpointBrowser = false
    @State private var checkpointRecords: [CheckpointRecord] = []
    @State private var selectedCheckpointID: UUID?
    @State private var latestSidebarSize: CGSize = .zero
    @State private var latestDetailSize: CGSize = .zero
    @State private var blockerPromptController = BlockerPromptWindowController()
    @State private var showWarningBanner = false
    @State private var warningBannerText = ""
    @State private var warningCountdown = 60

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
                            title: "Reflections (\(manager.blockerSettings.reflections.count))",
                            isSelected: manager.selectedSidebarKey == "reflections",
                            isDimmed: manager.blockerSettings.reflections.isEmpty
                        ) {
                            manager.selectedSidebarKey = "reflections"
                        } menu: {
                            EmptyView()
                        }

                        sidebarSelectionRow(
                            title: "Screen Time",
                            isSelected: manager.selectedSidebarKey == "screentime",
                            isDimmed: false
                        ) {
                            manager.selectedSidebarKey = "screentime"
                        } menu: {
                            EmptyView()
                        }

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
                } else if manager.selectedSidebarKey == "reflections" {
                    ReflectionsView()
                        .environmentObject(manager)
                        .frame(maxHeight: .infinity)
                } else if manager.selectedSidebarKey == "screentime" {
                    ScreenTimeView()
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
                            SettingsWindowController.shared.show(manager: manager)
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Check if celebration phase needs to show the prompt
            // (the manager's internal timer handles evaluateDistraction)
            if manager.focusPhase == .celebrating {
                blockerPromptController.show(manager: manager)
            }
        }
        .onChange(of: manager.blockerPromptNonce) { _ in
            // Hide the warning banner — the full prompt is taking over
            withAnimation(.easeOut(duration: 0.3)) { showWarningBanner = false }
            blockerPromptController.show(manager: manager)
        }
        .onChange(of: manager.focusPhase) { phase in
            // When work phase ends and celebration begins, show the prompt
            if phase == .celebrating {
                blockerPromptController.show(manager: manager)
            }
            // When session ends (idle), hide the prompt
            if phase == .idle {
                blockerPromptController.hide()
            }
        }
        .onChange(of: manager.distractionWarningNonce) { _ in
            // Show the first-stage warning banner
            let name = manager.lastWarningDistraction
            warningBannerText = "⚠️  Distraction detected: \(name)"
            warningCountdown = 60
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                showWarningBanner = true
            }
            // Tick the countdown every second and auto-dismiss after 60 s
            // (the full prompt will fire at that point anyway)
            let startNonce = manager.distractionWarningNonce
            func tick(_ remaining: Int) {
                guard remaining > 0, manager.distractionWarningNonce == startNonce else {
                    if manager.distractionWarningNonce == startNonce {
                        withAnimation(.easeOut(duration: 0.4)) { showWarningBanner = false }
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    warningCountdown = remaining - 1
                    tick(remaining - 1)
                }
            }
            tick(60)
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
        // ── First-stage warning banner ────────────────────────────────────────
        .overlay(alignment: .top) {
            if showWarningBanner {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.black)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(warningBannerText)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                        Text("Focus prompt in \(warningCountdown)s — choose a session plan or keep working")
                            .font(.system(size: 12))
                            .foregroundColor(.black.opacity(0.75))
                    }

                    Spacer()

                    // Countdown ring
                    ZStack {
                        Circle()
                            .stroke(Color.black.opacity(0.2), lineWidth: 3)
                            .frame(width: 34, height: 34)
                        Circle()
                            .trim(from: 0, to: CGFloat(warningCountdown) / 60.0)
                            .stroke(Color.black, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 34, height: 34)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: warningCountdown)
                        Text("\(warningCountdown)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                    }

                    Button {
                        withAnimation(.easeOut(duration: 0.3)) { showWarningBanner = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.orange)
                        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
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
    @State private var selection: SettingsSelection = .blockerGeneral
    @State private var blockerExpanded = true

    var body: some View {
        NavigationSplitView {
            List {
                DisclosureGroup(isExpanded: $blockerExpanded) {
                    settingsSidebarRow(
                        title: "General Blocker",
                        systemImage: "square.stack.3d.up",
                        selection: .blockerGeneral
                    )
                    settingsSidebarRow(
                        title: "Reminder Category",
                        systemImage: "bell.badge",
                        selection: .blockerReminder
                    )
                    settingsSidebarRow(
                        title: "Auto Close Category",
                        systemImage: "bolt.shield",
                        selection: .blockerAutoClose
                    )
                    settingsSidebarRow(
                        title: "Whitelist",
                        systemImage: "checkmark.shield",
                        selection: .blockerWhitelist
                    )
                } label: {
                    Label("Blocker", systemImage: "shield.lefthalf.filled")
                        .font(.headline)
                }

                settingsSidebarRow(
                    title: "Window",
                    systemImage: "macwindow",
                    selection: .window
                )
                settingsSidebarRow(
                    title: "General",
                    systemImage: "gearshape",
                    selection: .general
                )
            }
            .navigationTitle("Settings")
        } detail: {
            if let blockerItem = selection.blockerItem {
                BlockerSettingsView(
                    selection: Binding(
                        get: { blockerItem },
                        set: { selection = .from(blockerItem: $0) }
                    )
                )
                    .environmentObject(manager)
            } else if selection == .window {
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
        .frame(minWidth: 820, minHeight: 520)
    }

    @ViewBuilder
    private func settingsSidebarRow(title: String, systemImage: String, selection rowSelection: SettingsSelection) -> some View {
        Button {
            selection = rowSelection
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selection == rowSelection ? Color.accentColor.opacity(0.16) : Color.clear)
    }
}

// MARK: - Window Settings View

struct WindowSettingsView: View {
    @EnvironmentObject var manager: TodoManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Window")
                            .font(.title2.bold())
                        Text("Control how the todo window behaves when closed or minimized.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Reset Window") {
                        manager.resetWindowSettingsToDefault()
                    }
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

enum BlockerSidebarItem: String, CaseIterable, Identifiable {
    case general
    case reminder
    case autoClose
    case whitelist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General Blocker"
        case .reminder: return "Reminder Category"
        case .autoClose: return "Auto Close Category"
        case .whitelist: return "Whitelist"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "All blocker sections in one connected page"
        case .reminder: return "Popup-only apps, sites, and shared rules"
        case .autoClose: return "Force-close rules plus shared blocker lists"
        case .whitelist: return "Apps and sites that are never blocked"
        }
    }
}

// MARK: - Delete Key Handler (NSViewRepresentable for keyboard Delete in lists)

/// Invisible NSView that intercepts the Delete/Backspace key and calls a closure.
/// Used as a .background() on List views where .onKeyPress is unavailable (< macOS 14).
struct DeleteKeyHandler: NSViewRepresentable {
    let onDelete: () -> Void

    func makeNSView(context: Context) -> DeleteKeyNSView {
        let view = DeleteKeyNSView()
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ nsView: DeleteKeyNSView, context: Context) {
        nsView.onDelete = onDelete
    }
}

class DeleteKeyNSView: NSView {
    var onDelete: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Delete (0x33) or Forward Delete (0x75)
        if event.keyCode == 0x33 || event.keyCode == 0x75 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Blocker List Section (macOS-native selection + delete)

/// A reusable list section used throughout the blocker settings.
/// Supports click-to-select, Delete key, toolbar Delete button, and right-click context menu.
struct BlockerListSectionView: View {
    let title: String
    let subtitle: String
    let items: [String]
    let placeholder: String
    @Binding var newValue: String
    let onAdd: () -> Void
    let onDelete: (IndexSet) -> Void
    let onReset: (() -> Void)?
    let onSelectApp: (() -> Void)?

    @State private var selectedItem: String? = nil

    init(
        title: String,
        subtitle: String,
        items: [String],
        placeholder: String,
        newValue: Binding<String>,
        onAdd: @escaping () -> Void,
        onDelete: @escaping (IndexSet) -> Void,
        onReset: (() -> Void)? = nil,
        onSelectApp: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.placeholder = placeholder
        self._newValue = newValue
        self.onAdd = onAdd
        self.onDelete = onDelete
        self.onReset = onReset
        self.onSelectApp = onSelectApp
    }

    private func deleteSelected() {
        guard let selected = selectedItem,
              let idx = items.firstIndex(of: selected) else { return }
        selectedItem = nil
        onDelete(IndexSet(integer: idx))
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Header row
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if selectedItem != nil {
                        Button(role: .destructive) {
                            deleteSelected()
                        } label: {
                            Label("Remove", systemImage: "trash")
                                .font(.caption)
                        }
                        .help("Remove selected item")
                    }
                    if let onReset {
                        Button("Reset", action: onReset)
                            .font(.caption)
                    }
                }

                // List with selection
                List(selection: $selectedItem) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .font(.subheadline)
                            .tag(item)
                            .contextMenu {
                                Button(role: .destructive) {
                                    if let idx = items.firstIndex(of: item) {
                                        onDelete(IndexSet(integer: idx))
                                        if selectedItem == item { selectedItem = nil }
                                    }
                                } label: {
                                    Label("Remove \"\(item)\"", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 150, maxHeight: 220)
                // Handle keyboard Delete / Backspace (macOS 14+)
                .background(
                    DeleteKeyHandler(onDelete: deleteSelected)
                )
                .onChange(of: items) { _ in
                    // Clear selection if the selected item was removed
                    if let sel = selectedItem, !items.contains(sel) {
                        selectedItem = nil
                    }
                }

                // Hint text when nothing is selected
                if !items.isEmpty && selectedItem == nil {
                    Text("Click an item to select it, then press Delete or use the trash button to remove it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Add row
                HStack {
                    TextField(placeholder, text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                onAdd()
                            }
                        }
                    if let onSelectApp {
                        Button("Select App") { onSelectApp() }
                            .help("Browse Applications folder to pick an app")
                    }
                    Button("Add") { onAdd() }
                        .disabled(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BlockerMirrorPrompt {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let action: () -> Void
}

private struct BlockerSectionOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [BlockerSidebarItem: CGFloat] = [:]

    static func reduce(value: inout [BlockerSidebarItem: CGFloat], nextValue: () -> [BlockerSidebarItem: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct BlockerSettingsView: View {
    @EnvironmentObject var manager: TodoManager
    @Binding var selection: BlockerSidebarItem
    @State private var newReminderApp = ""
    @State private var newReminderSite = ""
    @State private var newAutoCloseApp = ""
    @State private var newAutoCloseSite = ""
    @State private var newKeyword = ""
    @State private var newPhrase = ""
    @State private var newWhitelistApp = ""
    @State private var newWhitelistSite = ""
    @State private var pendingMirrorPrompt: BlockerMirrorPrompt?
    @State private var isProgrammaticScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    blockerOverviewSection
                        .id(BlockerSidebarItem.general)
                        .trackBlockerSection(.general)
                    reminderCategorySection(includeSharedSupport: false)
                        .id(BlockerSidebarItem.reminder)
                        .trackBlockerSection(.reminder)
                    autoCloseCategorySection(includeSharedSupport: false)
                        .id(BlockerSidebarItem.autoClose)
                        .trackBlockerSection(.autoClose)
                    whitelistCategorySection
                        .id(BlockerSidebarItem.whitelist)
                        .trackBlockerSection(.whitelist)
                    sharedBlockerSupportSection
                }
                .padding(20)
            }
            .coordinateSpace(name: "BlockerScroll")
            .background(Color(NSColor.textBackgroundColor).opacity(0.001))
            .onPreferenceChange(BlockerSectionOffsetPreferenceKey.self) { offsets in
                guard selection == .general, !isProgrammaticScroll else { return }
                let targetY: CGFloat = 28
                if let nearest = offsets.min(by: { abs($0.value - targetY) < abs($1.value - targetY) })?.key,
                   selection != nearest {
                    selection = nearest
                }
            }
            .onChange(of: selection) { item in
                isProgrammaticScroll = true
                DispatchQueue.main.async {
                    proxy.scrollTo(item, anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isProgrammaticScroll = false
                    }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(selection, anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isProgrammaticScroll = false
                    }
                }
            }
            .modifier(BlockerMirrorAlertModifier(prompt: $pendingMirrorPrompt))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var blockerOverviewSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Focus Blocker")
                        .font(.title2.bold())
                    Text("General Blocker shows every blocker page stitched together. As you scroll through the connected sections, the sidebar follows along so it feels like one continuous setup flow.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset General") {
                    manager.resetBlockerOverviewSettingsToDefault()
                }
            }

            Divider()

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

                    Text("Optional but recommended. Enables reading the exact focused window title via the Accessibility API and now relaunches the app with a detached helper once permission becomes available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Toggle("Also block YouTube videos (not just Shorts)", isOn: Binding(
                        get: { manager.blockerSettings.blockYouTubeVideos },
                        set: { manager.blockerSettings.blockYouTubeVideos = $0 }
                    ))

                    Text("When on, any window titled \"YouTube\" is treated as a distraction, not just Shorts. YouTube Music is excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Block Duration")
                            .font(.headline)

                        Stepper(value: Binding(
                            get: { manager.blockerSettings.blockDurationSeconds },
                            set: { manager.blockerSettings.blockDurationSeconds = max(10, $0) }
                        ), in: 10...600, step: 10) {
                            Text("\(manager.blockerSettings.blockDurationSeconds) seconds")
                                .monospacedDigit()
                        }

                        Text("How long the blocker prompt stays on screen before you can be interrupted again. Default is 60 seconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(4)
            }
        }
    }

    private func reminderCategorySection(includeSharedSupport: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            blockerSectionHeader(
                title: "Reminder Category",
                description: "Detected items here show the blocker popup but are not force-closed. Adding a reminder item now also offers to mirror it into Auto Close.",
                resetTitle: "Reset Reminder",
                onReset: manager.resetReminderCategoryToDefault
            )

            HStack(alignment: .top, spacing: 16) {
                blockerListSection(
                    title: "Reminder Apps",
                    subtitle: "Show reminder popup only for these apps.",
                    items: manager.blockerSettings.reminderApps,
                    placeholder: "App name or bundle ID",
                    newValue: $newReminderApp,
                    onAdd: handleReminderAppAdd,
                    onDelete: manager.removeBlockedApp,
                    onReset: manager.resetReminderAppsToDefault,
                    onSelectApp: {
                        selectAppFromFinder { appName in
                            newReminderApp = appName
                            handleReminderAppAdd()
                        }
                    }
                )

                blockerListSection(
                    title: "Reminder Websites",
                    subtitle: "Show reminder popup only for these websites.",
                    items: manager.blockerSettings.reminderWebsites,
                    placeholder: "Domain or URL fragment",
                    newValue: $newReminderSite,
                    onAdd: handleReminderSiteAdd,
                    onDelete: manager.removeBlockedWebsite,
                    onReset: manager.resetReminderWebsitesToDefault
                )
            }

            if includeSharedSupport {
                sharedBlockerSupportSection
            }
        }
    }

    private func autoCloseCategorySection(includeSharedSupport: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Auto Close Category")
                        .font(.title3.bold())
                    Text("Items here are force-closed on the second consecutive detection. Apps are terminated; browser tabs are closed with Cmd+W. YouTube Shorts and other short-form sites are included by default.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset Auto Close") {
                    manager.resetAutoCloseCategoryToDefault()
                }
            }

            GroupBox {
                Toggle("Enable Auto Close", isOn: Binding(
                    get: { manager.blockerSettings.autoCloseEnabled },
                    set: { manager.blockerSettings.autoCloseEnabled = $0 }
                ))
                .font(.headline)

                Text("When off, items in this list still trigger the reminder popup but are never force-closed or terminated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            HStack(alignment: .top, spacing: 16) {
                blockerListSection(
                    title: "Auto Close Apps",
                    subtitle: "After two consecutive detections, these apps are terminated. Requires Accessibility permission.",
                    items: manager.blockerSettings.autoCloseApps,
                    placeholder: "App name or bundle ID",
                    newValue: $newAutoCloseApp,
                    onAdd: handleAutoCloseAppAdd,
                    onDelete: manager.removeAutoCloseApp,
                    onReset: manager.resetAutoCloseAppsToDefault,
                    onSelectApp: {
                        selectAppFromFinder { appName in
                            newAutoCloseApp = appName
                            handleAutoCloseAppAdd()
                        }
                    }
                )

                blockerListSection(
                    title: "Auto Close Websites",
                    subtitle: "Browser tabs for these sites are closed on the second consecutive detection. YouTube Shorts, TikTok, and other short-form sites are included by default.",
                    items: manager.blockerSettings.autoCloseWebsites,
                    placeholder: "Domain or URL fragment",
                    newValue: $newAutoCloseSite,
                    onAdd: handleAutoCloseSiteAdd,
                    onDelete: manager.removeAutoCloseWebsite,
                    onReset: manager.resetAutoCloseWebsitesToDefault
                )
            }

            if includeSharedSupport {
                sharedBlockerSupportSection
            }
        }
    }

    private var whitelistCategorySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            blockerSectionHeader(
                title: "Whitelist",
                description: "Apps and websites on this list are never blocked, regardless of what appears in the Reminder or Auto Close lists. Microsoft productivity apps are always exempt by default.",
                resetTitle: "Reset Whitelist",
                onReset: manager.resetWhitelistToDefault
            )

            HStack(alignment: .top, spacing: 16) {
                blockerListSection(
                    title: "Whitelisted Apps",
                    subtitle: "These apps will never trigger a reminder or be auto-closed. Use 'Select App' to pick from installed apps.",
                    items: manager.blockerSettings.whitelistedApps,
                    placeholder: "App name or bundle ID",
                    newValue: $newWhitelistApp,
                    onAdd: {
                        if manager.addWhitelistedApp(newWhitelistApp) != nil {
                            newWhitelistApp = ""
                        }
                    },
                    onDelete: manager.removeWhitelistedApp,
                    onReset: manager.resetWhitelistedAppsToDefault,
                    onSelectApp: {
                        selectAppFromFinder { appName in
                            newWhitelistApp = appName
                            if manager.addWhitelistedApp(appName) != nil {
                                newWhitelistApp = ""
                            }
                        }
                    }
                )

                blockerListSection(
                    title: "Whitelisted Websites",
                    subtitle: "These websites will never trigger a reminder or be auto-closed.",
                    items: manager.blockerSettings.whitelistedWebsites,
                    placeholder: "Domain or URL fragment",
                    newValue: $newWhitelistSite,
                    onAdd: {
                        if manager.addWhitelistedWebsite(newWhitelistSite) != nil {
                            newWhitelistSite = ""
                        }
                    },
                    onDelete: manager.removeWhitelistedWebsite,
                    onReset: manager.resetWhitelistedWebsitesToDefault
                )
            }

            GroupBox("How whitelisting works") {
                VStack(alignment: .leading, spacing: 8) {
                    researchRow(icon: "checkmark.shield", text: "Whitelisted apps bypass all detection layers — no popup, no auto-close.")
                    researchRow(icon: "building.2", text: "All Microsoft apps (Word, Excel, Teams, Edge, etc.) are always exempt and never show the reminder window.")
                    researchRow(icon: "app.badge.checkmark", text: "Use 'Select App' to browse your Applications folder and pick an app directly.")
                    researchRow(icon: "globe.badge.chevron.backward", text: "Whitelisted websites override any matching entry in the Reminder or Auto Close lists.")
                }
                .padding(4)
            }
        }
    }

    private func selectAppFromFinder(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select an App to Whitelist"
        panel.message = "Choose an application to add to the whitelist"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Use the app bundle name without extension
            let appName = url.deletingPathExtension().lastPathComponent
            DispatchQueue.main.async {
                completion(appName)
            }
        }
    }

    private var sharedBlockerSupportSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            blockerSectionHeader(
                title: "Shared Blocker Support",
                description: "This was the floating independent blocker area before. It now stays tied into the blocker categories so the shared lists are available wherever you work.",
                resetTitle: "Reset Shared Lists",
                onReset: manager.resetSharedBlockerSupportToDefault
            )

            HStack(alignment: .top, spacing: 16) {
                blockerListSection(
                    title: "Blocked Keywords",
                    subtitle: "Any app whose name or bundle ID contains these words is blocked across the reminder and auto-close flows.",
                    items: manager.blockerSettings.blockedKeywords,
                    placeholder: "Keyword",
                    newValue: $newKeyword,
                    onAdd: {
                        if manager.addBlockedKeyword(newKeyword) != nil {
                            newKeyword = ""
                        }
                    },
                    onDelete: manager.removeBlockedKeyword,
                    onReset: manager.resetBlockedKeywordsToDefault
                )

                blockerListSection(
                    title: "Motivational Phrases",
                    subtitle: "These rotate on the focus reminder popup every 7 seconds.",
                    items: manager.blockerSettings.motivationalPhrases,
                    placeholder: "Add a phrase",
                    newValue: $newPhrase,
                    onAdd: {
                        if manager.addMotivationPhrase(newPhrase) != nil {
                            newPhrase = ""
                        }
                    },
                    onDelete: manager.removeMotivationPhrase,
                    onReset: manager.resetMotivationalPhrasesToDefault
                )
            }

            GroupBox("Personalise your blocklist") {
                VStack(alignment: .leading, spacing: 8) {
                    researchRow(icon: "app.badge", text: "Add any game launcher you use that is not already covered.")
                    researchRow(icon: "globe", text: "Add any social or entertainment site you regularly drift toward in a browser.")
                    researchRow(icon: "arrow.triangle.2.circlepath", text: "When you add a reminder or auto-close item, you can now mirror it into the other category in one step.")
                    researchRow(icon: "checkmark.shield", text: "Grant Accessibility permission to enable auto-close and automatic relaunch after the permission is accepted.")
                }
                .padding(4)
            }
        }
    }

    private func blockerSectionHeader(
        title: String,
        description: String,
        resetTitle: String? = nil,
        onReset: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let resetTitle, let onReset {
                Button(resetTitle, action: onReset)
            }
        }
    }

    private func handleReminderAppAdd() {
        guard let added = manager.addBlockedApp(newReminderApp) else { return }
        newReminderApp = ""
        guard !manager.containsAutoCloseApp(added) else { return }
        pendingMirrorPrompt = BlockerMirrorPrompt(
            title: "Also add to Auto Close?",
            message: "\"\(added)\" was added to Reminder. Do you want to add it to Auto Close too?",
            confirmTitle: "Add to Auto Close"
        ) {
            _ = manager.addAutoCloseApp(added)
        }
    }

    private func handleReminderSiteAdd() {
        guard let added = manager.addBlockedWebsite(newReminderSite) else { return }
        newReminderSite = ""
        guard !manager.containsAutoCloseWebsite(added) else { return }
        pendingMirrorPrompt = BlockerMirrorPrompt(
            title: "Also add to Auto Close?",
            message: "\"\(added)\" was added to Reminder Websites. Do you want to add it to Auto Close Websites too?",
            confirmTitle: "Add to Auto Close"
        ) {
            _ = manager.addAutoCloseWebsite(added)
        }
    }

    private func handleAutoCloseAppAdd() {
        guard let added = manager.addAutoCloseApp(newAutoCloseApp) else { return }
        newAutoCloseApp = ""
        guard !manager.containsReminderApp(added) else { return }
        pendingMirrorPrompt = BlockerMirrorPrompt(
            title: "Also add to Reminder?",
            message: "\"\(added)\" was added to Auto Close. Do you want it to show blocker reminders too?",
            confirmTitle: "Add to Reminder"
        ) {
            _ = manager.addBlockedApp(added)
        }
    }

    private func handleAutoCloseSiteAdd() {
        guard let added = manager.addAutoCloseWebsite(newAutoCloseSite) else { return }
        newAutoCloseSite = ""
        guard !manager.containsReminderWebsite(added) else { return }
        pendingMirrorPrompt = BlockerMirrorPrompt(
            title: "Also add to Reminder?",
            message: "\"\(added)\" was added to Auto Close Websites. Do you want it to also trigger the blocker reminder?",
            confirmTitle: "Add to Reminder"
        ) {
            _ = manager.addBlockedWebsite(added)
        }
    }

    @ViewBuilder
    private func blockerListSection(
        title: String,
        subtitle: String,
        items: [String],
        placeholder: String,
        newValue: Binding<String>,
        onAdd: @escaping () -> Void,
        onDelete: @escaping (IndexSet) -> Void,
        onReset: (() -> Void)? = nil,
        onSelectApp: (() -> Void)? = nil
    ) -> some View {
        BlockerListSectionView(
            title: title,
            subtitle: subtitle,
            items: items,
            placeholder: placeholder,
            newValue: newValue,
            onAdd: onAdd,
            onDelete: onDelete,
            onReset: onReset,
            onSelectApp: onSelectApp
        )
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

private struct BlockerMirrorAlertModifier: ViewModifier {
    @Binding var prompt: BlockerMirrorPrompt?

    func body(content: Content) -> some View {
        content.alert(
            prompt?.title ?? "",
            isPresented: Binding(
                get: { prompt != nil },
                set: { isPresented in
                    if !isPresented {
                        prompt = nil
                    }
                }
            )
        ) {
            Button(prompt?.confirmTitle ?? "Add") {
                prompt?.action()
                prompt = nil
            }
            Button("Not Now", role: .cancel) {
                prompt = nil
            }
        } message: {
            Text(prompt?.message ?? "")
        }
    }
}

private extension View {
    func trackBlockerSection(_ section: BlockerSidebarItem) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: BlockerSectionOffsetPreferenceKey.self,
                    value: [section: geometry.frame(in: .named("BlockerScroll")).minY]
                )
            }
        )
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
