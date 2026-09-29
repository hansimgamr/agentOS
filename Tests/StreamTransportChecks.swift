import Foundation

private final class CapturedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(String, [String: Any])] = []

    func append(_ event: String, _ payload: [String: Any]) {
        lock.lock()
        stored.append((event, payload))
        lock.unlock()
    }

    var values: [(String, [String: Any])] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@main
struct StreamTransportChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("scenario endpoint fingerprint") }
        let scenario = CommandLine.arguments[1]
        let endpoint = CommandLine.arguments[2]
        let fingerprint = CommandLine.arguments[3]
        let api = try HermesAPI(endpoint: endpoint, apiKey: "fixture-only-token", fingerprint: scenario == "wrong-pin" ? String(repeating: "0", count: 64) : fingerprint)
        let imageBytes = Data([0x00, 0x01, 0xfe, 0xff])
        let image = PendingImage(data: imageBytes, mimeType: "image/png")
        let events = CapturedEvents()
        let started = Date()
        let send = {
            try await api.send(sessionID: scenario, text: "hello", image: image) { name, payload in
                events.append(name, payload)
            }
        }

        if scenario == "cancel" {
            let task = Task { try await send() }
            for _ in 0..<40 where !events.values.contains(where: { $0.0 == "run.started" }) {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            precondition(events.values.contains(where: { $0.0 == "run.started" }), "Cancellation fixture failed before the response stream started")
            task.cancel()
            do {
                try await task.value
                fatalError("Cancelled stream unexpectedly succeeded")
            } catch is CancellationError { }
            catch { }
            precondition(Date().timeIntervalSince(started) < 2, "Cancellation did not end the stream promptly")
            print("PASS cancel: stream ended promptly")
            return
        }

        do {
            try await send()
            guard scenario == "valid" else { fatalError("\(scenario) unexpectedly succeeded") }
        } catch let error as HermesError {
            switch (scenario, error) {
            case ("wrong-pin", _): fatalError("Wrong pin reached an HTTP-level Hermes error")
            case ("http-401", .badResponse(401, _)): break
            case ("redirect", .badResponse(302, _)): break
            case ("wrong-content-type", .malformedResponse): break
            case ("sse-error", .streamFailed(_)): break
            case ("truncated", .streamInterrupted): break
            default: fatalError("Unexpected HermesError for \(scenario): \(error)")
            }
            print("PASS \(scenario): rejected as expected")
            return
        } catch {
            guard scenario == "wrong-pin" else { throw error }
            print("PASS wrong-pin: TLS rejected before HTTP")
            return
        }

        guard scenario == "valid" else { return }
        let captured = events.values
        precondition(captured.map(\.0) == ["run.started", "assistant.delta", "assistant.delta", "assistant.completed", "run.completed", "done"], "SSE event framing/order was lost: \(captured.map(\.0))")
        precondition(captured[1].1["text"] as? String == "café", "UTF-8 split across HTTP chunks was corrupted")
        precondition(captured[2].1["text"] as? String == "multiline", "Multiline SSE data was not joined as JSON whitespace")
        print("PASS valid: CRLF/LF, chunked UTF-8, multiline SSE, terminal events, image bytes")
    }
}
