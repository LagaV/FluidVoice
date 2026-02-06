import Combine
import Foundation
import Swifter

@MainActor
final class APIService: ObservableObject {
    static let shared = APIService()

    private let server = HttpServer()
    private var port: UInt16 = 7086
    private var isStarted = false

    /// Helper to execute MainActor code synchronously from a background thread
    private func runOnMain<T>(_ block: @MainActor @escaping () -> T) -> T? {
        var result: T?
        let semaphore = DispatchSemaphore(value: 0)

        Task { @MainActor in
            result = block()
            semaphore.signal()
        }

        let timeout = semaphore.wait(timeout: .now() + 10.0)
        if timeout == .timedOut {
            DebugLogger.shared.error("runOnMain timed out", source: "APIService")
            return nil
        }
        return result
    }

    /// Helper for Void returns
    private func runOnMainVoid(_ block: @MainActor @escaping () -> Void) {
        let semaphore = DispatchSemaphore(value: 0)

        Task { @MainActor in
            block()
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 10.0)
    }

    private init() {
        self.setupRoutes()

        // Observe settings change
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.handleSettingsChange),
            name: NSNotification.Name("EnableAPIChanged"),
            object: nil
        )
    }

    @objc private func handleSettingsChange() {
        if SettingsStore.shared.enableAPI {
            self.start()
        } else {
            self.stop()
        }
    }

    func initialize(port: UInt16 = 7086) {
        self.port = port
        if SettingsStore.shared.enableAPI {
            self.start()
        }
    }

    private func start() {
        guard !self.isStarted else { return }
        do {
            try self.server.start(self.port)
            self.isStarted = true
            DebugLogger.shared.info("APIService started on port \(self.port)", source: "APIService")
        } catch {
            DebugLogger.shared.error("Failed to start APIService: \(error)", source: "APIService")
        }
    }

    private func stop() {
        guard self.isStarted else { return }
        self.server.stop()
        self.isStarted = false
        DebugLogger.shared.info("APIService stopped", source: "APIService")
    }

    private func setupRoutes() {
        // middleware to log requests
        self.server.middleware.append { _ in
            // Logging on background thread is fine if logger is thread safe
            // We'll skip jumping to main for logging
            nil
        }

        // POST /transcribe
        self.server.POST["/transcribe"] = { [weak self] request in
            guard let self else { return .internalServerError }

            // Allow JSON body
            let data = Data(request.body)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urlString = json["url"] as? String,
                  let url = URL(string: urlString)
            else {
                return .badRequest(.text("Invalid JSON or missing 'url' field"))
            }

            let modelId = json["model"] as? String

            // Fire and forget (or wait if we want to confirm it's queued)
            // We'll wait to ensure it's in the queue before returning
            self.runOnMainVoid {
                BacklogManager.shared.addJob(url: url, modelId: modelId)
            }

            return .ok(.json(["id": url.absoluteString, "status": "pending"]))
        }

        // GET /status
        self.server.GET["/status"] = { [weak self] request in
            guard let self else { return .internalServerError }

            // 1. Try ID-based lookup first
            if let id = request.queryParams.first(where: { $0.0 == "id" })?.1 {
                let result = self.runOnMain {
                    guard let job = BacklogManager.shared.getJob(id: id) else {
                        return HttpResponse.notFound
                    }
                    
                    var response: [String: Any] = [
                        "id": job.id,
                        "status": job.status.rawValue,
                        "created_at": job.createdAt.timeIntervalSince1970,
                    ]

                    if let model = job.modelId {
                        response["model"] = model
                    }

                    if let duration = job.processingDuration {
                        response["processing_duration"] = duration
                    }

                    if let error = job.error {
                        response["error"] = error
                    }
                    
                    // Also include the URL for reference
                    response["url"] = job.fileURL.absoluteString

                    return .ok(.json(response))
                }
                return result ?? .internalServerError
            }

            // 2. Fallback to URL-based lookup
            guard let urlString = request.queryParams.first(where: { $0.0 == "url" })?.1,
                  let url = URL(string: urlString)
            else {
                return .badRequest(.text("Missing 'id' or 'url' query parameter"))
            }

            let modelId = request.queryParams.first(where: { $0.0 == "model" })?.1

            let result = self.runOnMain {
                let jobs = BacklogManager.shared.getJobs(for: url)
                var matches = jobs

                if let model = modelId {
                    matches = matches.filter { $0.modelId == model }
                } else if jobs.count > 1 {
                    // Ambiguous request (multiple jobs exist but no model specified)
                    let choices = jobs.map { [
                        "id": $0.id,
                        "model": $0.modelId ?? "default",
                        "status": $0.status.rawValue,
                    ] }
                    return HttpResponse.raw(409, "Conflict", ["Content-Type": "application/json"]) { writer in
                        let json = ["error": "Ambiguous request. Multiple transcriptions found for this URL. Please specify a 'model' parameter.", "choices": choices] as [String: Any]
                        try? writer.write(JSONSerialization.data(withJSONObject: json))
                    }
                }

                guard let job = matches.first else {
                    return .notFound
                }

                var response: [String: Any] = [
                    "id": job.id,
                    "status": job.status.rawValue,
                    "created_at": job.createdAt.timeIntervalSince1970,
                ]

                if let model = job.modelId {
                    response["model"] = model
                }

                if let duration = job.processingDuration {
                    response["processing_duration"] = duration
                }

                if let error = job.error {
                    response["error"] = error
                }

                return .ok(.json(response))
            }
            return result ?? .internalServerError
        }

        // GET /result
        self.server.GET["/result"] = { [weak self] request in
            guard let self else { return .internalServerError }

            let format = request.queryParams.first(where: { $0.0 == "format" })?.1 ?? "text"

            // 1. Try based on ID
            if let id = request.queryParams.first(where: { $0.0 == "id" })?.1 {
                let result = self.runOnMain {
                    guard let job = BacklogManager.shared.getJob(id: id) else {
                        return HttpResponse.notFound
                    }

                    if job.status != .completed {
                        return .badRequest(.text("Job not completed"))
                    }

                    guard let text = job.resultText else {
                        return .internalServerError
                    }

                    if format == "vtt" {
                        let vtt = """
                        WEBVTT
                        
                        00:00:00.000 --> 00:00:10.000
                        \(text)
                        """
                        return .ok(.text(vtt))
                    } else {
                        return .ok(.text(text))
                    }
                }
                return result ?? .internalServerError
            }

            // 2. Fallback to URL
            guard let urlString = request.queryParams.first(where: { $0.0 == "url" })?.1,
                  let url = URL(string: urlString)
            else {
                return .badRequest(.text("Missing 'id' or 'url' query parameter"))
            }

            let modelId = request.queryParams.first(where: { $0.0 == "model" })?.1

            let result = self.runOnMain {
                let jobs = BacklogManager.shared.getJobs(for: url)
                var matches = jobs

                if let model = modelId {
                    matches = matches.filter { $0.modelId == model }
                } else if jobs.count > 1 {
                    let choices = jobs.map { [
                        "id": $0.id,
                        "model": $0.modelId ?? "default",
                        "status": $0.status.rawValue,
                    ] }
                    return HttpResponse.raw(409, "Conflict", ["Content-Type": "application/json"]) { writer in
                        let json = ["error": "Ambiguous request. Multiple transcriptions found for this URL. Please specify a 'model' parameter.", "choices": choices] as [String: Any]
                        try? writer.write(JSONSerialization.data(withJSONObject: json))
                    }
                }

                guard let job = matches.first else {
                    return .notFound
                }

                if job.status != .completed {
                    return .badRequest(.text("Job not completed"))
                }

                guard let text = job.resultText else {
                    return .internalServerError
                }

                if format == "vtt" {
                    let vtt = """
                    WEBVTT

                    00:00:00.000 --> 00:00:10.000
                    \(text)
                    """
                    return .ok(.text(vtt))
                } else {
                    return .ok(.text(text))
                }
            }
            return result ?? .internalServerError
        }

        // DELETE /backlog
        self.server.DELETE["/backlog"] = { [weak self] request in
            guard let self else { return .internalServerError }

            // 1. Try ID
            if let id = request.queryParams.first(where: { $0.0 == "id" })?.1 {
                let result = self.runOnMain {
                    guard BacklogManager.shared.getJob(id: id) != nil else {
                        return HttpResponse.notFound
                    }
                    BacklogManager.shared.deleteJob(id: id)
                    return .ok(.text("Deleted"))
                }
                return result ?? .internalServerError
            }

            // 2. Fallback to URL
            guard let urlString = request.queryParams.first(where: { $0.0 == "url" })?.1,
                  let url = URL(string: urlString)
            else {
                return .badRequest(.text("Missing 'id' or 'url' query parameter"))
            }

            let modelId = request.queryParams.first(where: { $0.0 == "model" })?.1

            let result = self.runOnMain {
                let jobs = BacklogManager.shared.getJobs(for: url)
                var matches = jobs

                if let model = modelId {
                    matches = matches.filter { $0.modelId == model }
                } else if jobs.count > 1 {
                    let choices = jobs.map { [
                        "id": $0.id,
                        "model": $0.modelId ?? "default",
                        "status": $0.status.rawValue,
                    ] }
                    return HttpResponse.raw(409, "Conflict", ["Content-Type": "application/json"]) { writer in
                        let json = ["error": "Ambiguous request. Multiple transcriptions found for this URL. Please specify a 'model' parameter.", "choices": choices] as [String: Any]
                        try? writer.write(JSONSerialization.data(withJSONObject: json))
                    }
                }

                guard let job = matches.first else {
                    return .notFound
                }

                BacklogManager.shared.deleteJob(id: job.id)
                return .ok(.text("Deleted"))
            }
            return result ?? .internalServerError
        }

        // GET /list
        self.server.GET["/list"] = { [weak self] _ in
            guard let self else { return .internalServerError }

            let jobs = self.runOnMain { BacklogManager.shared.jobs } ?? []
            let list = jobs.map { job -> [String: Any] in
                var dict: [String: Any] = [
                    "id": job.id,
                    "status": job.status.rawValue,
                    "url": job.fileURL.absoluteString,
                ]
                if let model = job.modelId {
                    dict["model"] = model
                }
                if let duration = job.processingDuration {
                    dict["processing_duration"] = duration
                }
                if let error = job.error {
                    dict["error"] = error
                }
                return dict
            }

            return .ok(.json(list))
        }

        // GET /models
        self.server.GET["/models"] = { [weak self] _ in
            guard let self else { return .internalServerError }

            let models = self.runOnMain {
                // Return available transcription models
                SettingsStore.SpeechModel.availableModels.map(\.id).sorted()
            } ?? []

            return .ok(.json(["models": models]))
        }
    }
}
