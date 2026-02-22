//
//  LiveTranscriptionView.swift
//  Fluid
//
//  Live transcription view with real-time editing and session management
//

import SwiftUI
import UniformTypeIdentifiers

struct LiveTranscriptionView: View {
    @StateObject private var service: LiveTranscriptionService
    @ObservedObject private var store = LiveTranscriptionStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var editableText: String = ""
    @State private var transcriptionTitle: String = ""
    @State private var customMetadata: [String: String] = [:]
    @State private var showingNewMetadataDialog = false
    @State private var newMetadataKey: String = ""
    @State private var newMetadataValue: String = ""
    @State private var showingClearConfirmation = false
    @State private var showingExportDialog = false
    @State private var exportFormat: ExportFormat = .plainText

    enum ExportFormat {
        case plainText
        case withTimestamps
        case htmlSpans
    }

    @State private var showingDeleteConfirmation: UUID?
    @State private var searchQuery: String = ""
    @State private var showTimestamps: Bool = false
    @State private var showSessionInfo: Bool = false
    @State private var showArchivesSheet: Bool = false
    @State private var showLoadConfirmation: Bool = false
    @State private var sessionToLoad: LiveTranscriptionSession?
    @State private var isSyncingFromService: Bool = false // Track ASR updates vs user edits
    @FocusState private var isEditorFocused: Bool

    init(asrService: ASRService) {
        _service = StateObject(wrappedValue: LiveTranscriptionService(asrService: asrService))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            self.headerView
                .padding()
                .background(self.theme.palette.windowBackground)

            Divider()

            // Main content
            ScrollView {
                VStack(spacing: 20) {
                    // Metadata Panel
                    self.metadataPanel

                    // Editor Section
                    self.editorSection

                    // Control Buttons
                    self.controlButtons
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.windowBackground)
        .sheet(isPresented: self.$showArchivesSheet) {
            self.archivesSheetView
        }
        .confirmationDialog(
            "Save current transcription before loading?",
            isPresented: self.$showLoadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Save & Load") {
                Task {
                    if self.service.isRecording {
                        _ = await self.service.stopAndFinalizeSession()
                    }
                    if let session = self.sessionToLoad {
                        self.loadSession(session)
                        self.showArchivesSheet = false
                    }
                }
            }
            Button("Load Without Saving", role: .destructive) {
                if let session = self.sessionToLoad {
                    self.loadSession(session)
                    self.showArchivesSheet = false
                }
            }
            Button("Cancel", role: .cancel) {
                self.sessionToLoad = nil
            }
        } message: {
            Text("You have \(self.service.currentWordCount) words in your current transcription.")
        }
        .onAppear {
            // Restore any backed-up session
            self.restoreSessionIfNeeded()

            // Initialize title if empty
            if self.transcriptionTitle.isEmpty {
                self.transcriptionTitle = self.generateDefaultTitle()
            }
        }
        .onDisappear {
            // Auto-save current state when leaving view
            if self.service.isRecording {
                Task {
                    // Pause to save state (will auto-save to backup)
                    await self.service.pauseSession()
                }
            }
        }
        .onChange(of: self.service.completedText) { _, _ in
            // Smart sync: allow ASR text to flow in while preserving user edits
            self.updateEditableText(forceUpdate: false)
        }
        .onChange(of: self.showTimestamps) { _, _ in
            // Rebuild text when timestamp display toggles - force update
            self.updateEditableText(forceUpdate: true)
        }
        .onChange(of: self.store.currentSession) { _, session in
            if let session {
                self.customMetadata = session.customMetadata
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("Live Transcription")
                    .font(.title2)
                    .fontWeight(.bold)

                // Editable title field
                TextField("Transcription title...", text: self.$transcriptionTitle)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .onChange(of: self.transcriptionTitle) { _, newValue in
                        self.service.addMetadata(key: "title", value: newValue)
                    }

                HStack(spacing: 6) {
                    if self.service.isRecording {
                        Circle()
                            .fill(self.service.isPaused ? Color.orange : Color.red)
                            .frame(width: 8, height: 8)

                        Text(self.service.isPaused ? "Paused" : "Recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Ready to start")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Always show word count and duration after status
                    if self.service.isRecording || self.service.currentWordCount > 0 {
                        Text("•")
                            .foregroundStyle(.secondary)

                        if self.service.isRecording {
                            Text(self.formatDuration(self.service.elapsedDuration))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("•")
                                .foregroundStyle(.secondary)
                        }

                        Text("\(self.service.currentWordCount) words")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Metadata Panel

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.showSessionInfo.toggle()
                }
            }) {
                HStack {
                    Text("Session Information")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: self.showSessionInfo ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if self.showSessionInfo {
                VStack(spacing: 12) {
                    // Session Status
                    self.metadataRow(
                        label: "Status",
                        value: self.service.isRecording ? (self.service.isPaused ? "Paused" : "Recording") : "Idle"
                    )

                    // Start Time
                    if let startTime = self.service.sessionStartTime {
                        self.metadataRow(
                            label: "Start Time",
                            value: self.formatDateTime(startTime)
                        )
                    }

                    // Duration
                    if self.service.isRecording {
                        self.metadataRow(
                            label: "Duration",
                            value: self.formatDuration(self.service.elapsedDuration)
                        )
                    }

                    // Word Count
                    self.metadataRow(
                        label: "Word Count",
                        value: "\(self.service.currentWordCount)"
                    )

                    // Device Info
                    if let session = self.store.currentSession {
                        self.metadataRow(
                            label: "Microphone",
                            value: session.deviceInfo
                        )
                    }

                    Divider()

                    // Custom Metadata
                    if !self.customMetadata.isEmpty {
                        ForEach(Array(self.customMetadata.keys.sorted()), id: \.self) { key in
                            HStack {
                                self.metadataRow(
                                    label: key,
                                    value: self.customMetadata[key] ?? ""
                                )

                                Button(action: {
                                    self.removeCustomMetadata(key: key)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()
                    }

                    // Add Custom Metadata Button
                    Button(action: {
                        self.showingNewMetadataDialog = true
                    }) {
                        Label("Add Custom Field", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(self.theme.palette.accent)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(self.theme.palette.cardBackground.opacity(0.5))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
        .sheet(isPresented: self.$showingNewMetadataDialog) {
            self.newMetadataDialog
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)

            Spacer()
        }
    }

    private var newMetadataDialog: some View {
        VStack(spacing: 20) {
            Text("Add Custom Field")
                .font(.headline)

            TextField("Field Name", text: self.$newMetadataKey)
                .textFieldStyle(.roundedBorder)

            TextField("Value", text: self.$newMetadataValue)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    self.showingNewMetadataDialog = false
                    self.newMetadataKey = ""
                    self.newMetadataValue = ""
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Add") {
                    self.addCustomMetadata()
                }
                .keyboardShortcut(.return)
                .disabled(self.newMetadataKey.isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }

    // MARK: - Editor Section

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Completed Text (Editable)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Completed Transcription")
                        .font(.headline)

                    Spacer()

                    // Jump to Live button
                    Button(action: {
                        // Exit edit mode: unfocus editor (triggers scroll to bottom)
                        self.isEditorFocused = false
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.to.line")
                            Text("Live")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!self.service.isRecording || self.service.isPaused)
                    .help("Exit edit mode and jump to live transcription")

                    // Copy button
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(self.editableText, forType: .string)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Copy")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(self.editableText.isEmpty)
                    .help("Copy transcription to clipboard")

                    // Timestamp toggle
                    Toggle(isOn: self.$showTimestamps) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text("Timestamps")
                        }
                        .font(.caption)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)

                    Text("✏️ Editable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ScrollViewReader { proxy in
                    // Single text editor with inline timestamps
                    ScrollView {
                        VStack(spacing: 0) {
                            // Always show TextEditor (edit mode)
                            TextEditor(text: self.$editableText)
                                .font(.system(size: 18))
                                .frame(minHeight: 350, alignment: .topLeading)
                                .padding(12)
                                .background(self.theme.palette.contentBackground)
                                .focused(self.$isEditorFocused)
                                .onChange(of: self.editableText) { _, newValue in
                                    // Only save user edits to service (not ASR syncs)
                                    if !self.isSyncingFromService {
                                        self.service.updateCompletedText(newValue)
                                    }
                                }

                            // Invisible anchor at the bottom for scrolling
                            Color.clear
                                .frame(height: 1)
                                .id("editor-bottom")

                            // Padding at bottom so text isn't cut off at edge
                            Spacer()
                                .frame(height: 80)
                        }
                    }
                    .frame(height: 350)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(self.isEditorFocused ? self.theme.palette.accent.opacity(0.5) : self.theme.palette.cardBorder.opacity(0.3), lineWidth: 1)
                    )
                    .onChange(of: self.service.transcriptionSegments) { _, segments in
                        // Auto-scroll when editor not focused
                        if !self.isEditorFocused, !segments.isEmpty {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("editor-bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .onChange(of: self.isEditorFocused) { _, focused in
                        // When editor loses focus (edit mode OFF), scroll to bottom
                        if !focused {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("editor-bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }

            // Live Segment (Read-only, 1-2 lines)
            if self.service.isRecording, !self.service.isPaused {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Currently Transcribing")
                            .font(.headline)

                        Spacer()

                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text("Live")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    // Read-only live text (1-2 lines)
                    Text(self.service.liveSegment.isEmpty ? "Listening..." : self.service.liveSegment)
                        .font(.system(size: 18))
                        .foregroundStyle(self.service.liveSegment.isEmpty ? .secondary : .primary)
                        .italic(self.service.liveSegment.isEmpty)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 50)
                        .padding(12)
                        .background(self.theme.palette.contentBackground.opacity(0.5))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                }
            }
        }
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        HStack(spacing: 12) {
            // Transcribe Toggle Button (simplified play/pause)
            Button(action: {
                Task {
                    if self.service.isPaused {
                        // Resume transcribing (paused state)
                        try? await self.service.resumeSession()
                    } else if self.service.isRecording {
                        // Pause transcribing
                        await self.service.pauseSession()
                    } else {
                        // Start/continue transcribing (will preserve existing text)
                        try? await self.service.startNewSession()
                    }
                }
            }) {
                HStack {
                    Image(systemName: self.service.isRecording && !self.service.isPaused ? "stop.fill" : "mic.fill")
                    Text(self.service.isRecording && !self.service.isPaused ? "Pause" : "Start")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(self.service.isRecording && !self.service.isPaused ? Color.orange : Color.green)
            .keyboardShortcut("r", modifiers: [.command, .shift])

            // Archive & Clear Button (stops current, saves to archives, starts fresh)
            Button(action: {
                Task {
                    if self.service.isRecording {
                        _ = await self.service.stopAndFinalizeSession()
                    }
                    // Clear text for new session
                    self.service.updateCompletedText("")
                    self.editableText = ""
                    self.customMetadata = [:]
                    self.transcriptionTitle = self.generateDefaultTitle()
                    try? await self.service.startNewSession()
                }
            }) {
                Label("Archive & Clear", systemImage: "archivebox.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("Archive current session and start a new blank session")

            // Clear Button (without archiving)
            Button(action: {
                self.showingClearConfirmation = true
            }) {
                Label("Clear", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(self.editableText.isEmpty)
            .help("Clear current transcription without saving")
            .confirmationDialog(
                "Clear current transcription?",
                isPresented: self.$showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) {
                    Task {
                        if self.service.isRecording {
                            await self.service.cancelSession()
                        }
                        self.editableText = ""
                        self.customMetadata = [:]
                        self.transcriptionTitle = self.generateDefaultTitle()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }

            // Archives Button (opens sheet)
            Button(action: {
                self.showArchivesSheet = true
            }) {
                Label("Archives", systemImage: "archivebox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .help("View archived recordings")

            // Export Button
            Menu {
                Button("Plain Text") {
                    self.exportFormat = .plainText
                    self.showingExportDialog = true
                }
                Button("With Timestamps") {
                    self.exportFormat = .withTimestamps
                    self.showingExportDialog = true
                }
                Button("HTML (with timestamp spans)") {
                    self.exportFormat = .htmlSpans
                    self.showingExportDialog = true
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!self.service.isRecording && self.editableText.isEmpty)
            .help("Export transcription to file")
            .fileExporter(
                isPresented: self.$showingExportDialog,
                document: LiveTranscriptionExportDocument(
                    session: self.store.currentSession,
                    format: self.exportFormat,
                    title: self.transcriptionTitle
                ),
                contentType: self.exportFormat == .htmlSpans ? .html : .plainText,
                defaultFilename: self.generateFilename()
            ) { result in
                switch result {
                case let .success(url):
                    DebugLogger.shared.info("Exported session to: \(url.path)", source: "LiveTranscriptionView")
                    AnalyticsService.shared.capture(.liveTranscriptionSaved)
                case let .failure(error):
                    DebugLogger.shared.error("Failed to export session: \(error)", source: "LiveTranscriptionView")
                }
            }
        }
    }

    // MARK: - Archives Sheet

    private var archivesSheetView: some View {
        NavigationStack {
            VStack {
                if self.filteredSessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Archives", systemImage: "archivebox")
                    } description: {
                        Text(self.searchQuery.isEmpty ? "No archived recordings yet" : "No matching recordings")
                    }
                } else {
                    List(self.filteredSessions) { session in
                        self.archiveRow(session)
                    }
                }
            }
            .navigationTitle("Archives")
            .searchable(text: self.$searchQuery, prompt: "Search transcriptions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        self.showArchivesSheet = false
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func archiveRow(_ session: LiveTranscriptionSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(self.theme.palette.accent)

                    Text(session.formattedStartTime)
                        .fontWeight(.medium)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(session.formattedDuration)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text("\(session.wordCount) words")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                Text(session.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    // Check if there's unsaved work
                    if !self.editableText.isEmpty, self.service.currentWordCount > 0 {
                        self.sessionToLoad = session
                        self.showLoadConfirmation = true
                    } else {
                        self.loadSession(session)
                        self.showArchivesSheet = false
                    }
                } label: {
                    Label("Load", systemImage: "arrow.down.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Load this transcription")

                Button(role: .destructive) {
                    self.showingDeleteConfirmation = session.id
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Delete this transcription")
            }
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { self.showingDeleteConfirmation == session.id },
                set: { if !$0 { self.showingDeleteConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                self.store.deleteSession(id: session.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Previous Recordings Section (Deprecated - moved to sheet)

    private var filteredSessions: [LiveTranscriptionSession] {
        if self.searchQuery.isEmpty {
            return self.store.sessions
        }
        return self.store.searchSessions(query: self.searchQuery)
    }

    private var previousRecordingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Previous Recordings")
                    .font(.headline)

                Spacer()

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    TextField("Search...", text: self.$searchQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(self.theme.palette.contentBackground)
                .cornerRadius(6)
                .frame(width: 200)
            }

            if self.filteredSessions.isEmpty {
                Text(self.searchQuery.isEmpty ? "No recordings yet" : "No matching recordings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                VStack(spacing: 8) {
                    ForEach(self.filteredSessions) { session in
                        self.sessionRow(session)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: LiveTranscriptionSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(self.theme.palette.accent)
                        .font(.caption)

                    Text(session.formattedStartTime)
                        .font(.caption)
                        .fontWeight(.medium)

                    Text("•")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Text(session.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Text("\(session.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(session.previewText)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 6) {
                // Load button
                Button(action: {
                    self.loadSession(session)
                }) {
                    Image(systemName: "arrow.down.doc")
                }
                .buttonStyle(.borderless)
                .help("Load session")

                // Delete button
                Button(action: {
                    self.showingDeleteConfirmation = session.id
                }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete session")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(self.theme.palette.cardBorder.opacity(0.3), lineWidth: 1)
                )
        )
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { self.showingDeleteConfirmation == session.id },
                set: { if !$0 { self.showingDeleteConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                self.store.deleteSession(id: session.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Helper Methods

    private func updateEditableText(forceUpdate: Bool = false) {
        // Don't update while user is actively editing (unless forced, like timestamp toggle)
        if self.isEditorFocused, !forceUpdate {
            return
        }

        let newText: String
        if self.showTimestamps {
            // Build text with inline timestamps
            if self.service.transcriptionSegments.isEmpty, !self.service.completedText.isEmpty {
                // Fallback: Parse completedText into paragraphs with generated timestamps
                let paragraphs = self.service.completedText.components(separatedBy: "\n\n").filter { !$0.isEmpty }
                newText = paragraphs.enumerated().map { index, paragraph in
                    let timestamp = self.formatTimestamp(for: index)
                    return "[\(timestamp)] \(paragraph)"
                }.joined(separator: "\n\n")
            } else if !self.service.transcriptionSegments.isEmpty {
                // Use actual segments with real timestamps
                newText = self.service.transcriptionSegments.map { segment in
                    "[\(segment.timestamp)] \(segment.text)"
                }.joined(separator: "\n\n")
            } else {
                newText = ""
            }
        } else {
            // Use plain completed text from service
            newText = self.service.completedText
        }

        // Simple: Just update from service (user edits go directly to service anyway)
        if newText != self.editableText {
            self.isSyncingFromService = true
            self.editableText = newText
            DispatchQueue.main.async {
                self.isSyncingFromService = false
            }
        }
    }

    private func formatTimestamp(for index: Int) -> String {
        // Generate placeholder timestamps for segments without real timing data
        // Use session start time if available, otherwise current time
        let baseTime = self.service.sessionStartTime ?? Date()
        let segmentTime = baseTime.addingTimeInterval(TimeInterval(index * 5)) // 5 seconds apart

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: segmentTime)
    }

    private func addCustomMetadata() {
        let key = self.newMetadataKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = self.newMetadataValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !key.isEmpty else { return }

        self.customMetadata[key] = value
        self.service.addMetadata(key: key, value: value)

        self.showingNewMetadataDialog = false
        self.newMetadataKey = ""
        self.newMetadataValue = ""
    }

    private func removeCustomMetadata(key: String) {
        self.customMetadata.removeValue(forKey: key)
        self.service.removeMetadata(key: key)
    }

    private func loadSession(_ session: LiveTranscriptionSession) {
        self.editableText = session.transcribedText
        self.customMetadata = session.customMetadata
        self.transcriptionTitle = session.customMetadata["title"] ?? session.formattedStartTime

        AnalyticsService.shared.capture(.liveTranscriptionLoaded)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func generateDefaultTitle() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        return dateFormatter.string(from: Date())
    }

    private func generateFilename() -> String {
        // Use title if available, otherwise use timestamp
        let safeName = self.transcriptionTitle.isEmpty ? self.generateDefaultTitle() : self.transcriptionTitle
        let sanitized = safeName.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return "\(sanitized).md"
    }

    private func restoreSessionIfNeeded() {
        // Try to restore a backed-up session
        self.store.restoreCurrentSessionBackup()

        // If we have a restored session, load it into the view
        if let session = self.store.currentSession {
            self.editableText = session.transcribedText
            self.customMetadata = session.customMetadata
            self.transcriptionTitle = session.customMetadata["title"] ?? session.formattedStartTime

            // IMPORTANT: Explicitly sync buffer to prevent clearing on next start
            self.service.updateCompletedText(session.transcribedText)

            // Note: We don't auto-resume recording, user must explicitly resume
            // This prevents accidentally recording when returning to the view

            DebugLogger.shared.info("Restored session from backup with \(session.wordCount) words", source: "LiveTranscriptionView")
        }
    }
}

// MARK: - File Document

struct LiveTranscriptionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText, .html]
    }

    let session: LiveTranscriptionSession?
    let format: LiveTranscriptionView.ExportFormat
    let title: String

    init(session: LiveTranscriptionSession?, format: LiveTranscriptionView.ExportFormat, title: String) {
        self.session = session
        self.format = format
        self.title = title
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let session = self.session else {
            throw NSError(
                domain: "LiveTranscriptionView",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No active session"]
            )
        }

        let content: String = switch self.format {
        case .plainText:
            self.exportPlainText(session)
        case .withTimestamps:
            self.exportWithTimestamps(session)
        case .htmlSpans:
            self.exportHTML(session)
        }

        let data = Data(content.utf8)
        return FileWrapper(regularFileWithContents: data)
    }

    private func exportPlainText(_ session: LiveTranscriptionSession) -> String {
        var output = "# \(self.title)\n\n"
        output += session.transcribedText
        return output
    }

    private func exportWithTimestamps(_ session: LiveTranscriptionSession) -> String {
        // Build YAML frontmatter
        var frontmatter = """
        ---
        id: \(session.id.uuidString)
        title: "\(self.title)"
        start_time: "\(ISO8601DateFormatter().string(from: session.startTime))"
        """

        if let endTime = session.endTime {
            frontmatter += "\nend_time: \"\(ISO8601DateFormatter().string(from: endTime))\""
        }

        frontmatter += """

        duration: \(Int(session.duration))
        word_count: \(session.wordCount)
        segment_count: \(session.segments.count)
        app_name: "\(session.appName)"
        device_info: "\(session.deviceInfo)"
        """

        // Add custom metadata
        for (key, value) in session.customMetadata.sorted(by: { $0.key < $1.key }) where key != "title" {
            frontmatter += "\n\(key): \"\(value)\""
        }

        frontmatter += "\n---\n\n"

        var output = frontmatter
        output += "# \(self.title)\n\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        // Export each segment with timestamps
        for segment in session.segments {
            let start = formatter.string(from: segment.startTime)
            let end = formatter.string(from: segment.endTime)
            output += "[\(start) - \(end)] \(segment.text)\n\n"
        }

        // If no segments, fall back to plain text
        if session.segments.isEmpty {
            output += session.transcribedText
        }

        return output
    }

    private func exportHTML(_ session: LiveTranscriptionSession) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>\(self.title)</title>
            <style>
                body { font-family: system-ui; line-height: 1.6; max-width: 800px; margin: 40px auto; padding: 0 20px; }
                h1 { margin-bottom: 30px; }
                .segment { margin-bottom: 0.5em; }
                .segment span { cursor: pointer; }
                .segment span:hover { background-color: #f0f0f0; }
            </style>
        </head>
        <body>
            <h1>\(self.title)</h1>
            <div class="transcription">
        """

        // Use segments with timestamp spans
        if !session.segments.isEmpty {
            for segment in session.segments {
                let startMs = String(format: "%.3f", segment.startTime.timeIntervalSince1970)
                let endMs = String(format: "%.3f", segment.endTime.timeIntervalSince1970)
                let start = formatter.string(from: segment.startTime)
                let end = formatter.string(from: segment.endTime)

                html += "        <p class=\"segment\"><span data-start=\"\(start)\" data-end=\"\(end)\" data-start-ms=\"\(startMs)\" data-end-ms=\"\(endMs)\">\(segment.text)</span></p>\n"
            }
        } else {
            // Fallback: plain paragraphs
            let paragraphs = session.transcribedText.components(separatedBy: "\n\n").filter { !$0.isEmpty }
            for paragraph in paragraphs {
                html += "        <p class=\"segment\">\(paragraph)</p>\n"
            }
        }

        html += """
            </div>
        </body>
        </html>
        """

        return html
    }
}

// MARK: - View Extension for Selective Corner Radius

extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int

    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)

    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let topLeft = self.corners.contains(.topLeft) ? self.radius : 0
        let topRight = self.corners.contains(.topRight) ? self.radius : 0
        let bottomLeft = self.corners.contains(.bottomLeft) ? self.radius : 0
        let bottomRight = self.corners.contains(.bottomRight) ? self.radius : 0

        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        if topRight > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
                radius: topRight,
                startAngle: Angle(degrees: -90),
                endAngle: Angle(degrees: 0),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        if bottomRight > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
                radius: bottomRight,
                startAngle: Angle(degrees: 0),
                endAngle: Angle(degrees: 90),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        if bottomLeft > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
                radius: bottomLeft,
                startAngle: Angle(degrees: 90),
                endAngle: Angle(degrees: 180),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        if topLeft > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
                radius: topLeft,
                startAngle: Angle(degrees: 180),
                endAngle: Angle(degrees: 270),
                clockwise: false
            )
        }

        return path
    }
}

// MARK: - Preview

#Preview {
    LiveTranscriptionView(asrService: ASRService())
        .frame(width: 800, height: 900)
}
