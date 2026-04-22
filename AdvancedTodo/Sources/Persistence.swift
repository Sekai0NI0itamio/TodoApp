import Foundation
import AppKit

struct BlockerSettings: Codable, Equatable {
    var isEnabled: Bool
    var appMonitoringPermissionGranted: Bool
    var accessibilityPermissionGranted: Bool
    var blockYouTubeVideos: Bool
    var autoCloseTabsOnSecondStrike: Bool
    var blockDurationSeconds: Int
    var preventWindowClose: Bool
    var autoReopenEnabled: Bool
    var autoReopenMinutes: Int
    var blockedApps: [String]
    var blockedWebsites: [String]
    var blockedKeywords: [String]
    var motivationalPhrases: [String]

    static func `default`() -> BlockerSettings {
        BlockerSettings(
            isEnabled: false,
            appMonitoringPermissionGranted: false,
            accessibilityPermissionGranted: false,
            blockYouTubeVideos: false,
            autoCloseTabsOnSecondStrike: true,
            blockDurationSeconds: 60,
            preventWindowClose: true,
            autoReopenEnabled: true,
            autoReopenMinutes: 5,
            blockedApps: [
                // Chat & social
                "Discord", "WeChat", "Instagram", "Telegram", "WhatsApp",
                "Messenger", "Signal", "Slack", "Messages",
                // Short-form video / social media
                "TikTok", "Snapchat",
                // Gaming launchers & games
                "Steam", "Minecraft", "Prism Launcher", "TLauncher",
                "Epic Games Launcher", "GOG Galaxy", "Battle.net",
                "Heroic Games Launcher", "Riot Client", "League of Legends",
                "Origin", "EA", "Roblox",
                // Entertainment
                "Spotify", "Apple Music", "Music", "TV", "Netflix",
                "Prime Video", "Disney+", "Plex", "VLC", "Twitch"
            ],
            blockedWebsites: [
                // Social media
                "instagram.com", "tiktok.com", "facebook.com", "twitter.com",
                "x.com", "snapchat.com", "threads.net", "reddit.com",
                // Video / streaming
                "youtube.com", "twitch.tv", "netflix.com", "primevideo.com",
                "disneyplus.com", "hulu.com",
                // Chat
                "discord.com", "web.whatsapp.com", "web.telegram.org",
                // Other
                "news.ycombinator.com", "9gag.com", "tumblr.com"
            ],
            blockedKeywords: [
                // Short-form video
                "shorts", "reels", "tiktok", "reel",
                // Gaming
                "minecraft", "steam", "roblox", "fortnite", "valorant",
                // Social
                "instagram", "twitter", "reddit", "facebook",
                // Entertainment
                "netflix", "spotify", "twitch"
            ],
            motivationalPhrases: [
                "Small focus now creates big freedom later.",
                "Discipline is a gift to your future self.",
                "Finish what matters before what distracts.",
                "Stay with the work. You are building momentum.",
                "Every minute you protect is a minute invested in your future.",
                "The work is the reward. Start.",
                "You don't need motivation. You need to begin.",
                "Close the tab. Open the task.",
                "Your future self is watching. Make them proud.",
                "One focused hour beats ten distracted ones."
            ]
        )
    }
}

// Codable migration: handle old saves that lack the new accessibilityPermissionGranted field
extension BlockerSettings {
    enum CodingKeys: String, CodingKey {
        case isEnabled
        case appMonitoringPermissionGranted
        case accessibilityPermissionGranted
        case blockYouTubeVideos
        case autoCloseTabsOnSecondStrike
        case blockDurationSeconds
        case preventWindowClose
        case autoReopenEnabled
        case autoReopenMinutes
        case blockedApps
        case blockedWebsites
        case blockedKeywords
        case motivationalPhrases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        appMonitoringPermissionGranted = try c.decodeIfPresent(Bool.self, forKey: .appMonitoringPermissionGranted) ?? false
        accessibilityPermissionGranted = try c.decodeIfPresent(Bool.self, forKey: .accessibilityPermissionGranted) ?? false
        blockYouTubeVideos = try c.decodeIfPresent(Bool.self, forKey: .blockYouTubeVideos) ?? false
        autoCloseTabsOnSecondStrike = try c.decodeIfPresent(Bool.self, forKey: .autoCloseTabsOnSecondStrike) ?? true
        blockDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .blockDurationSeconds) ?? 60
        preventWindowClose = try c.decodeIfPresent(Bool.self, forKey: .preventWindowClose) ?? true
        autoReopenEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoReopenEnabled) ?? true
        autoReopenMinutes = try c.decodeIfPresent(Int.self, forKey: .autoReopenMinutes) ?? 5
        blockedApps = try c.decodeIfPresent([String].self, forKey: .blockedApps) ?? BlockerSettings.default().blockedApps
        blockedWebsites = try c.decodeIfPresent([String].self, forKey: .blockedWebsites) ?? BlockerSettings.default().blockedWebsites
        blockedKeywords = try c.decodeIfPresent([String].self, forKey: .blockedKeywords) ?? BlockerSettings.default().blockedKeywords
        motivationalPhrases = try c.decodeIfPresent([String].self, forKey: .motivationalPhrases) ?? BlockerSettings.default().motivationalPhrases
    }
}

struct WindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct StoredTodo: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var descriptionRTF: Data
    var dueDate: Date
    var isCompleted: Bool
    var completionDate: Date?

    init(todo: TodoItem) {
        id = todo.id
        title = todo.title
        descriptionRTF = todo.description.rtfData() ?? Data()
        dueDate = todo.dueDate
        isCompleted = todo.isCompleted
        completionDate = todo.completionDate
    }

    func makeTodo() -> TodoItem {
        TodoItem(
            id: id,
            title: title,
            description: NSAttributedString.fromRTFData(descriptionRTF),
            dueDate: dueDate,
            isCompleted: isCompleted,
            completionDate: completionDate
        )
    }
}

struct StoredNoteBoard: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var noteBodyRTF: Data

    init(board: NoteBoard) {
        id = board.id
        name = board.name
        noteBodyRTF = board.noteBody.rtfData() ?? Data()
    }

    func makeBoard() -> NoteBoard {
        NoteBoard(id: id, name: name, noteBody: NSAttributedString.fromRTFData(noteBodyRTF))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case noteBodyRTF
        case noteBody
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)

        if let data = try container.decodeIfPresent(Data.self, forKey: .noteBodyRTF) {
            noteBodyRTF = data
        } else {
            let legacy = try container.decodeIfPresent(String.self, forKey: .noteBody) ?? ""
            noteBodyRTF = NSAttributedString(string: legacy).rtfData() ?? Data()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(noteBodyRTF, forKey: .noteBodyRTF)
    }
}

struct StoredTrashedNoteBoard: Codable, Identifiable, Equatable {
    var id: UUID
    var board: StoredNoteBoard
    var deletedAt: Date

    init(item: TrashedNoteBoard) {
        id = item.id
        board = StoredNoteBoard(board: item.board)
        deletedAt = item.deletedAt
    }

    func makeItem() -> TrashedNoteBoard {
        TrashedNoteBoard(id: id, board: board.makeBoard(), deletedAt: deletedAt)
    }
}

struct AppSnapshot: Codable, Equatable {
    var todos: [StoredTodo]
    var selectedCategory: String
    var scrollAnchorTodoID: UUID?
    var mainWindowFrame: WindowFrame?
    var selectedSidebarKey: String?
    var noteBoards: [StoredNoteBoard]?
    var trashedNoteBoards: [StoredTrashedNoteBoard]?
    var blockerSettings: BlockerSettings?
    var debugModeEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case todos
        case selectedCategory
        case scrollAnchorTodoID
        case mainWindowFrame
        case selectedSidebarKey
        case noteBoards
        case trashedNoteBoards
        case blockerSettings
        case debugModeEnabled
    }

    init(
        todos: [StoredTodo],
        selectedCategory: String,
        scrollAnchorTodoID: UUID?,
        mainWindowFrame: WindowFrame?,
        selectedSidebarKey: String?,
        noteBoards: [StoredNoteBoard]?,
        trashedNoteBoards: [StoredTrashedNoteBoard]?,
        blockerSettings: BlockerSettings?,
        debugModeEnabled: Bool?
    ) {
        self.todos = todos
        self.selectedCategory = selectedCategory
        self.scrollAnchorTodoID = scrollAnchorTodoID
        self.mainWindowFrame = mainWindowFrame
        self.selectedSidebarKey = selectedSidebarKey
        self.noteBoards = noteBoards
        self.trashedNoteBoards = trashedNoteBoards
        self.blockerSettings = blockerSettings
        self.debugModeEnabled = debugModeEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        todos = try container.decodeIfPresent([StoredTodo].self, forKey: .todos) ?? []
        selectedCategory = try container.decodeIfPresent(String.self, forKey: .selectedCategory) ?? "todo"
        scrollAnchorTodoID = try container.decodeIfPresent(UUID.self, forKey: .scrollAnchorTodoID)
        mainWindowFrame = try container.decodeIfPresent(WindowFrame.self, forKey: .mainWindowFrame)
        selectedSidebarKey = try container.decodeIfPresent(String.self, forKey: .selectedSidebarKey)
        noteBoards = try container.decodeIfPresent([StoredNoteBoard].self, forKey: .noteBoards)
        trashedNoteBoards = try container.decodeIfPresent([StoredTrashedNoteBoard].self, forKey: .trashedNoteBoards)
        blockerSettings = try container.decodeIfPresent(BlockerSettings.self, forKey: .blockerSettings)
        debugModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugModeEnabled)
    }
}

enum ImportMode: String, Codable {
    case merge
    case replace
    case create
}

struct SidebarExportPackage: Codable {
    var formatVersion: Int = 1
    var exportedAt: Date = Date()
    var sourceSidebarKey: String
    var displayName: String
    var todos: [StoredTodo]?
    var noteBoard: StoredNoteBoard?

    var isTodoPackage: Bool {
        todos != nil
    }
}

extension NSAttributedString {
    func rtfData() -> Data? {
        try? data(from: NSRange(location: 0, length: length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func fromRTFData(_ data: Data) -> NSAttributedString {
        guard !data.isEmpty else { return NSAttributedString(string: "") }
        return (try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )) ?? NSAttributedString(string: "")
    }
}
