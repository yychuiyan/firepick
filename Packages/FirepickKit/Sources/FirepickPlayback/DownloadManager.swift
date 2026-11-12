import Foundation
import FirepickCore
import Observation

public enum DownloadStatus: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

public struct OfflineMedia: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sourceKey: String
    public var vodId: String
    public var episodeId: String
    public var title: String
    public var episodeName: String
    public var fileName: String
    public var remoteURL: String
    public var headers: [String: String]
    public var createdAt: Date
    public var fileSize: Int64
    public var status: DownloadStatus
    public var progress: Double
    public var error: String?

    public init(
        id: String,
        sourceKey: String,
        vodId: String,
        episodeId: String,
        title: String,
        episodeName: String,
        fileName: String,
        remoteURL: String = "",
        headers: [String: String] = [:],
        createdAt: Date = .now,
        fileSize: Int64 = 0,
        status: DownloadStatus = .queued,
        progress: Double = 0,
        error: String? = nil
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.vodId = vodId
        self.episodeId = episodeId
        self.title = title
        self.episodeName = episodeName
        self.fileName = fileName
        self.remoteURL = remoteURL
        self.headers = headers
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.status = status
        self.progress = progress
        self.error = error
    }
}

@MainActor
@Observable
public final class DownloadManager {
    public private(set) var entries: [OfflineMedia] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    public init(directory: URL? = nil, session: URLSession = .shared) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directory = base.appendingPathComponent("Downloads", isDirectory: true)
        }
        self.session = session
        try FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
        try load()
    }

    public func download(
        request: PlaybackRequest,
        sourceKey: String,
        item: MediaItem,
        episode: Episode
    ) {
        let id = "\(sourceKey)|\(item.vodId)|\(episode.value)"
        if let existing = entries.first(where: { $0.id == id }) {
            if existing.status == .completed,
               let url = fileURL(existing),
               fileManager.fileExists(atPath: url.path) {
                return
            }
            if existing.status != .completed {
                retry(id: id)
            }
            return
        }

        let extensionName = mediaExtension(request)
        let digest = ConfigurationDigest.sha256(Data(id.utf8)).prefix(20)
        let safeTitle = sanitized(item.name).prefix(80)
        let fileName = "\(digest)-\(safeTitle).\(extensionName)"
        var entry = OfflineMedia(
            id: id,
            sourceKey: sourceKey,
            vodId: item.vodId,
            episodeId: episode.value,
            title: item.name,
            episodeName: episode.name,
            fileName: fileName,
            remoteURL: request.url.absoluteString,
            headers: request.headers
        )
        entry.status = .queued
        entries.insert(entry, at: 0)
        persist()
        start(entry.id, request: request)
    }

    public func retry(id: String) {
        guard let index = entryIndex(id),
              entries[index].status != .completed,
              let url = URL(string: entries[index].remoteURL) else {
            return
        }
        let request = PlaybackRequest(
            url: url,
            headers: entries[index].headers,
            formatHint: entries[index].fileName
        )
        tasks[id]?.cancel()
        entries[index].error = nil
        entries[index].status = .queued
        entries[index].progress = 0
        persist()
        start(id, request: request)
    }

    public func pause(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        guard let index = entryIndex(id), entries[index].status != .completed else {
            return
        }
        entries[index].status = .paused
        persist()
    }

    public func importFile(from source: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let identifier = UUID().uuidString
        let safe = sanitized(source.deletingPathExtension().lastPathComponent)
        let extensionName = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let fileName = "\(identifier)-\(safe).\(extensionName)"
        let destination = try checkedFileURL(fileName)
        try fileManager.copyItem(at: source, to: destination)
        let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        entries.insert(
            OfflineMedia(
                id: "import|\(identifier)",
                sourceKey: "local",
                vodId: identifier,
                episodeId: identifier,
                title: source.deletingPathExtension().lastPathComponent,
                episodeName: "本地文件",
                fileName: fileName,
                fileSize: size,
                status: .completed,
                progress: 1
            ),
            at: 0
        )
        persist()
    }

    public func remove(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        guard let index = entryIndex(id) else { return }
        let entry = entries.remove(at: index)
        if let url = fileURL(entry) {
            try? fileManager.removeItem(at: url)
        }
        try? fileManager.removeItem(at: partURL(entry))
        persist()
    }

    public func fileURL(_ entry: OfflineMedia) -> URL? {
        try? checkedFileURL(entry.fileName)
    }

    public func playbackRequest(for entry: OfflineMedia) -> PlaybackRequest? {
        guard let url = fileURL(entry), fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return PlaybackRequest(url: url, formatHint: entry.fileName)
    }

    private func start(_ id: String, request: PlaybackRequest) {
        tasks[id]?.cancel()
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            await run(id: id, request: request)
        }
    }

    private func run(id: String, request: PlaybackRequest) async {
        guard let index = entryIndex(id) else { return }
        let entry = entries[index]
        let destination = partURL(entry)
        let finalDestination = fileURL(entry)
        guard let finalDestination else {
            finish(id: id, error: "下载文件名无效")
            return
        }
        update(id) {
            $0.status = .downloading
            $0.error = nil
        }

        do {
            let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
            var offset = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            var upstream = URLRequest(url: request.url)
            upstream.timeoutInterval = 60
            request.headers.forEach {
                upstream.setValue($0.value, forHTTPHeaderField: $0.key)
            }
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 {
                upstream.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            }

            let (http, chunks) = try await DownloadChunkStream.open(
                request: upstream,
                session: session
            )
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 416, offset > 0 {
                    try? fileManager.moveItem(at: destination, to: finalDestination)
                    update(id) {
                        $0.status = .completed
                        $0.progress = 1
                        $0.fileSize = offset
                    }
                    persist()
                    tasks[id] = nil
                    return
                }
                throw FirepickError.network("下载失败：HTTP \(http.statusCode)")
            }
            if http.statusCode == 200 {
                offset = 0
                try? fileManager.removeItem(at: destination)
            }
            if !fileManager.fileExists(atPath: destination.path) {
                fileManager.createFile(atPath: destination.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()

            let responseLength = max(0, http.expectedContentLength)
            let total = responseLength > 0 ? offset + responseLength : 0
            var written = offset
            var buffer = Data()
            buffer.reserveCapacity(65_536)
            for try await chunk in chunks {
                try Task.checkCancellation()
                buffer.append(chunk)
                if buffer.count >= 65_536 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    updateProgress(id: id, written: written, total: total)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            try handle.synchronize()
            try? fileManager.removeItem(at: finalDestination)
            try fileManager.moveItem(at: destination, to: finalDestination)
            update(id) {
                $0.status = .completed
                $0.progress = 1
                $0.fileSize = written
            }
            persist()
            tasks[id] = nil
        } catch is CancellationError {
            if let index = entryIndex(id), entries[index].status == .downloading {
                entries[index].status = .paused
            }
            persist()
            tasks[id] = nil
        } catch {
            finish(id: id, error: error.localizedDescription)
            tasks[id] = nil
        }
    }

    private func update(_ id: String, change: (inout OfflineMedia) -> Void) {
        guard let index = entryIndex(id) else { return }
        change(&entries[index])
    }

    private func updateProgress(id: String, written: Int64, total: Int64) {
        update(id) {
            $0.fileSize = written
            $0.progress = total > 0 ? min(0.99, Double(written) / Double(total)) : 0
        }
    }

    private func finish(id: String, error: String?) {
        update(id) {
            $0.status = .failed
            $0.error = error
        }
        persist()
    }

    private func entryIndex(_ id: String) -> Int? {
        entries.firstIndex(where: { $0.id == id })
    }

    private func partURL(_ entry: OfflineMedia) -> URL {
        directory
            .appendingPathComponent(entry.fileName)
            .appendingPathExtension("part")
    }

    private func checkedFileURL(_ fileName: String) throws -> URL {
        guard !fileName.contains("/"), !fileName.contains("\\"), !fileName.isEmpty else {
            throw FirepickError.network("下载文件名无效")
        }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func mediaExtension(_ request: PlaybackRequest) -> String {
        let hint = request.formatHint
            .flatMap(URL.init(string:))?
            .path
            ?? request.url.path
        let value = URL(fileURLWithPath: hint).pathExtension.lowercased()
        let allowed = [
            "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "ts",
            "m2ts", "iso", "mp3", "m4a", "aac", "flac", "wav",
        ]
        return allowed.contains(value) ? value : "mp4"
    }

    private func sanitized(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
        let result = value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "media" : result
    }

    private var metadataURL: URL {
        directory.appendingPathComponent("downloads.json")
    }

    private func load() throws {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return }
        let data = try Data(contentsOf: metadataURL)
        entries = try JSONDecoder().decode([OfflineMedia].self, from: data)
        for index in entries.indices {
            if entries[index].status == .downloading || entries[index].status == .queued {
                entries[index].status = .paused
            }
            if let url = fileURL(entries[index]),
               !fileManager.fileExists(atPath: url.path),
               entries[index].status == .completed {
                entries[index].status = .failed
                entries[index].error = "本地文件已丢失"
            }
        }
        persist()
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(entries).write(to: metadataURL, options: .atomic)
        } catch {
            NSLog("Firepick download metadata error: %@", error.localizedDescription)
        }
    }
}

private final class DownloadChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?

    override init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        super.init()
    }

    static func open(
        request: URLRequest,
        session parent: URLSession
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let delegate = DownloadChunkStream()
        let session = URLSession(
            configuration: parent.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        delegate.session = session
        let task = session.dataTask(with: request)
        delegate.task = task
        let response = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
            delegate.responseContinuation = continuation
            task.resume()
        }
        return (response, delegate.stream)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            let error = FirepickError.network("下载服务返回无效响应")
            responseContinuation?.resume(throwing: error)
            responseContinuation = nil
            completionHandler(.cancel)
            return
        }
        responseContinuation?.resume(returning: http)
        responseContinuation = nil
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        continuation.yield(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            responseContinuation?.resume(throwing: error)
            responseContinuation = nil
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
        self.session = nil
        self.task = nil
    }
}
