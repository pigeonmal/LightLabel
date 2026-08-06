import Foundation

public struct ProjectMetadata: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var projectID: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var metadata: [String: String]

    public init(projectID: UUID, name: String, schemaVersion: Int = 1, createdAt: Date = Date(), modifiedAt: Date = Date(), metadata: [String: String] = [:]) {
        self.schemaVersion = schemaVersion; self.projectID = projectID; self.name = name; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.metadata = metadata
    }
}

public enum ProjectPersistenceError: LocalizedError, Sendable { case invalidDirectory, encodingFailed
    public var errorDescription: String? { switch self { case .invalidDirectory: "The project directory is invalid."; case .encodingFailed: "The project could not be encoded." } }
}

public actor ProjectPersistence {
    public let directoryURL: URL
    private let encoder: JSONEncoder
    private var pendingSave: Task<Void, Never>?
    private var pendingError: Error?

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    }

    public func loadDataset() throws -> AnnotationDataset {
        let data = try Data(contentsOf: directoryURL.appendingPathComponent("dataset.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnnotationDataset.self, from: data)
    }

    public func save(_ dataset: AnnotationDataset) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(dataset)
        try atomicWrite(data, to: directoryURL.appendingPathComponent("dataset.json"))
    }

    public func save(_ metadata: ProjectMetadata) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try atomicWrite(encoder.encode(metadata), to: directoryURL.appendingPathComponent("project.json"))
    }

    /// Replaces a pending delayed save, useful for editor autosave.
    public func scheduleSave(_ dataset: AnnotationDataset, after delay: Duration = .milliseconds(350)) {
        pendingSave?.cancel()
        pendingError = nil
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            do { try await self?.save(dataset) } catch { await self?.record(error) }
            await self?.clearCompletedSave()
        }
    }

    public func cancelScheduledSave() { pendingSave?.cancel(); pendingSave = nil }

    public func flushScheduledSave() async throws {
        await pendingSave?.value
        pendingSave = nil
        if let pendingError {
            self.pendingError = nil
            throw pendingError
        }
    }

    private func clearCompletedSave() { pendingSave = nil }
    private func record(_ error: Error) { pendingError = error }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
