import Foundation
import Combine
import FluidAudio

/// Represents a file transcription job
struct TranscriptionJob: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    let fileURL: URL
    let createdAt: Date
    var status: JobStatus
    var modelId: String? // User-specified model ID
    var resultText: String?
    var error: String?
    var processingDuration: TimeInterval?
    
    enum JobStatus: String, Codable, Equatable {
        case pending
        case processing
        case completed
        case failed
    }

    init(fileURL: URL, modelId: String? = nil) {
        self.fileURL = fileURL
        self.createdAt = Date()
        self.status = .pending
        self.modelId = modelId
    }
    
    // Migration for old data matching
    private enum CodingKeys: String, CodingKey {
        case id, fileURL, createdAt, status, modelId, resultText, error, processingDuration
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileURL = try container.decode(URL.self, forKey: .fileURL)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.status = try container.decode(JobStatus.self, forKey: .status)
        self.modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        self.resultText = try container.decodeIfPresent(String.self, forKey: .resultText)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.processingDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .processingDuration)
        
        // Use existing ID or generate new one for legacy entries
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(modelId, forKey: .modelId)
        try container.encodeIfPresent(resultText, forKey: .resultText)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(processingDuration, forKey: .processingDuration)
    }
}

@MainActor
final class BacklogManager: ObservableObject {
    static let shared = BacklogManager()
    
    @Published private(set) var jobs: [TranscriptionJob] = []
    @Published var isProcessing: Bool = false
    
    private let defaults = UserDefaults.standard
    private let storageKey = "TranscriptionBacklog"
    
    // Dependencies
    private var transcriptionService: MeetingTranscriptionService?
    
    private init() {
        loadJobs()
    }
    
    func configure(with service: MeetingTranscriptionService) {
        self.transcriptionService = service
        self.processNextJob() // Check if we should start processing
    }
    
    // MARK: - Job Management
    
    func addJob(url: URL, modelId: String?) {
        // Check for existing job with same URL AND same model
        // If modelId is nil, we treat it as "default/unspecified".
        // We only block if there's an exact match on (URL, modelId).
        
        let exists = jobs.contains { job in
            job.fileURL == url && job.modelId == modelId
        }
        
        guard !exists else { 
            DebugLogger.shared.info("Skipping duplicate job for \(url.lastPathComponent) (model: \(modelId ?? "nil"))", source: "BacklogManager")
            return 
        }
        
        let job = TranscriptionJob(fileURL: url, modelId: modelId)
        jobs.append(job)
        saveJobs()
        
        DebugLogger.shared.info("Added transcription job: \(url.lastPathComponent) (model: \(modelId ?? "default"))", source: "BacklogManager")
        processNextJob()
    }
    
    /// Returns all jobs matching the given URL.
    func getJobs(for url: URL) -> [TranscriptionJob] {
        return jobs.filter { $0.fileURL == url }
    }
    
    /// Returns a specific job by ID.
    func getJob(id: String) -> TranscriptionJob? {
        return jobs.first(where: { $0.id == id })
    }
    
    // Helper for legacy lookup (returns first match if multiple, but ideally shouldn't be used for strict logic)
    func getJob(url: URL) -> TranscriptionJob? {
        jobs.first(where: { $0.fileURL == url })
    }
    
    func deleteJob(id: String) {
        jobs.removeAll(where: { $0.id == id })
        saveJobs()
        DebugLogger.shared.info("Deleted transcription job: \(id)", source: "BacklogManager")
    }
    
    func deleteJobs(url: URL) {
        jobs.removeAll(where: { $0.fileURL == url })
        saveJobs()
        DebugLogger.shared.info("Deleted all transcription jobs for: \(url.lastPathComponent)", source: "BacklogManager")
    }
    
    func clearCompleted() {
        jobs.removeAll(where: { $0.status == .completed || $0.status == .failed })
        saveJobs()
    }
    
    // MARK: - Processing
    
    private func processNextJob() {
        guard !isProcessing, let service = transcriptionService else { return }
        
        // Find next pending job
        guard let index = jobs.firstIndex(where: { $0.status == .pending }) else { return }
        
        // Check for max items limit (FIFO: If we exceed limit, we might want to prune completed/failed logic, but for now we just process pending)
        // User asked for "setting for a number of items to maintain in backlog". 
        // We should enforce that on add or periodically. Let's enforce on complete.
        
        isProcessing = true
        var job = jobs[index]
        job.status = .processing
        jobs[index] = job
        saveJobs() // Pending -> Processing
        
        DebugLogger.shared.info("Starting transcription for: \(job.fileURL.lastPathComponent)", source: "BacklogManager")
        
        Task(priority: .userInitiated) {
            var fileToTranscribe = job.fileURL
            var tempDownloadURL: URL? = nil
            
            // Handle HTTP/HTTPS URLs - Download to temp file
            if job.fileURL.scheme?.lowercased() == "http" || job.fileURL.scheme?.lowercased() == "https" {
                DebugLogger.shared.info("Downloading remote file: \(job.fileURL)", source: "BacklogManager")
                do {
                    let (tempURL, _) = try await URLSession.shared.download(from: job.fileURL)
                    let ext = job.fileURL.pathExtension.isEmpty ? "mp3" : job.fileURL.pathExtension
                    let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                    
                    fileToTranscribe = destURL
                    tempDownloadURL = destURL
                    DebugLogger.shared.info("Downloaded to: \(destURL.path)", source: "BacklogManager")
                } catch {
                    DebugLogger.shared.error("Download failed: \(error)", source: "BacklogManager")
                    await MainActor.run {
                        if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
                            self.jobs[index].status = .failed
                            self.jobs[index].error = "Download failed: \(error.localizedDescription)"
                            self.saveJobs()
                        }
                        self.isProcessing = false
                        self.processNextJob()
                    }
                    return
                }
            }
            
            // Cleanup temp file
            defer {
                if let tempURL = tempDownloadURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            do {
                // If job specifies a model, we might need to switch models?
                // The current MeetingTranscriptionService uses the globally selected model in ASRService.
                // Switching models globally might be disruptive if the user is using the app.
                // However, the request implies "model to transcribe".
                // We should probably temporarily switch or pass the model to the service.
                // Looking at MeetingTranscriptionService, it uses `asrService.fileTranscriptionProvider`.
                // ASRService has `downloadModel` and `getProvider` but currently `transcriptionProvider` is computed from SettingsStore.
                // To support per-job model, we'd need to extend MeetingTranscriptionService or ASRService to accept a model override.
                // For now, let's assume we use the current model if not specified, or try to switch if specified.
                
                // NOTE: Swapping global model is risky. Ideally ASRService allows transient provider usage.
                
                
                // Track timing
                let startTime = Date()
                // Use the modelId from the job if present, otherwise nil (defaulting to global)
                let result = try await service.transcribeFile(job.fileURL, modelId: job.modelId)
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)
                
                await MainActor.run {
                    if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
                        self.jobs[index].status = .completed
                        self.jobs[index].resultText = result.text
                        self.jobs[index].processingDuration = duration
                        // If modelId was nil, we could potentially update it here if the service returned which model was used
                        // different logic might be needed if service.transcribeFile returns metadata
                        self.saveJobs()
                    }
                    self.isProcessing = false
                    self.pruneBacklog()
                    self.processNextJob() // Loop
                }
            } catch {
                await MainActor.run {
                    DebugLogger.shared.error("Backlog processing failed: \(error.localizedDescription)", source: "BacklogManager")
                    if let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
                        self.jobs[index].status = .failed
                        self.jobs[index].error = error.localizedDescription
                        self.saveJobs()
                    }
                    self.isProcessing = false
                    self.processNextJob() // Loop
                }
            }
        }
    }
    
    private func pruneBacklog() {
        let maxItems = SettingsStore.shared.apiBacklogLimit
        guard jobs.count > maxItems else { return }
        
        // Remove oldest completed/failed jobs first
        // If still too many, remove oldest pending (FIFO)? Or just refuse to add?
        // User said "setting for a number of items to maintain in backlog". Usually implies retention policy.
        // We'll remove oldest completed jobs.
        
        let completed = jobs.filter { $0.status == .completed || $0.status == .failed }.sorted { $0.createdAt < $1.createdAt }
        
        if let toRemove = completed.first {
             jobs.removeAll(where: { $0.id == toRemove.id })
             saveJobs()
             // Recurse if still over limit
             if jobs.count > maxItems {
                 pruneBacklog()
             }
        }
    }

    // MARK: - Persistence
    
    private func loadJobs() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([TranscriptionJob].self, from: data) else { return }
        self.jobs = decoded
    }
    
    private func saveJobs() {
        if let encoded = try? JSONEncoder().encode(jobs) {
            defaults.set(encoded, forKey: storageKey)
        }
    }
}
