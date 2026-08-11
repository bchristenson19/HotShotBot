import AppKit
import Foundation
import CoreGraphics
import ImageIO

/// Decodes a Panasonic camera's MJPEG-over-HTTP stream (`multipart/x-mixed-replace`) into a
/// sequence of `NSImage` frames.
///
/// There's no AVFoundation support for MJPEG-over-HTTP on macOS, so this parses the raw byte
/// stream itself: rather than parsing the multipart boundary string out of the `Content-Type`
/// header (fragile — boundary tokens vary by camera firmware), it scans the accumulated bytes
/// directly for JPEG SOI (`0xFFD8`) / EOI (`0xFFD9`) markers. Everything between one frame's EOI
/// and the next frame's SOI — the multipart boundary line and per-part headers — is simply
/// skipped over, since only the bytes from SOI to EOI are handed to the JPEG decoder.
///
/// This is a `URLSessionDataDelegate` rather than `async`/`await` streaming because the
/// connection is long-lived and effectively never completes on its own (the camera keeps the
/// HTTP response open indefinitely) — delegate callbacks let each chunk be processed as it
/// arrives without holding the whole stream in memory.
final class MJPEGStreamDecoder: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case connecting
        case streaming
        case error(String)
    }

    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var status: Status = .idle
    @Published private(set) var frameCount: Int = 0

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var desiredURL: URL?
    private var reconnectWorkItem: DispatchWorkItem?

    /// How far into `buffer` (as an offset from `buffer.startIndex`, not an absolute `Data.Index`)
    /// the EOI search has already confirmed there's no marker. Without this, `consume()` would
    /// re-scan the whole accumulated buffer from the front on every single incoming TCP chunk —
    /// for a frame arriving across ~19 chunks this made the aggregate scan cost ~10x the actual
    /// frame size (measured), enough on its own to blow well past the 33ms/frame budget at 30fps.
    /// Must be reset to 0 any time bytes are removed from the front of `buffer`, since that
    /// invalidates the offset's meaning.
    private var eoiSearchFrom = 0

    /// Hard cap on the byte buffer so a malformed/never-terminated stream (missing EOI marker)
    /// can't grow memory unbounded — if we blow past this without completing a frame, the
    /// buffer is dropped and we wait for the next SOI to resync.
    private static let maxBufferBytes = 8 * 1024 * 1024

    private static let soiMarker: (UInt8, UInt8) = (0xFF, 0xD8)
    private static let eoiMarker: (UInt8, UInt8) = (0xFF, 0xD9)

    /// Manual pointer scan for a 2-byte marker, starting at offset `from` (relative to `data`'s
    /// own indexing, i.e. 0-based regardless of `data.startIndex`). Measured ~120x faster than
    /// `Data.firstRange(of:)` for this exact 2-byte-pattern-in-a-large-buffer workload — the
    /// stdlib's generic `Collection`-based search carries enormous per-byte overhead that a raw
    /// `withUnsafeBytes` loop doesn't.
    private static func findMarker(_ marker: (UInt8, UInt8), in data: Data, from: Int) -> Int? {
        let count = data.count
        guard from >= 0, from + 1 < count else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.baseAddress else { return nil }
            let buf = base.assumingMemoryBound(to: UInt8.self)
            var i = from
            while i < count - 1 {
                if buf[i] == marker.0 && buf[i + 1] == marker.1 { return i }
                i += 1
            }
            return nil
        }
    }

    func start(url: URL) {
        stop()
        desiredURL = url
        connect(to: url)
    }

    func stop() {
        desiredURL = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll()
        eoiSearchFrom = 0
        setStatus(.idle)
    }

    private func connect(to url: URL) {
        setStatus(.connecting)
        buffer.removeAll()
        eoiSearchFrom = 0

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        // The stream is long-lived by design (the camera never closes the response), so the
        // resource timeout needs to be effectively unbounded rather than the 7-day default
        // being relied upon implicitly.
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let newTask = newSession.dataTask(with: request)
        session = newSession
        task = newTask
        newTask.resume()
    }

    private func scheduleReconnect() {
        guard desiredURL != nil else { return }
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.desiredURL else { return }
            self.connect(to: url)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func setStatus(_ newStatus: Status) {
        DispatchQueue.main.async { [weak self] in
            self?.status = newStatus
        }
    }

    /// Appends newly-received bytes to the buffer and extracts as many complete JPEG frames as
    /// are available. Called on the URLSession delegate queue (a private background queue), not
    /// the main thread — only the final `@Published` update is hopped over to the main thread.
    ///
    /// Uses `Self.findMarker`/`eoiSearchFrom` rather than `Data.firstRange(of:)` starting from
    /// the buffer's front every call — see `eoiSearchFrom`'s doc comment for why that mattered.
    private func consume(_ data: Data) {
        buffer.append(data)

        while true {
            guard let soiOffset = Self.findMarker(Self.soiMarker, in: buffer, from: 0) else {
                // No frame start found at all yet — bound memory and wait for more data.
                if buffer.count > Self.maxBufferBytes {
                    buffer.removeAll()
                    eoiSearchFrom = 0
                }
                return
            }
            // Discard any multipart boundary / header bytes preceding the frame start.
            if soiOffset > 0 {
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + soiOffset))
                eoiSearchFrom = 0
            }

            guard let eoiOffset = Self.findMarker(Self.eoiMarker, in: buffer, from: max(2, eoiSearchFrom)) else {
                // Frame started but hasn't finished arriving yet — remember how far the search
                // already got so the next call resumes instead of re-scanning from the front.
                eoiSearchFrom = max(2, buffer.count - 1)
                if buffer.count > Self.maxBufferBytes {
                    // Something is malformed (no EOI within a very large frame) — resync by
                    // dropping this partial frame and searching for the next SOI.
                    buffer.removeAll()
                    eoiSearchFrom = 0
                }
                return
            }

            let frameEnd = buffer.startIndex + eoiOffset + 2
            let frameData = buffer.subdata(in: buffer.startIndex..<frameEnd)
            buffer.removeSubrange(buffer.startIndex..<frameEnd)
            eoiSearchFrom = 0

            decodeAndPublish(frameData)
        }
    }

    /// Guards `latestPendingImage`/`publishInFlight` below — accessed from both the delegate
    /// queue (writer) and the main thread (reader/clearer), so needs real synchronization rather
    /// than relying on `@MainActor`/`DispatchQueue.main.async` alone.
    private let publishLock = NSLock()
    private var latestPendingImage: NSImage?
    private var publishInFlight = false

    /// Publishes at most one pending frame to the main thread at a time — if frames decode
    /// faster than the main thread drains them (e.g. a transient stall), later frames simply
    /// overwrite `latestPendingImage` instead of queuing another `DispatchQueue.main.async`
    /// closure behind the ones already scheduled. Without this, a backlog of queued closures
    /// would each display a progressively staler frame, visibly replaying "in slow motion"
    /// rather than skipping ahead to the current one, once frames were arriving fast again after
    /// the `consume()` rescan fix above.
    private func decodeAndPublish(_ frameData: Data) {
        guard let source = CGImageSourceCreateWithData(frameData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        publishLock.lock()
        latestPendingImage = image
        let shouldSchedule = !publishInFlight
        publishInFlight = true
        publishLock.unlock()
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishLock.lock()
            let imageToShow = self.latestPendingImage
            self.publishInFlight = false
            self.publishLock.unlock()
            guard let imageToShow else { return }
            self.currentFrame = imageToShow
            self.frameCount += 1
            if self.status != .streaming { self.status = .streaming }
        }
    }
}

extension MJPEGStreamDecoder: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        consume(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                // Manual stop() — not a failure, don't reconnect.
                return
            }
            setStatus(.error(error.localizedDescription))
            scheduleReconnect()
        } else {
            // Camera closed the connection cleanly (rare for MJPEG, but handle it) — retry.
            setStatus(.error("Stream ended"))
            scheduleReconnect()
        }
    }
}
