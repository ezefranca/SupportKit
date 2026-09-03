import Foundation
@testable import SupportKit
import Testing

@Suite("Bounded URL session HTTP client", .serialized)
struct URLSessionSupportHTTPClientTests {
    @Test
    func `an unknown-length oversized response is cancelled before the complete body arrives`() async throws {
        // Arrange
        let chunks = Array(repeating: Data(repeating: 0x41, count: 512), count: 64)
        StreamingURLProtocol.controller.configure(chunks: chunks, delay: .milliseconds(5))
        let sut = URLSessionSupportHTTPClient(configuration: urlSessionConfiguration())
        let request = try URLRequest(url: testURL())

        // Act / Assert
        do {
            _ = try await sut.data(for: request, maximumResponseBytes: 1024)
            Issue.record("Expected an oversized response to fail")
        } catch let error as SupportTransportError {
            #expect(error == .invalidResponse)
        } catch {
            Issue.record("Expected SupportTransportError, received \(type(of: error))")
        }

        await waitUntil { StreamingURLProtocol.controller.snapshot().wasStopped }
        let snapshot = StreamingURLProtocol.controller.snapshot()
        #expect(snapshot.wasStopped)
        #expect(snapshot.emittedBytes < chunks.reduce(0) { $0 + $1.count })
        #expect(!snapshot.didFinish)
    }

    @Test
    func `caller cancellation cancels the underlying response stream`() async throws {
        // Arrange
        let chunks = Array(repeating: Data(repeating: 0x41, count: 256), count: 1000)
        StreamingURLProtocol.controller.configure(chunks: chunks, delay: .milliseconds(10))
        let sut = URLSessionSupportHTTPClient(configuration: urlSessionConfiguration())
        let request = try URLRequest(url: testURL())
        let operation = Task {
            try await sut.data(for: request, maximumResponseBytes: 1024 * 1024)
        }
        await waitUntil { StreamingURLProtocol.controller.snapshot().emittedBytes > 0 }

        // Act
        operation.cancel()

        // Assert
        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(type(of: error))")
        }
        await waitUntil { StreamingURLProtocol.controller.snapshot().wasStopped }
        let snapshot = StreamingURLProtocol.controller.snapshot()
        #expect(snapshot.wasStopped)
        #expect(snapshot.emittedBytes < chunks.reduce(0) { $0 + $1.count })
        #expect(!snapshot.didFinish)
    }

    private func urlSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        return configuration
    }

    private func testURL() throws -> URL {
        try #require(URL(string: "https://support.example.com/stream"))
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool,
        timeout: Duration = .seconds(2),
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
    }
}

private class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
    static let controller = StreamingResponseController()

    private let stateLock = NSLock()
    private var producer: Task<Void, Never>?
    private var runID: UUID?
    private var stopped = false

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil,
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let run = Self.controller.begin()
        stateLock.withLock {
            runID = run.id
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let task = Task { @Sendable [weak self] in
            guard let self else { return }
            for chunk in run.chunks {
                do {
                    try await Task.sleep(for: run.delay)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      Self.controller.recordEmission(of: chunk.count, runID: run.id)
                else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            guard Self.controller.finish(runID: run.id) else { return }
            client?.urlProtocolDidFinishLoading(self)
        }

        let shouldCancel = stateLock.withLock {
            producer = task
            return stopped
        }
        if shouldCancel {
            task.cancel()
            Self.controller.stop(runID: run.id)
        }
    }

    override func stopLoading() {
        let state = stateLock.withLock { () -> (Task<Void, Never>?, UUID?) in
            stopped = true
            let state = (producer, runID)
            producer = nil
            return state
        }
        state.0?.cancel()
        if let runID = state.1 {
            Self.controller.stop(runID: runID)
        }
    }
}

private final class StreamingResponseController: @unchecked Sendable {
    struct Run: Sendable {
        let id: UUID
        let chunks: [Data]
        let delay: Duration
    }

    struct Snapshot: Sendable {
        let emittedBytes: Int
        let wasStopped: Bool
        let didFinish: Bool
    }

    private let lock = NSLock()
    private var currentRun = Run(id: UUID(), chunks: [], delay: .zero)
    private var emittedBytes = 0
    private var wasStopped = false
    private var didFinish = false

    func configure(chunks: [Data], delay: Duration) {
        lock.withLock {
            currentRun = Run(id: UUID(), chunks: chunks, delay: delay)
            emittedBytes = 0
            wasStopped = false
            didFinish = false
        }
    }

    func begin() -> Run {
        lock.withLock { currentRun }
    }

    func recordEmission(of byteCount: Int, runID: UUID) -> Bool {
        lock.withLock {
            guard currentRun.id == runID, !wasStopped else { return false }
            emittedBytes += byteCount
            return true
        }
    }

    func finish(runID: UUID) -> Bool {
        lock.withLock {
            guard currentRun.id == runID, !wasStopped else { return false }
            didFinish = true
            return true
        }
    }

    func stop(runID: UUID) {
        lock.withLock {
            guard currentRun.id == runID else { return }
            wasStopped = true
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                emittedBytes: emittedBytes,
                wasStopped: wasStopped,
                didFinish: didFinish,
            )
        }
    }
}
