import Foundation

public actor TurnDetailCache {
    private struct Record: Codable {
        let version: Int
        let turnKey: String
        let storedAt: Date
        let reasoningSamples: [TurnReasoningSample]
    }

    public static func defaultDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexPulse", isDirectory: true)
            .appendingPathComponent("turn-details", isDirectory: true)
    }

    private let directoryURL: URL?
    private let memoryCapacity: Int
    private let maxDiskBytes: Int
    private let maxDiskAge: TimeInterval
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var memory: [String: [TurnReasoningSample]] = [:]
    private var recency: [String] = []
    private var storeCount = 0

    public init(
        directoryURL: URL? = nil,
        memoryCapacity: Int = 8,
        maxDiskBytes: Int = 128 * 1_024 * 1_024,
        maxDiskAge: TimeInterval = 7 * 24 * 60 * 60,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.memoryCapacity = max(1, memoryCapacity)
        self.maxDiskBytes = max(1, maxDiskBytes)
        self.maxDiskAge = max(60, maxDiskAge)
        self.fileManager = fileManager
        if let directoryURL {
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
    }

    public func store(
        reasoningSamples: [TurnReasoningSample],
        for turnKey: String
    ) throws {
        guard reasoningSamples.isEmpty == false else {
            return
        }

        retainInMemory(reasoningSamples, for: turnKey)
        guard let fileURL = fileURL(for: turnKey) else {
            return
        }

        let record = Record(
            version: 1,
            turnKey: turnKey,
            storedAt: Date(),
            reasoningSamples: reasoningSamples
        )
        try encoder.encode(record).write(to: fileURL, options: .atomic)
        storeCount += 1
        if storeCount == 1 || storeCount.isMultiple(of: 64) {
            try pruneDisk()
        }
    }

    public func loadReasoningSamples(for turnKey: String) -> [TurnReasoningSample] {
        if let cached = memory[turnKey] {
            touch(turnKey)
            return cached
        }
        guard let fileURL = fileURL(for: turnKey),
              let data = try? Data(contentsOf: fileURL),
              let record = try? decoder.decode(Record.self, from: data),
              record.version == 1,
              record.turnKey == turnKey else {
            return []
        }
        retainInMemory(record.reasoningSamples, for: turnKey)
        return record.reasoningSamples
    }

    public func removeAll() throws {
        memory.removeAll()
        recency.removeAll()
        guard let directoryURL,
              fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }
        try fileManager.removeItem(at: directoryURL)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func retainInMemory(_ samples: [TurnReasoningSample], for turnKey: String) {
        memory[turnKey] = samples
        touch(turnKey)
        while recency.count > memoryCapacity {
            let evicted = recency.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    private func touch(_ turnKey: String) {
        recency.removeAll(where: { $0 == turnKey })
        recency.append(turnKey)
    }

    private func fileURL(for turnKey: String) -> URL? {
        directoryURL?.appendingPathComponent(
            String(format: "%016llx.json", stableHash(turnKey)),
            isDirectory: false
        )
    }

    private func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func pruneDisk(referenceDate: Date = Date()) throws {
        guard let directoryURL else {
            return
        }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]
        var files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }

        let cutoff = referenceDate.addingTimeInterval(-maxDiskAge)
        for file in files where file.date < cutoff {
            try? fileManager.removeItem(at: file.url)
        }
        files.removeAll(where: { $0.date < cutoff })

        var totalBytes = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where totalBytes > maxDiskBytes {
            try? fileManager.removeItem(at: file.url)
            totalBytes -= file.size
        }
    }
}
