//
//  LiveTranscriptionSession.swift
//  Fluid
//
//  Live transcription session model with metadata and persistence support
//

import Foundation

// MARK: - Live Transcription Session Model

struct LiveTranscriptionSession: Codable, Identifiable, Equatable {
    let id: UUID
    var startTime: Date
    var endTime: Date?
    var transcribedText: String
    var appName: String
    var deviceInfo: String
    var customMetadata: [String: String]
    var isPaused: Bool
    var pauseIntervals: [PauseInterval]
    var segments: [TimedSegment]  // NEW: Store segments with timing
    
    struct PauseInterval: Codable, Equatable {
        let start: Date
        var end: Date?
    }
    
    struct TimedSegment: Codable, Equatable {
        let text: String
        let startTime: Date
        let endTime: Date
    }
    
    init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        endTime: Date? = nil,
        transcribedText: String = "",
        appName: String = "FluidVoice",
        deviceInfo: String = "",
        customMetadata: [String: String] = [:],
        isPaused: Bool = false,
        pauseIntervals: [PauseInterval] = [],
        segments: [TimedSegment] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.transcribedText = transcribedText
        self.appName = appName
        self.deviceInfo = deviceInfo
        self.customMetadata = customMetadata
        self.isPaused = isPaused
        self.pauseIntervals = pauseIntervals
        self.segments = segments
    }
    
    // MARK: - Computed Properties
    
    /// Total duration in seconds
    var duration: TimeInterval {
        let end = self.endTime ?? Date()
        var totalDuration = end.timeIntervalSince(self.startTime)
        
        // Subtract pause durations
        for interval in self.pauseIntervals {
            let pauseEnd = interval.end ?? Date()
            totalDuration -= pauseEnd.timeIntervalSince(interval.start)
        }
        
        return max(0, totalDuration)
    }
    
    /// Word count
    var wordCount: Int {
        let trimmed = self.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return words.count
    }
    
    /// Formatted duration string (e.g., "1h 23m 45s" or "2m 30s")
    var formattedDuration: String {
        let seconds = Int(self.duration)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
    
    /// Formatted start time
    var formattedStartTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self.startTime)
    }
    
    /// Formatted end time (if available)
    var formattedEndTime: String? {
        guard let endTime else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: endTime)
    }
    
    /// Preview text for list display (first 100 chars)
    var previewText: String {
        let text = self.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 100 {
            return String(text.prefix(97)) + "..."
        }
        return text.isEmpty ? "(No content)" : text
    }
    
    /// Relative time string for display
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.startTime, relativeTo: Date())
    }
    
    /// Check if session is currently active
    var isActive: Bool {
        self.endTime == nil
    }
    
    // MARK: - Markdown Export
    
    /// Generate markdown content with YAML frontmatter
    func toMarkdown() -> String {
        // Use custom title if available, otherwise use formatted start time
        let title = self.customMetadata["title"] ?? self.formattedStartTime
        
        var frontmatter = """
        ---
        id: \(self.id.uuidString)
        title: "\(title)"
        start_time: "\(ISO8601DateFormatter().string(from: self.startTime))"
        """
        
        if let endTime {
            frontmatter += "\nend_time: \"\(ISO8601DateFormatter().string(from: endTime))\""
        }
        
        frontmatter += """
        
        duration: \(Int(self.duration))
        word_count: \(self.wordCount)
        app_name: "\(self.appName)"
        device_info: "\(self.deviceInfo)"
        """
        
        // Add custom metadata
        for (key, value) in self.customMetadata.sorted(by: { $0.key < $1.key }) {
            frontmatter += "\n\(key): \"\(value)\""
        }
        
        frontmatter += "\n---\n\n"
        
        return frontmatter + self.transcribedText
    }
    
    /// Parse markdown file with frontmatter
    static func fromMarkdown(_ content: String) -> LiveTranscriptionSession? {
        // Split frontmatter and content
        let components = content.components(separatedBy: "---")
        guard components.count >= 3 else { return nil }
        
        let frontmatterString = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let textContent = components[2...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Parse frontmatter
        var metadata: [String: String] = [:]
        for line in frontmatterString.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            
            metadata[key] = value
        }
        
        // Extract required fields
        guard let idString = metadata["id"],
              let id = UUID(uuidString: idString),
              let startTimeString = metadata["start_time"],
              let startTime = ISO8601DateFormatter().date(from: startTimeString)
        else {
            return nil
        }
        
        let endTime = metadata["end_time"].flatMap { ISO8601DateFormatter().date(from: $0) }
        let appName = metadata["app_name"] ?? "FluidVoice"
        let deviceInfo = metadata["device_info"] ?? ""
        
        // Extract custom metadata (exclude known fields)
        let knownKeys = Set(["id", "title", "start_time", "end_time", "duration", "word_count", "app_name", "device_info"])
        var customMetadata: [String: String] = [:]
        for (key, value) in metadata where !knownKeys.contains(key) {
            customMetadata[key] = value
        }
        
        return LiveTranscriptionSession(
            id: id,
            startTime: startTime,
            endTime: endTime,
            transcribedText: textContent,
            appName: appName,
            deviceInfo: deviceInfo,
            customMetadata: customMetadata,
            isPaused: false,
            pauseIntervals: []
        )
    }
}
