import Foundation
import XCTest

@testable import FluidVoice_Debug

final class DictationE2ETests: XCTestCase {
    func testDictationEndToEnd_whisperTiny_transcribesFixture() async throws {
        // Arrange
        SettingsStore.shared.shareAnonymousAnalytics = false
        SettingsStore.shared.selectedSpeechModel = .whisperTiny

        let modelDirectory = Self.modelDirectoryForRun()
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let provider = WhisperProvider(modelDirectory: modelDirectory)

        // Act
        try await provider.prepare()
        let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let result = try await provider.transcribe(samples)

        // Assert
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(raw.isEmpty, "Expected non-empty transcription text.")

        let normalized = Self.normalize(raw)
        XCTAssertTrue(normalized.contains("hello"), "Expected transcription to contain 'hello'. Got: \(raw)")
        XCTAssertTrue(normalized.contains("fluid"), "Expected transcription to contain 'fluid'. Got: \(raw)")
        XCTAssertTrue(
            normalized.contains("voice") || normalized.contains("fluidvoice") || normalized.contains("boys"),
            "Expected transcription to contain 'voice' (or a close variant like 'boys'). Got: \(raw)"
        )
    }
    
    @MainActor
    func testAPIService_startsAndResponds() async throws {
        // Arrange
        SettingsStore.shared.enableAPI = true
        
        let apiService = APIService.shared
        apiService.initialize()
        
        // Wait briefly for server start
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        
        // Act
        let url = URL(string: "http://localhost:7086/models")!
        let (data, response) = try await URLSession.shared.data(from: url)
        
        // Assert
        let httpResponse = response as? HTTPURLResponse
        XCTAssertEqual(httpResponse?.statusCode, 200, "Expected status code 200 from API")
        
        // Validate JSON content
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["models"], "Expected 'models' field in response")
    }

    @MainActor
    func testAPIService_idBasedOperations() async throws {
        // Arrange
        SettingsStore.shared.enableAPI = true
        let apiService = APIService.shared
        apiService.initialize(port: 7089)

        // Wait briefly for server start
        try await Task.sleep(nanoseconds: 500_000_000)

        // create a dummy job in BacklogManager
        let dummyURL = URL(fileURLWithPath: "/tmp/test_audio.mp3")
        
        // Manually inject a job into BacklogManager (since it's a singleton, we can modify it directly if it exposes properties, otherwise we use addJob)
        // BacklogManager.shared.addJob checks for duplicates by URL+Model.
        // We can't force an ID via addJob easily without changing BacklogManager internals or init.
        // However, we can use addJob and then find the ID.
        
        BacklogManager.shared.addJob(url: dummyURL, modelId: "whisperTiny")
        
        // Give it a moment to persist/update
        try await Task.sleep(nanoseconds: 100_000_000)
        
        guard let job = BacklogManager.shared.getJobs(for: dummyURL).first(where: { $0.modelId == "whisperTiny" }) else {
            XCTFail("Failed to add dummy job")
            return
        }
        let jobID = job.id
        
        // Act & Assert 1: Get Status by ID
        let statusURL = URL(string: "http://localhost:7089/status?id=\(jobID)")!
        let (statusData, statusResponse) = try await URLSession.shared.data(from: statusURL)
        XCTAssertEqual((statusResponse as? HTTPURLResponse)?.statusCode, 200)
        
        let statusJSON = try JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        XCTAssertEqual(statusJSON?["id"] as? String, jobID)
        let status = statusJSON?["status"] as? String
        XCTAssertTrue(status == "pending" || status == "processing", "Status was \(String(describing: status))")
        
        // Act & Assert 2: Get Result by ID (should fail as not completed)
        let resultURL = URL(string: "http://localhost:7089/result?id=\(jobID)")!
        var request = URLRequest(url: resultURL)
        request.httpMethod = "GET"
        let (_, resultResponse) = try await URLSession.shared.data(for: request)
        // Should be 400 Bad Request because job is not completed
        XCTAssertEqual((resultResponse as? HTTPURLResponse)?.statusCode, 400)
        
        // Act & Assert 3: Delete by ID
        let deleteURL = URL(string: "http://localhost:7089/backlog?id=\(jobID)")!
        var deleteRequest = URLRequest(url: deleteURL)
        deleteRequest.httpMethod = "DELETE"
        let (_, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
        XCTAssertEqual((deleteResponse as? HTTPURLResponse)?.statusCode, 200)
        
        // Verify Deletion
        let (_, verifyResponse) = try await URLSession.shared.data(from: statusURL)
        // Should be 404 Not Found
        XCTAssertEqual((verifyResponse as? HTTPURLResponse)?.statusCode, 404)
    }

    private static func modelDirectoryForRun() -> URL {
        // Use a stable path on CI so GitHub Actions cache can speed up runs.
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" ||
            ProcessInfo.processInfo.environment["CI"] == "true"
        {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                preconditionFailure("Could not find caches directory")
            }
            return caches.appendingPathComponent("WhisperModels")
        }

        // Local runs: isolate per test execution.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return base.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let noPunct = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.punctuationCharacters.contains(scalar) { return " " }
            return Character(scalar)
        }
        let collapsed = String(noPunct)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsed
    }
}
