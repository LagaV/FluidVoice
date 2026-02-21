//
//  LiveTranscriptionService.swift
//  Fluid
//
//  Service for managing live transcription sessions with real-time ASR integration
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class LiveTranscriptionService: ObservableObject {
    // MARK: - Published State

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var completedText: String = "" // Finalized segments (editable)
    @Published private(set) var liveSegment: String = "" // Current partial transcription (read-only)
    @Published private(set) var sessionStartTime: Date?
    @Published private(set) var elapsedDuration: TimeInterval = 0
    @Published private(set) var currentWordCount: Int = 0
    @Published private(set) var transcriptionSegments: [TranscriptionSegment] = []

    // MARK: - Dependencies

    private let asrService: ASRService
    private let store = LiveTranscriptionStore.shared
    private let settings = SettingsStore.shared

    // MARK: - Private State

    private var updateTimer: Timer?
    private var autoSaveTimer: Timer?
    private var transcriptionBuffer: String = "" // Finalized text from completed segments
    private var cancellables = Set<AnyCancellable>()

    // Minimal tracking for timing only
    private var lastPartialText: String = ""
    private var lastPartialUpdateTime: Date?
    private var currentSegmentStartTime: Date?
    private var finalizationTimer: Timer?

    // Duration tracking for active recording time only
    private var accumulatedDuration: TimeInterval = 0 // Time already recorded
    private var activeRecordingStartTime: Date? // When current active period started

    /// Structured segments with timestamps
    struct TranscriptionSegment: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let startTime: Date
        let endTime: Date

        static func == (lhs: TranscriptionSegment, rhs: TranscriptionSegment) -> Bool {
            lhs.id == rhs.id
        }

        var timestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: self.startTime)
        }

        var duration: TimeInterval {
            self.endTime.timeIntervalSince(self.startTime)
        }
    }

    private var segments: [TranscriptionSegment] = []

    // MARK: - Initialization

    init(asrService: ASRService) {
        self.asrService = asrService

        // Subscribe to partialTranscription changes for real-time updates
        self.asrService.$partialTranscription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, self.isRecording, !self.isPaused else { return }

                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                // CLEAN LOGIC: Extract all complete sentences, add new ones
                let (completeSentences, liveText) = self.extractCompleteSentences(from: trimmed)

                // Add each complete sentence (duplicate check inside)
                for sentence in completeSentences {
                    self.addSegment(sentence)
                }

                // Update live segment
                self.liveSegment = liveText

                // Track timing for auto-finalization
                if trimmed != self.lastPartialText {
                    self.lastPartialUpdateTime = Date()
                    self.lastPartialText = trimmed

                    if self.currentSegmentStartTime == nil {
                        self.currentSegmentStartTime = Date()
                    }
                }

                // Update word count
                let totalText = self.transcriptionBuffer.isEmpty ? trimmed : "\(self.transcriptionBuffer) \(trimmed)"
                self.currentWordCount = self.countWords(in: totalText)
            }
            .store(in: &self.cancellables)
    }

    // MARK: - Public Methods

    /// Start a new live transcription session
    func startNewSession() async throws {
        guard !self.isRecording else {
            DebugLogger.shared.warning("Attempted to start session while already recording", source: "LiveTranscriptionService")
            return
        }

        // Get current audio device info
        let deviceInfo = AudioDevice.getDefaultInputDevice()?.name ?? "Unknown Microphone"

        // Create new session
        let sessionID = self.store.createSession(deviceInfo: deviceInfo)

        DebugLogger.shared.info("Starting live transcription session: \(sessionID)", source: "LiveTranscriptionService")

        // Only clear state if truly starting fresh (no existing text)
        // This allows continuation after stop
        if self.transcriptionBuffer.isEmpty {
            self.completedText = ""
            self.liveSegment = ""
            self.segments = []
            self.transcriptionSegments = []
            self.currentWordCount = 0
        }

        // Always reset tracking state for NEW ASR session
        self.lastPartialText = ""
        self.lastPartialUpdateTime = nil
        self.currentSegmentStartTime = nil
        self.elapsedDuration = 0
        self.accumulatedDuration = 0
        self.activeRecordingStartTime = Date()
        self.sessionStartTime = Date()

        // Start ASR and set Live Transcription state
        self.asrService.isLiveTranscriptionActive = true
        self.asrService.isLiveTranscriptionRecording = true
        self.asrService.suppressNotchOverlay = true // Suppress notch during active recording
        try await self.asrService.ensureAsrReady()
        await self.asrService.start()

        self.isRecording = true
        self.isPaused = false

        // Start update timers
        self.startUpdateTimer()
        self.startAutoSaveTimer()
        self.startFinalizationCheckTimer()

        // Track analytics
        AnalyticsService.shared.capture(.liveTranscriptionStarted)
    }

    /// Pause the current session (stops ASR to free resources)
    func pauseSession() async {
        guard self.isRecording, !self.isPaused else { return }

        DebugLogger.shared.debug("Pausing live transcription session", source: "LiveTranscriptionService")

        // Stop ASR and finalize any remaining text
        let finalText = await self.asrService.stop()
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            // Extract and add any complete sentences
            let (completeSentences, _) = self.extractCompleteSentences(from: trimmed)
            for sentence in completeSentences {
                self.addSegment(sentence)
            }
        }

        self.liveSegment = "" // Clear live segment

        // Accumulate duration before pausing
        if let startTime = self.activeRecordingStartTime {
            self.accumulatedDuration += Date().timeIntervalSince(startTime)
            self.activeRecordingStartTime = nil
        }
        self.elapsedDuration = self.accumulatedDuration

        // Update Live Transcription state (active but not recording)
        self.asrService.isLiveTranscriptionRecording = false
        self.asrService.suppressNotchOverlay = false // Allow notch overlay when paused

        self.isPaused = true
        self.store.pauseSession()

        AnalyticsService.shared.capture(.liveTranscriptionPaused)
    }

    /// Resume the paused session (restarts ASR)
    func resumeSession() async throws {
        guard self.isRecording, self.isPaused else { return }

        DebugLogger.shared.debug("Resuming live transcription session", source: "LiveTranscriptionService")

        // Reset ASR tracking for new ASR session
        self.lastPartialText = ""
        self.lastPartialUpdateTime = nil
        self.currentSegmentStartTime = nil

        // Resume ASR and update state
        self.asrService.isLiveTranscriptionRecording = true
        self.asrService.suppressNotchOverlay = true // Suppress notch during active recording
        await self.asrService.start()

        // Resume duration tracking
        self.activeRecordingStartTime = Date()

        self.isPaused = false
        self.store.resumeSession()

        AnalyticsService.shared.capture(.liveTranscriptionResumed)
    }

    /// Stop and finalize the current session
    func stopAndFinalizeSession() async -> LiveTranscriptionSession? {
        guard self.isRecording else { return nil }

        DebugLogger.shared.info("Stopping and finalizing live transcription session", source: "LiveTranscriptionService")

        // Stop ASR and finalize any remaining text
        let finalText = await self.asrService.stop()
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            // Extract and add any complete sentences
            let (completeSentences, _) = self.extractCompleteSentences(from: trimmed)
            for sentence in completeSentences {
                self.addSegment(sentence)
            }
        }

        // Update completed text and clear live segment
        self.completedText = self.transcriptionBuffer
        self.liveSegment = ""

        // Update session with final text
        self.store.updateSessionText(self.transcriptionBuffer)

        // Stop timers
        self.stopUpdateTimer()
        self.stopAutoSaveTimer()
        self.stopFinalizationCheckTimer()

        // Finalize session
        let finalizedSession = self.store.finalizeCurrentSession()

        // Reset state
        self.isRecording = false
        self.isPaused = false
        self.completedText = ""
        self.liveSegment = ""
        self.transcriptionBuffer = ""
        self.sessionStartTime = nil
        self.elapsedDuration = 0
        self.currentWordCount = 0

        // Reset Live Transcription state
        self.asrService.isLiveTranscriptionActive = false
        self.asrService.isLiveTranscriptionRecording = false
        self.asrService.suppressNotchOverlay = false

        // Track analytics
        if let session = finalizedSession {
            AnalyticsService.shared.capture(
                .liveTranscriptionCompleted,
                properties: [
                    "duration": Int(session.duration),
                    "word_count": session.wordCount,
                    "was_paused": !session.pauseIntervals.isEmpty,
                ]
            )
        }

        return finalizedSession
    }

    /// Cancel the current session without saving
    func cancelSession() async {
        guard self.isRecording else { return }

        DebugLogger.shared.info("Cancelling live transcription session", source: "LiveTranscriptionService")

        // Stop ASR
        await self.asrService.stopWithoutTranscription()

        // Stop timers
        self.stopUpdateTimer()
        self.stopAutoSaveTimer()

        // Cancel session
        self.store.cancelCurrentSession()

        // Reset state
        self.isRecording = false
        self.isPaused = false
        self.completedText = ""
        self.liveSegment = ""
        self.transcriptionBuffer = ""
        self.sessionStartTime = nil
        self.elapsedDuration = 0
        self.currentWordCount = 0

        // Reset Live Transcription state
        self.asrService.isLiveTranscriptionActive = false
        self.asrService.isLiveTranscriptionRecording = false
        self.asrService.suppressNotchOverlay = false
    }

    /// Update the completed text manually (for editing)
    func updateCompletedText(_ text: String) {
        self.transcriptionBuffer = text
        self.completedText = text
        self.currentWordCount = self.countWords(in: text)
        self.store.updateSessionText(text)
        // Note: segments array unchanged - it tracks what ASR finalized
        // User edits don't affect ASR tracking
    }

    /// Add custom metadata to current session
    func addMetadata(key: String, value: String) {
        self.store.updateMetadata(key: key, value: value)
    }

    /// Remove custom metadata from current session
    func removeMetadata(key: String) {
        self.store.removeMetadata(key: key)
    }

    // MARK: - Private Methods

    private func startUpdateTimer() {
        self.updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateElapsedTime()
            }
        }
    }

    private func stopUpdateTimer() {
        self.updateTimer?.invalidate()
        self.updateTimer = nil
    }

    private func startAutoSaveTimer() {
        // Auto-save every 10 seconds while recording
        self.autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Store already auto-saves on updateSessionText, this is just a safety net
                DebugLogger.shared.debug("Auto-save checkpoint", source: "LiveTranscriptionService")
            }
        }
    }

    private func stopAutoSaveTimer() {
        self.autoSaveTimer?.invalidate()
        self.autoSaveTimer = nil
    }

    private func startFinalizationCheckTimer() {
        // Check every 1 second if we should finalize current segment
        self.finalizationTimer?.invalidate()
        self.finalizationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkForStaleSegment()
            }
        }
    }

    private func stopFinalizationCheckTimer() {
        self.finalizationTimer?.invalidate()
        self.finalizationTimer = nil
    }

    private func scheduleFinalizationCheck() {
        // Already handled by the timer
    }

    /// Check if current segment should be finalized (no text changes for 1.5s)
    private func checkForStaleSegment() {
        guard self.isRecording, !self.isPaused else { return }
        guard !self.lastPartialText.isEmpty else { return }
        guard let lastUpdate = self.lastPartialUpdateTime else { return }

        let timeSinceUpdate = Date().timeIntervalSince(lastUpdate)

        // If no text changes for 1.5s and ends with punctuation, finalize
        if timeSinceUpdate >= 1.5 {
            let endsWithPunctuation = self.lastPartialText.hasSuffix(".") ||
                self.lastPartialText.hasSuffix("!") ||
                self.lastPartialText.hasSuffix("?")

            if endsWithPunctuation {
                DebugLogger.shared.debug("Auto-finalizing after 1.5s silence", source: "LiveTranscriptionService")
                // Extract and add complete sentences from stale text
                let (completeSentences, _) = self.extractCompleteSentences(from: self.lastPartialText)
                for sentence in completeSentences {
                    self.addSegment(sentence)
                }
            }
        }
    }

    private func updateElapsedTime() {
        // Only update duration during active recording (not paused)
        guard !self.isPaused, let startTime = self.activeRecordingStartTime else {
            return
        }
        self.elapsedDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
    }

    private func updateCompletedText() {
        self.completedText = self.transcriptionBuffer
        self.currentWordCount = self.countWords(in: self.transcriptionBuffer)
    }

    private func countWords(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let words = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return words.count
    }

    // MARK: - Clean Finalization Helpers

    /// Extract complete sentences from ASR text
    /// Returns: (array of complete sentences, remaining live text)
    private func extractCompleteSentences(from text: String) -> ([String], String) {
        guard let pattern = try? Regex("([.!?])\\s+([A-Z])") else {
            return ([], text)
        }

        var sentences: [String] = []
        var lastEndIndex = text.startIndex

        // Find all sentence boundaries
        for match in text.matches(of: pattern) {
            // Boundary is just before the capital letter
            let boundaryIndex = text.index(before: match.range.upperBound)
            let beforeBoundary = text.index(before: boundaryIndex)

            // Extract sentence from last end to this boundary
            let sentence = String(text[lastEndIndex...beforeBoundary]).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }

            lastEndIndex = boundaryIndex
        }

        // Everything after last boundary is live text
        let liveText = String(text[lastEndIndex...]).trimmingCharacters(in: .whitespaces)

        return (sentences, liveText)
    }

    /// Add a sentence segment (with duplicate check)
    private func addSegment(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Exact duplicate check
        if self.segments.contains(where: { $0.text == trimmed }) {
            return // Already finalized, skip
        }

        // Fuzzy duplicate check: check similarity with last 10 segments
        let recentSegments = self.segments.suffix(10)
        for segment in recentSegments {
            // If very recent (within 10 seconds), be more aggressive about duplicates
            let timeDiff = Date().timeIntervalSince(segment.endTime)
            let isRecent = timeDiff < 10.0

            if self.isSimilarText(trimmed, to: segment.text, strictIfRecent: isRecent) {
                DebugLogger.shared.debug("Skipping similar segment (ASR refinement, time diff: \(String(format: "%.1f", timeDiff))s)", source: "LiveTranscriptionService")
                return // Too similar to recent segment, likely ASR refinement
            }
        }

        // Create and add segment
        let segment = TranscriptionSegment(
            text: trimmed,
            startTime: self.currentSegmentStartTime ?? Date(),
            endTime: Date()
        )
        self.segments.append(segment)
        self.transcriptionSegments = self.segments

        // APPEND to buffer (don't rebuild from segments to preserve user edits)
        if !self.transcriptionBuffer.isEmpty {
            self.transcriptionBuffer += "\n\n"
        }
        self.transcriptionBuffer += trimmed
        self.completedText = self.transcriptionBuffer
        self.store.updateSessionText(self.transcriptionBuffer)

        // Update segments in store for export
        let timedSegments = self.segments.map { seg in
            LiveTranscriptionSession.TimedSegment(
                text: seg.text,
                startTime: seg.startTime,
                endTime: seg.endTime
            )
        }
        self.store.updateSessionSegments(timedSegments)

        // Reset timing for next segment
        self.currentSegmentStartTime = nil

        DebugLogger.shared.debug("Added segment: \(trimmed.prefix(50))...", source: "LiveTranscriptionService")
    }

    /// Check if two texts are similar (likely ASR refinements of same content)
    private func isSimilarText(_ text1: String, to text2: String, strictIfRecent: Bool = false) -> Bool {
        // Normalize texts
        let normalized1 = text1.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let normalized2 = text2.lowercased().trimmingCharacters(in: .punctuationCharacters)

        // Check if one is a substring of the other (ASR refinement often adds/removes words)
        if normalized1.contains(normalized2) || normalized2.contains(normalized1) {
            return true
        }

        // Calculate word overlap similarity
        let words1 = Set(normalized1.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let words2 = Set(normalized2.components(separatedBy: .whitespaces).filter { !$0.isEmpty })

        guard !words1.isEmpty, !words2.isEmpty else { return false }

        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        let similarity = Double(intersection.count) / Double(union.count)

        // For recent segments (within 10s), use stricter threshold to catch ASR refinements
        let threshold: Double = strictIfRecent ? 0.70 : 0.85
        return similarity > threshold
    }
}
