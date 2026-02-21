//
//  LiveTranscriptionStore.swift
//  Fluid
//
//  Persistence manager for Live Transcription sessions
//

import Combine
import Foundation

// MARK: - Live Transcription Store

@MainActor
final class LiveTranscriptionStore: ObservableObject {
    static let shared = LiveTranscriptionStore()
    
    private let defaults = UserDefaults.standard
    
    private enum Keys {
        static let recentSessions = "LiveTranscriptionRecentSessions"
        static let currentSessionBackup = "LiveTranscriptionCurrentSessionBackup"
    }
    
    @Published private(set) var sessions: [LiveTranscriptionSession] = []
    @Published var selectedSessionID: UUID?
    @Published private(set) var currentSession: LiveTranscriptionSession?
    
    private init() {
        self.loadRecentSessions()
    }
    
    // MARK: - Public Methods
    
    /// Get selected session
    var selectedSession: LiveTranscriptionSession? {
        guard let id = selectedSessionID else { return nil }
        return self.sessions.first(where: { $0.id == id })
    }
    
    /// Create a new session
    func createSession(deviceInfo: String = "") -> UUID {
        let session = LiveTranscriptionSession(
            deviceInfo: deviceInfo
        )
        
        self.currentSession = session
        DebugLogger.shared.info("Created new live transcription session: \(session.id)", source: "LiveTranscriptionStore")
        
        return session.id
    }
    
    /// Update session text
    func updateSessionText(_ text: String) {
        guard var session = self.currentSession else { return }
        session.transcribedText = text
        self.currentSession = session
        
        // Auto-save current session backup
        self.saveCurrentSessionBackup()
    }
    
    /// Update session segments with timing
    func updateSessionSegments(_ segments: [LiveTranscriptionSession.TimedSegment]) {
        guard var session = self.currentSession else { return }
        session.segments = segments
        self.currentSession = session
        
        // Auto-save current session backup
        self.saveCurrentSessionBackup()
    }
    
    /// Pause current session
    func pauseSession() {
        guard var session = self.currentSession else { return }
        
        session.isPaused = true
        let pauseInterval = LiveTranscriptionSession.PauseInterval(start: Date(), end: nil)
        session.pauseIntervals.append(pauseInterval)
        
        self.currentSession = session
        self.saveCurrentSessionBackup()
        DebugLogger.shared.debug("Paused session: \(session.id)", source: "LiveTranscriptionStore")
    }
    
    /// Resume current session
    func resumeSession() {
        guard var session = self.currentSession else { return }
        
        session.isPaused = false
        
        // Close the last pause interval
        if let lastInterval = session.pauseIntervals.last, lastInterval.end == nil {
            session.pauseIntervals[session.pauseIntervals.count - 1].end = Date()
        }
        
        self.currentSession = session
        self.saveCurrentSessionBackup()
        DebugLogger.shared.debug("Resumed session: \(session.id)", source: "LiveTranscriptionStore")
    }
    
    /// Update custom metadata
    func updateMetadata(key: String, value: String) {
        guard var session = self.currentSession else { return }
        session.customMetadata[key] = value
        self.currentSession = session
        self.saveCurrentSessionBackup()
    }
    
    /// Remove custom metadata key
    func removeMetadata(key: String) {
        guard var session = self.currentSession else { return }
        session.customMetadata.removeValue(forKey: key)
        self.currentSession = session
        self.saveCurrentSessionBackup()
    }
    
    /// Finalize current session (mark as complete and save)
    func finalizeCurrentSession() -> LiveTranscriptionSession? {
        guard var session = self.currentSession else { return nil }
        
        // Set end time
        session.endTime = Date()
        
        // Close any open pause interval
        if let lastInterval = session.pauseIntervals.last, lastInterval.end == nil {
            session.pauseIntervals[session.pauseIntervals.count - 1].end = Date()
        }
        
        // Add to sessions list
        self.sessions.insert(session, at: 0)
        
        // Save to recent sessions
        self.saveRecentSessions()
        
        // Auto-save to file if enabled
        if SettingsStore.shared.liveTranscriptionAutoSave {
            do {
                try self.saveSessionToFile(session)
            } catch {
                DebugLogger.shared.error("Failed to auto-save session: \(error)", source: "LiveTranscriptionStore")
            }
        }
        
        let finalizedSession = session
        self.currentSession = nil
        
        // Clear the backup since session is finalized
        self.clearCurrentSessionBackup()
        
        DebugLogger.shared.info("Finalized session: \(finalizedSession.id), duration: \(finalizedSession.formattedDuration), words: \(finalizedSession.wordCount)", source: "LiveTranscriptionStore")
        
        return finalizedSession
    }
    
    /// Cancel current session without saving
    func cancelCurrentSession() {
        guard let session = self.currentSession else { return }
        
        DebugLogger.shared.info("Cancelled session: \(session.id)", source: "LiveTranscriptionStore")
        self.currentSession = nil
        self.clearCurrentSessionBackup()
    }
    
    /// Save a session to markdown file
    func saveSessionToFile(_ session: LiveTranscriptionSession) throws {
        let storagePath = SettingsStore.shared.liveTranscriptionStoragePath
        let storageURL = URL(fileURLWithPath: storagePath)
        
        // Ensure directory exists
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        
        // Generate filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = dateFormatter.string(from: session.startTime)
        let filename = "transcription_\(dateString).md"
        
        let fileURL = storageURL.appendingPathComponent(filename)
        
        // Write markdown content
        let markdownContent = session.toMarkdown()
        try markdownContent.write(to: fileURL, atomically: true, encoding: .utf8)
        
        DebugLogger.shared.info("Saved session to file: \(fileURL.path)", source: "LiveTranscriptionStore")
    }
    
    /// Load a session from markdown file
    func loadSessionFromFile(_ url: URL) throws -> LiveTranscriptionSession {
        let content = try String(contentsOf: url, encoding: .utf8)
        
        guard let session = LiveTranscriptionSession.fromMarkdown(content) else {
            throw NSError(
                domain: "LiveTranscriptionStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse session from file"]
            )
        }
        
        DebugLogger.shared.info("Loaded session from file: \(url.path)", source: "LiveTranscriptionStore")
        return session
    }
    
    /// Export current session to user-selected location
    func exportCurrentSession() throws -> URL? {
        guard let session = self.currentSession else { return nil }
        
        // Generate filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = dateFormatter.string(from: session.startTime)
        let filename = "transcription_\(dateString).md"
        
        // Create temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let markdownContent = session.toMarkdown()
        try markdownContent.write(to: tempURL, atomically: true, encoding: .utf8)
        
        return tempURL
    }
    
    /// Delete a session from the list
    func deleteSession(id: UUID) {
        self.sessions.removeAll { $0.id == id }
        
        // Clear selection if deleted
        if self.selectedSessionID == id {
            self.selectedSessionID = self.sessions.first?.id
        }
        
        self.saveRecentSessions()
        DebugLogger.shared.debug("Deleted session: \(id)", source: "LiveTranscriptionStore")
    }
    
    /// Delete multiple sessions
    func deleteSessions(ids: Set<UUID>) {
        self.sessions.removeAll { ids.contains($0.id) }
        
        if let selected = selectedSessionID, ids.contains(selected) {
            self.selectedSessionID = self.sessions.first?.id
        }
        
        self.saveRecentSessions()
    }
    
    /// Clear all sessions
    func clearAllSessions() {
        self.sessions.removeAll()
        self.selectedSessionID = nil
        self.saveRecentSessions()
        
        DebugLogger.shared.info("Cleared all live transcription sessions", source: "LiveTranscriptionStore")
    }
    
    /// Search sessions by text content
    func searchSessions(query: String) -> [LiveTranscriptionSession] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self.sessions
        }
        
        let lowercased = query.lowercased()
        return self.sessions.filter { session in
            session.transcribedText.lowercased().contains(lowercased) ||
                session.appName.lowercased().contains(lowercased) ||
                session.deviceInfo.lowercased().contains(lowercased) ||
                session.customMetadata.values.contains { $0.lowercased().contains(lowercased) }
        }
    }
    
    /// Get total word count across all sessions
    var totalWordCount: Int {
        self.sessions.reduce(0) { $0 + $1.wordCount }
    }
    
    /// Get total duration across all sessions
    var totalDuration: TimeInterval {
        self.sessions.reduce(0) { $0 + $1.duration }
    }
    
    // MARK: - Session Backup (Auto-save)
    
    /// Restore backed-up current session (on app restart or view appear)
    func restoreCurrentSessionBackup() {
        guard let data = defaults.data(forKey: Keys.currentSessionBackup),
              let session = try? JSONDecoder().decode(LiveTranscriptionSession.self, from: data)
        else {
            return
        }
        
        self.currentSession = session
        DebugLogger.shared.info("Restored backed-up session: \(session.id)", source: "LiveTranscriptionStore")
    }
    
    /// Save current session as backup (auto-save)
    private func saveCurrentSessionBackup() {
        guard let session = self.currentSession,
              let encoded = try? JSONEncoder().encode(session)
        else {
            return
        }
        
        self.defaults.set(encoded, forKey: Keys.currentSessionBackup)
    }
    
    /// Clear the backed-up session
    private func clearCurrentSessionBackup() {
        self.defaults.removeObject(forKey: Keys.currentSessionBackup)
    }
    
    // MARK: - Private Methods
    
    private func loadRecentSessions() {
        guard let data = defaults.data(forKey: Keys.recentSessions),
              let decoded = try? JSONDecoder().decode([LiveTranscriptionSession].self, from: data)
        else {
            self.sessions = []
            return
        }
        
        // Only keep last 50 sessions in memory
        self.sessions = Array(decoded.prefix(50))
    }
    
    private func saveRecentSessions() {
        // Only save last 50 sessions to UserDefaults
        let sessionsToSave = Array(self.sessions.prefix(50))
        
        if let encoded = try? JSONEncoder().encode(sessionsToSave) {
            self.defaults.set(encoded, forKey: Keys.recentSessions)
        }
        objectWillChange.send()
    }
}
