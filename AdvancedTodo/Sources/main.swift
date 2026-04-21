import SwiftUI
import AppKit
import Combine

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

final class TodoManager: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    private let storageURL: URL
    private var isRestoring = false

    var todos: [TodoItem] = [] {
        didSet { stateDidChange() }
    }

    var selectedCategory: String = "All" {
        didSet { stateDidChange() }
    }

    var scrollAnchorTodoID: UUID? = nil {
        didSet { stateDidChange() }
    }

    init() {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        let directory = applicationSupport.appendingPathComponent("AdvancedTodo", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("state.json")
        loadState()
    }

    var sortedTodos: [TodoItem] {
        todos.sorted { (task1, task2) -> Bool in
            if task1.isCompleted == task2.isCompleted {
                if task1.isCompleted {
                    return (task1.completionDate ?? Date.distantPast) > (task2.completionDate ?? Date.distantPast)
                } else {
                    return task1.dueDate < task2.dueDate
                }
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
        if let index = todos.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.5)) {
                todos[index].isCompleted.toggle()
                todos[index].completionDate = todos[index].isCompleted ? Date() : nil
            }
        }
    }

    func update(todo: TodoItem) {
        if let index = todos.firstIndex(where: { $0.id == todo.id }) {
            withAnimation {
                todos[index] = todo
            }
        }
    }

    func delete(id: UUID) {
        if let index = todos.firstIndex(where: { $0.id == id }) {
            withAnimation {
                todos.remove(at: index)
            }
        }
    }

    func restoreScrollAnchorIfNeeded(_ targetID: UUID?) {
        guard scrollAnchorTodoID != targetID else { return }
        scrollAnchorTodoID = targetID
    }

    private func stateDidChange() {
        guard !isRestoring else { return }
        objectWillChange.send()
        saveState()
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: storageURL) else {
            return
        }
        guard let snapshot = try? JSONDecoder().decode(AppSnapshot.self, from: data) else {
            return
        }

        isRestoring = true
        todos = snapshot.todos.map { $0.makeTodo() }
        selectedCategory = snapshot.selectedCategory
        scrollAnchorTodoID = snapshot.scrollAnchorTodoID
        isRestoring = false
    }

    private func saveState() {
        let snapshot = AppSnapshot(
            todos: todos.map(StoredTodo.init(todo:)),
            selectedCategory: selectedCategory,
            scrollAnchorTodoID: scrollAnchorTodoID,
            mainWindowFrame: nil
        )

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: storageURL, options: [.atomic])
    }
}

// MARK: - 2. Native Rich Text Editor (Supports Images & Cmd+B, Cmd+I)

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 14)
        textView.backgroundColor = NSColor.textBackgroundColor
        
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.attributedString() != text {
            textView.textStorage?.setAttributedString(text)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        init(_ parent: RichTextEditor) { self.parent = parent }
        
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
    @StateObject var todoManager = TodoManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(todoManager)
                .frame(minWidth: minWindowSize.width, minHeight: minWindowSize.height)
                .onAppear {
                    setupFloatingWindow()
                }
        }
    }
    
    var minWindowSize: CGSize {
        if let screen = NSScreen.main {
            return CGSize(width: screen.frame.width / 7, height: screen.frame.height / 4)
        }
        return CGSize(width: 300, height: 400)
    }
    
    func setupFloatingWindow() {
        for window in NSApplication.shared.windows {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {}

// MARK: - 4. Content Views

struct ContentView: View {
    @EnvironmentObject var manager: TodoManager
    @State private var showingAddSheet = false
    @State private var selectedCategory = "All"
    
    let categories = ["All", "Work", "Personal", "Ideas"]
    
    var body: some View {
        NavigationSplitView {
            List(categories, id: \.self, selection: $selectedCategory) { category in
                Text(category).font(.headline)
            }
            .navigationTitle("Categories")
        } detail: {
            ZStack {
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()
                
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(manager.sortedTodos) { todo in
                            TodoRow(todo: todo)
                                .environmentObject(manager)
                                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding()
                }
                
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: { showingAddSheet = true }) {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(Color.blue)
                                .clipShape(Circle())
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .padding()
                    }
                }
            }
            .navigationTitle("Tasks")
        }
        .sheet(isPresented: $showingAddSheet) {
            AddEditTodoView(todoToEdit: nil)
        }
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
        if let y = diff.year, y > 0 { parts.append("\(y) Year\(y>1 ?"s":"")") }
        if let M = diff.month, M > 0 { parts.append("\(M) Month\(M>1 ?"s":"")") }
        if let d = diff.day, d > 0 { parts.append("\(d) Day\(d>1 ?"s":"")") }
        if let h = diff.hour, h > 0 { parts.append("\(h) Hour\(h>1 ?"s":"")") }
        if let m = diff.minute, m > 0 { parts.append("\(m) Minute\(m>1 ?"s":"")") }
        if let s = diff.second, s > 0 { parts.append("\(s) Second\(s>1 ?"s":"")") }
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
            
                    // Custom date selector: popover with graphical calendar + natural-language description
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
                                DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.graphical)
                                    .labelsHidden()
                                    .frame(minWidth: 300, minHeight: 260)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(naturalLanguageDescription(for: dueDate))
                                        .font(.headline)
                                    Text(fullDateDescription(for: dueDate))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding([.leading, .trailing, .bottom])
                            }
                            .frame(width: 340)
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
            return d == 1 ? "Yesterday — \(weekday)" : "\(d) days ago — \(weekday)"
        }
        if dayDiff == 0 { return "Today — \(weekday)" }
        if dayDiff == 1 { return "Tomorrow — \(weekday)" }
        if dayDiff <= 6 { return "This \(weekday)" }
        if dayDiff <= 13 { return "Next \(weekday)" }
        if dayDiff <= 30 { return "In \(dayDiff) days — \(weekday)" }

        // fallback: show month/week/year
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
        if dayDiff == 0 { return "Today" }
        if dayDiff == 1 { return "Tomorrow" }
        if dayDiff < 7 { return DateFormatter.localizedString(from: dueDate, dateStyle: .medium, timeStyle: .short) }
        // otherwise short date with weekday
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d"
        return df.string(from: dueDate)
    }
}
