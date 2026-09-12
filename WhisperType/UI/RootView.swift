import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: AppDataStore
    @ObservedObject var permissions: PermissionService

    var body: some View {
        Group {
            if store.onboardingComplete {
                appContent
            } else {
                OnboardingView(controller: controller, store: store, permissions: permissions)
            }
        }
        .frame(minWidth: 800, minHeight: 560)
        .tint(.purple)
        .alert("WhisperType", isPresented: Binding(
            get: { controller.lastError != nil },
            set: { if !$0 { controller.lastError = nil } }
        )) {
            Button("OK") { controller.lastError = nil }
        } message: {
            Text(controller.lastError ?? "")
        }
    }

    private var appContent: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $controller.selectedSection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 190, max: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(controller.status.phase == .error ? .red : controller.status.phase == .idle ? .green : .purple)
                            .frame(width: 7, height: 7)
                        Text(controller.status.message)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                }
            }
        } detail: {
            sectionView
                .navigationTitle(controller.selectedSection.title)
                .toolbar {
                    ToolbarItem {
                        Button {
                            controller.startHandsFreeFromMenu()
                        } label: {
                            Label(controller.status.phase == .listening ? "Stop" : "Dictate", systemImage: controller.status.phase == .listening ? "stop.fill" : "mic.fill")
                        }
                        .keyboardShortcut("d", modifiers: [.command, .shift])
                    }
                }
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch controller.selectedSection {
        case .home: HomeView(controller: controller, store: store)
        case .history: HistoryView(controller: controller, store: store)
        case .dictionary: DictionaryView(store: store)
        case .snippets: SnippetsView(store: store)
        case .scratchpad: ScratchpadView(store: store)
        case .styles: StylesView(store: store)
        case .settings: SettingsView(controller: controller, store: store, permissions: permissions)
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: AppDataStore
    @ObservedObject var permissions: PermissionService
    @State private var page = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.purple.opacity(0.18), Color.blue.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()
                Image(systemName: page == 0 ? "waveform.circle.fill" : page == 1 ? "hand.raised.fill" : "keyboard.fill")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.purple.gradient)
                    .contentTransition(.symbolEffect(.replace))

                VStack(spacing: 9) {
                    Text(title).font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 570)
                }

                Group {
                    if page == 0 { welcomeCard }
                    else if page == 1 { permissionsCard }
                    else { shortcutCard }
                }
                .frame(maxWidth: 590)

                HStack {
                    if page > 0 { Button("Back") { withAnimation { page -= 1 } } }
                    Spacer()
                    Button(page == 2 ? "Finish Setup" : "Continue") {
                        if page == 2 { controller.completeOnboarding() }
                        else { withAnimation { page += 1 } }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(page == 1 && (!permissions.microphoneGranted || !permissions.accessibilityGranted))
                }
                .frame(maxWidth: 590)
                Spacer()
            }
            .padding(42)
        }
        .onAppear { controller.refreshPermissions(prompt: false) }
        .onChange(of: page) { _, newPage in
            if newPage == 1 { controller.refreshPermissions(prompt: false) }
        }
    }

    private var title: String {
        ["Meet WhisperType", "Two permissions. Total control.", "Your voice shortcut"][page]
    }
    private var subtitle: String {
        [
            "Private, fast dictation that works anywhere you can type—powered by a modern on-device speech model.",
            "Audio stays on your Mac by default. These permissions let WhisperType hear you and insert text into the app you’re using.",
            "Hold your shortcut to talk and release to insert. Double-tap it for hands-free dictation."
        ][page]
    }

    private var welcomeCard: some View {
        HStack(spacing: 0) {
            FeatureIntro(symbol: "lock.shield.fill", title: "Local first", detail: "Speech transcription runs on your Mac")
            Divider().frame(height: 70)
            FeatureIntro(symbol: "sparkles", title: "Polished", detail: "Filler, formatting, and corrections handled")
            Divider().frame(height: 70)
            FeatureIntro(symbol: "app.badge.checkmark", title: "Every app", detail: "Messages, browsers, editors, and more")
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var permissionsCard: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                PermissionSetupRow(
                    symbol: "mic.fill", title: "Microphone", detail: microphoneDetail,
                    granted: permissions.microphoneGranted,
                    actionTitle: microphoneActionTitle,
                    isWorking: permissions.isRequestingMicrophone,
                    actionDisabled: permissions.microphoneState == .restricted
                ) { Task { await controller.requestMicrophone() } }
                Divider().padding(.leading, 52)
                PermissionSetupRow(
                    symbol: "accessibility", title: "Accessibility", detail: accessibilityDetail,
                    granted: permissions.accessibilityGranted,
                    actionTitle: permissions.accessibilityGranted ? "Granted" : permissions.accessibilitySetupStarted ? "Open Settings" : "Allow",
                    isWorking: false,
                    actionDisabled: false
                ) { controller.requestAccessibility() }
            }
            .padding(.horizontal, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Permission status updates automatically when you return.")
                Spacer()
                Button("Check Again") { controller.refreshPermissions(prompt: false) }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if permissions.accessibilitySetupStarted && !permissions.accessibilityGranted {
                Label("If WhisperType already appears enabled, turn it off and on once so macOS refreshes the installed app’s permission.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if permissions.isRequestingMicrophone {
                Label("Complete the macOS microphone dialog to continue.", systemImage: "macwindow.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var microphoneActionTitle: String {
        if permissions.isRequestingMicrophone { return "Waiting…" }
        switch permissions.microphoneState {
        case .notRequested: return "Allow"
        case .granted: return "Granted"
        case .denied: return "Open Settings"
        case .restricted: return "Unavailable"
        }
    }

    private var microphoneDetail: String {
        switch permissions.microphoneState {
        case .notRequested: "Records only while dictation is active"
        case .granted: "Ready for private, on-device dictation"
        case .denied: "Access is off — enable it in Privacy & Security"
        case .restricted: "Blocked by a system or device policy"
        }
    }

    private var accessibilityDetail: String {
        if permissions.accessibilityGranted { return "Ready to listen for your shortcut and insert text" }
        if permissions.accessibilitySetupStarted { return "Enable WhisperType in System Settings, then return here" }
        return "Listens for your shortcut and inserts text"
    }

    private var shortcutCard: some View {
        VStack(spacing: 18) {
            Text("DEFAULT SHORTCUT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(store.settings.shortcut.displayName)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .padding(.horizontal, 30).padding(.vertical, 14)
                .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Button("Use fn") { store.settings.shortcut = .function }
                Button("⌃  ⌥") { store.settings.shortcut = .controlOption }
                Button("⌃  Space") { store.settings.shortcut = .controlSpace }
                Button("Record another…") { controller.beginShortcutCapture() }
            }
            .buttonStyle(.bordered)
            Text("Command mode uses \(store.settings.commandShortcut.displayName) by default.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct FeatureIntro: View {
    let symbol: String, title: String, detail: String
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.purple)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}

private struct PermissionSetupRow: View {
    let symbol: String, title: String, detail: String
    let granted: Bool
    let actionTitle: String
    let isWorking: Bool
    let actionDisabled: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).frame(width: 26).font(.title3).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Button(actionTitle, action: action).buttonStyle(.borderless).disabled(true)
            } else {
                HStack(spacing: 8) {
                    if isWorking { ProgressView().controlSize(.small) }
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || actionDisabled)
                }
            }
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
        }.padding(.vertical, 14)
    }
}

private struct HomeView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: AppDataStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting).font(.largeTitle.bold())
                    Text("Your voice, ready wherever you type.").font(.title3).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    MetricCard(value: store.totalWords.formatted(), label: "Words dictated", symbol: "text.word.spacing")
                    MetricCard(value: store.averageWordsPerMinute.formatted(), label: "Words per minute", symbol: "speedometer")
                    MetricCard(value: store.currentStreak.formatted(), label: "Day streak", symbol: "flame.fill")
                }
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Start dictating", systemImage: "mic.fill").font(.headline)
                        HStack(spacing: 14) {
                            Text(store.settings.shortcut.displayName)
                                .font(.system(size: 27, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 20).padding(.vertical, 11)
                                .background(.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Hold to talk, release to insert").fontWeight(.medium)
                                Text("Double-tap for hands-free • Esc cancels").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Start hands-free") { controller.startHandsFreeFromMenu() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 14) {
                        Label("Voice commands", systemImage: "wand.and.stars").font(.headline)
                        Text("Hold \(store.settings.commandShortcut.displayName), then say “undo,” “select all,” or tell WhisperType how to rewrite selected text.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(store.settings.commandModeEnabled ? "Command mode is on" : "Enable Command mode in Settings")
                            .font(.caption.weight(.medium)).foregroundStyle(store.settings.commandModeEnabled ? .green : .orange)
                    }
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                RecentTranscripts(controller: controller, store: store)
            }.padding(28)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }
}

private struct MetricCard: View {
    let value: String, label: String, symbol: String
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.purple).frame(width: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title2.bold()).contentTransition(.numericText())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct RecentTranscripts: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: AppDataStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent").font(.title2.bold())
                Spacer()
                if !store.history.isEmpty {
                    Button("View all") { controller.selectedSection = .history }.buttonStyle(.plain).foregroundStyle(.purple)
                }
            }
            if store.history.isEmpty {
                ContentUnavailableView("No dictations yet", systemImage: "waveform", description: Text("Your recent transcripts will appear here."))
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ForEach(store.history.prefix(4)) { entry in
                    TranscriptRow(entry: entry, onCopy: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.finalText, forType: .string) }, onInsert: { controller.insertTranscript(entry) }, onDelete: { store.deleteTranscript(id: entry.id) })
                }
            }
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: AppDataStore
    @State private var search = ""

    private var results: [TranscriptEntry] {
        search.isEmpty ? store.history : store.history.filter {
            $0.finalText.localizedCaseInsensitiveContains(search) || $0.applicationName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search transcripts", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                Spacer()
                Text("\(results.count) dictations").foregroundStyle(.secondary)
                Menu {
                    Button("Export backup…") { controller.exportData() }
                    Divider()
                    Button("Clear history…", role: .destructive) { store.clearHistory() }
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(20)
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(results) { entry in
                            TranscriptRow(entry: entry, onCopy: {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.finalText, forType: .string)
                            }, onInsert: { controller.insertTranscript(entry) }, onDelete: { store.deleteTranscript(id: entry.id) })
                        }
                    }.padding(20)
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let entry: TranscriptEntry
    let onCopy: () -> Void
    let onInsert: () -> Void
    let onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(entry.applicationName, systemImage: entry.mode == .command ? "wand.and.stars" : "app")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(entry.createdAt, style: .relative).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("\(entry.wordCount) words").font(.caption).foregroundStyle(.secondary)
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy")
                Button(action: onInsert) { Image(systemName: "arrow.down.doc") }.buttonStyle(.plain).help("Insert")
                Menu { Button("Delete", role: .destructive, action: onDelete) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Text(entry.finalText)
                .lineLimit(expanded ? nil : 3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if entry.finalText.count > 220 {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.buttonStyle(.plain).font(.caption).foregroundStyle(.purple)
            }
        }
        .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DictionaryView: View {
    @ObservedObject var store: AppDataStore
    @State private var word = ""
    @State private var replacement = ""
    @State private var search = ""

    private var entries: [VocabularyEntry] {
        store.vocabulary
            .filter { search.isEmpty || $0.spoken.localizedCaseInsensitiveContains(search) || ($0.replacement?.localizedCaseInsensitiveContains(search) ?? false) }
            .sorted { ($0.isStarred ? 0 : 1, $0.spoken.lowercased()) < ($1.isStarred ? 0 : 1, $1.spoken.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    TextField("Word or phrase (e.g. WhisperType)", text: $word)
                    TextField("Correct spelling (optional)", text: $replacement)
                    Button("Add") {
                        store.addVocabulary(spoken: word, replacement: replacement)
                        word = ""; replacement = ""
                    }.buttonStyle(.borderedProminent).disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    TextField("Search dictionary", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    Spacer()
                    Text("Words guide recognition; corrections replace recurring mistakes.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("Your personal dictionary", systemImage: "character.book.closed", description: Text("Add names, acronyms, and technical terms to improve recognition immediately."))
            } else {
                List(entries) { entry in
                    HStack {
                        Button {
                            var updated = entry; updated.isStarred.toggle(); store.updateVocabulary(updated)
                        } label: { Image(systemName: entry.isStarred ? "star.fill" : "star").foregroundStyle(entry.isStarred ? .yellow : .secondary) }
                        .buttonStyle(.plain)
                        Text(entry.spoken).fontWeight(.medium)
                        if let replacement = entry.replacement {
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(replacement)
                        }
                        Spacer()
                        Button(role: .destructive) { store.deleteVocabulary(id: entry.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }.padding(.vertical, 5)
                }
            }
        }
    }
}

private struct SnippetsView: View {
    @ObservedObject var store: AppDataStore
    @State private var trigger = ""
    @State private var expansion = ""
    @State private var search = ""

    private var snippets: [Snippet] {
        store.snippets.filter { search.isEmpty || $0.trigger.localizedCaseInsensitiveContains(search) || $0.expansion.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Spoken trigger", text: $trigger).frame(maxWidth: 210)
                    TextField("Expansion text", text: $expansion)
                    Button("Add snippet") {
                        store.addSnippet(trigger: trigger, expansion: expansion); trigger = ""; expansion = ""
                    }.buttonStyle(.borderedProminent).disabled(trigger.isEmpty || expansion.isEmpty)
                }
                HStack {
                    TextField("Search snippets", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    Spacer()
                    Text("Say a trigger naturally inside a longer dictation.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
            Divider()
            if snippets.isEmpty {
                ContentUnavailableView("Create reusable voice shortcuts", systemImage: "text.badge.plus", description: Text("Say “my scheduling link” and insert the full URL or message."))
            } else {
                List(snippets) { snippet in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(snippet.trigger).font(.headline)
                            Spacer()
                            Button(role: .destructive) { store.deleteSnippet(id: snippet.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                        }
                        Text(snippet.expansion).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }.padding(.vertical, 7)
                }
            }
        }
    }
}

private struct ScratchpadView: View {
    @ObservedObject var store: AppDataStore
    @State private var find = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("A private place to capture and shape thoughts.", systemImage: "lock.fill").foregroundStyle(.secondary)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.scratchpad, forType: .string)
                }.disabled(store.scratchpad.isEmpty)
                Button("Clear", role: .destructive) { store.scratchpad = "" }.disabled(store.scratchpad.isEmpty)
            }.padding(16)
            Divider()
            TextEditor(text: $store.scratchpad)
                .font(.system(size: 16, design: .rounded)).scrollContentBackground(.hidden).padding(22)
                .overlay(alignment: .topLeading) {
                    if store.scratchpad.isEmpty {
                        Text("Start writing—or use your dictation shortcut here…").foregroundStyle(.tertiary).padding(28).allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct StylesView: View {
    @ObservedObject var store: AppDataStore
    let columns = [GridItem(.adaptive(minimum: 210), spacing: 14)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose how your spoken thoughts should read. Automatic adapts to the app and nearby text.")
                    .font(.title3).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(WritingStyle.allCases) { style in
                        Button { store.settings.selectedStyle = style } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: styleSymbol(style)).font(.title2).foregroundStyle(.purple)
                                    Spacer()
                                    Image(systemName: store.settings.selectedStyle == style ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(store.settings.selectedStyle == style ? .purple : .secondary)
                                }
                                Text(style.title).font(.headline)
                                Text(style.guidance).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            .padding(17).frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading)
                            .background(store.settings.selectedStyle == style ? Color.purple.opacity(0.1) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
                            .overlay(RoundedRectangle(cornerRadius: 15).stroke(store.settings.selectedStyle == style ? .purple.opacity(0.6) : .clear))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(28)
        }
    }

    private func styleSymbol(_ style: WritingStyle) -> String {
        switch style {
        case .automatic: "wand.and.stars"
        case .polished: "sparkles"
        case .casual: "message"
        case .concise: "scissors"
        case .verbatim: "quote.bubble"
        case .developer: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var store: AppDataStore
    @ObservedObject var permissions: PermissionService
    @State private var apiKey = ""
    @State private var connectionResult = ""
    @State private var isTesting = false

    private let languages: [(String, String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish — Español"),
        ("fr", "French — Français"), ("de", "German — Deutsch"), ("it", "Italian — Italiano"),
        ("pt", "Portuguese — Português"), ("nl", "Dutch — Nederlands"), ("pl", "Polish — Polski"),
        ("uk", "Ukrainian — Українська"), ("ru", "Russian — Русский"), ("zh", "Chinese — 中文"),
        ("ja", "Japanese — 日本語"), ("ko", "Korean — 한국어"), ("hi", "Hindi — हिन्दी"),
        ("ar", "Arabic — العربية"), ("tr", "Turkish — Türkçe")
    ]

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow("Microphone", granted: permissions.microphoneGranted, actionTitle: permissions.microphoneState == .notRequested ? "Allow" : "Open Settings") {
                    Task { await controller.requestMicrophone() }
                }
                permissionRow("Accessibility", granted: permissions.accessibilityGranted, actionTitle: "Open Settings") {
                    controller.requestAccessibility()
                }
                Button("Refresh permission status") { controller.refreshPermissions(prompt: false) }
            }

            Section("Shortcuts") {
                ShortcutSettingRow(title: "Dictation", shortcut: $store.settings.shortcut) { controller.beginShortcutCapture() }
                Toggle("Double-tap for hands-free dictation", isOn: $store.settings.doubleTapHandsFree)
                Toggle("Command mode", isOn: $store.settings.commandModeEnabled)
                if store.settings.commandModeEnabled {
                    ShortcutSettingRow(title: "Voice commands", shortcut: $store.settings.commandShortcut) { controller.beginShortcutCapture(command: true) }
                }
            }

            Section("Transcription") {
                Picker("Language", selection: $store.settings.languageCode) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Translate speech to English", isOn: $store.settings.translateToEnglish)
                Toggle("Smart formatting", isOn: $store.settings.autoFormatting)
                Toggle("Remove filler words", isOn: $store.settings.removeFillers)
                Toggle("Use nearby text and app context", isOn: $store.settings.contextAwareness)
                LabeledContent("Speech model", value: "Whisper large-v3-turbo • Q5 • Metal")
            }

            Section("AI refinement") {
                Picker("Provider", selection: $store.settings.refinementProvider) {
                    ForEach(RefinementProvider.allCases) { provider in Text(provider.title).tag(provider) }
                }
                Text(providerDescription).font(.caption).foregroundStyle(.secondary)
                if store.settings.refinementProvider == .openRouter {
                    SecureField(controller.hasOpenRouterKey() ? "API key saved — enter to replace" : "OpenRouter API key", text: $apiKey)
                    TextField("Model", text: $store.settings.openRouterModel)
                    HStack {
                        Button("Save key") {
                            do { try controller.saveOpenRouterKey(apiKey); apiKey = ""; connectionResult = "Key saved in Keychain" }
                            catch { connectionResult = error.localizedDescription }
                        }.disabled(apiKey.isEmpty)
                        Button("Test connection") {
                            isTesting = true
                            Task { connectionResult = await controller.testOpenRouter(); isTesting = false }
                        }
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(connectionResult).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Experience") {
                Toggle("Show floating dictation overlay", isOn: $store.settings.showOverlay)
                Toggle("Play start and stop sounds", isOn: $store.settings.playSounds)
                Toggle("Launch WhisperType at login", isOn: $store.settings.launchAtLogin)
                Toggle("Archive audio recordings after transcription", isOn: $store.settings.keepAudioForRetry)
                Text("Audio is deleted after successful transcription unless Keep audio is enabled. OpenRouter receives transcript text and limited cursor context only when selected.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Data") {
                HStack {
                    Button("Export backup…") { controller.exportData() }
                    Button("Import backup…") { controller.importData() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var providerDescription: String {
        switch store.settings.refinementProvider {
        case .automatic: "Uses Apple Intelligence when available, otherwise fast local formatting. No account or API key required."
        case .localRules: "Fully offline. Applies punctuation commands, backtracking, snippets, dictionary corrections, and context spacing."
        case .appleIntelligence: "Uses Apple’s on-device model. Requires Apple Intelligence to be enabled and available on this Mac."
        case .openRouter: "Uses your chosen model for the most capable rewriting. Your key is stored in the macOS Keychain."
        }
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Spacer()
            Text(granted ? "Granted" : "Required").foregroundStyle(.secondary)
            if !granted { Button(actionTitle, action: action) }
        }
    }
}

private struct ShortcutSettingRow: View {
    let title: String
    @Binding var shortcut: Shortcut
    let record: () -> Void
    private let presets: [Shortcut] = [.function, .controlOption, .controlSpace, .rightOption]

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Menu(shortcut.displayName) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        shortcut = preset
                    } label: {
                        if shortcut == preset { Label(preset.displayName, systemImage: "checkmark") }
                        else { Text(preset.displayName) }
                    }
                }
                Divider()
                Button("Record shortcut…", action: record)
            }
            .menuStyle(.borderlessButton)
            Button("Record…", action: record).buttonStyle(.bordered)
        }
    }
}
