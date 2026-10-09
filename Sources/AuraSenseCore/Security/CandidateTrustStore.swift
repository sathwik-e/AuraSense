import Foundation

/// Errors that may occur during candidate device registration or retrieval.
public enum TrustStoreError: LocalizedError, Sendable, Equatable {
    case persistenceFailed(String)
    case candidateNotFound
    case invalidCandidateData

    public var errorDescription: String? {
        switch self {
        case .persistenceFailed(let reason):
            return "Failed to persist candidate device: \(reason)"
        case .candidateNotFound:
            return "No trusted candidate device is currently registered."
        case .invalidCandidateData:
            return "Stored candidate device data is corrupted or invalid."
        }
    }
}

/// Abstract contract for managing trusted candidate device registration and persistence.
public protocol CandidateTrustStoreProtocol: Sendable {
    var registeredCandidate: CandidateDevice? { get }
    var lastLoadError: TrustStoreError? { get }
    func register(candidate: CandidateDevice) throws
    func unregister() throws
    func isRegistered(peripheralID: UUID) -> Bool
}

extension CandidateTrustStoreProtocol {
    public var lastLoadError: TrustStoreError? { nil }
}

/// Thread-safe in-memory trust store primarily used for automated testing.
public final class InMemoryCandidateTrustStore: CandidateTrustStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var candidate: CandidateDevice?

    public init(initialCandidate: CandidateDevice? = nil) {
        self.candidate = initialCandidate
    }

    public var registeredCandidate: CandidateDevice? {
        lock.lock()
        defer { lock.unlock() }
        return candidate
    }

    public func register(candidate: CandidateDevice) throws {
        lock.lock()
        defer { lock.unlock() }
        self.candidate = candidate
    }

    public func unregister() throws {
        lock.lock()
        defer { lock.unlock() }
        self.candidate = nil
    }

    public func isRegistered(peripheralID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate?.id == peripheralID
    }
}

/// Persistent file-backed trust store saving candidate metadata into Application Support.
public final class PersistentCandidateTrustStore: CandidateTrustStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let storageURL: URL
    private var cachedCandidate: CandidateDevice?
    private var _lastLoadError: TrustStoreError?

    public var lastLoadError: TrustStoreError? {
        lock.lock()
        defer { lock.unlock() }
        return _lastLoadError
    }

    public init(storageURL: URL? = nil) {
        if let customURL = storageURL {
            self.storageURL = customURL
            self.cachedCandidate = nil
            self._lastLoadError = nil
            self.cachedCandidate = loadFromDisk()
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Application Support", isDirectory: true)
            let aurasenseDir = appSupport.appendingPathComponent("AuraSense", isDirectory: true)
            self.storageURL = aurasenseDir.appendingPathComponent("trusted_candidate.json")
            self.cachedCandidate = nil
            self._lastLoadError = nil
            do {
                try FileManager.default.createDirectory(at: aurasenseDir, withIntermediateDirectories: true)
                self.cachedCandidate = loadFromDisk()
            } catch {
                self._lastLoadError = .persistenceFailed("Unable to create candidate storage directory: \(error.localizedDescription)")
            }
        }
    }

    public var registeredCandidate: CandidateDevice? {
        lock.lock()
        defer { lock.unlock() }
        return cachedCandidate
    }

    public func register(candidate: CandidateDevice) throws {
        lock.lock()
        defer { lock.unlock() }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(candidate)

            let parentDir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            try data.write(to: storageURL, options: .atomic)
            self.cachedCandidate = candidate
            self._lastLoadError = nil
        } catch {
            throw TrustStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    public func unregister() throws {
        lock.lock()
        defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                try FileManager.default.removeItem(at: storageURL)
            } catch {
                throw TrustStoreError.persistenceFailed("Failed to delete candidate store: \(error.localizedDescription)")
            }
        }
        self.cachedCandidate = nil
        self._lastLoadError = nil
    }

    public func isRegistered(peripheralID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedCandidate?.id == peripheralID
    }

    /// Recovers a corrupt store by deleting the malformed file and resetting error state.
    public func recoverCorruptStore() throws {
        lock.lock()
        defer { lock.unlock() }

        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                try FileManager.default.removeItem(at: storageURL)
            } catch {
                throw TrustStoreError.persistenceFailed("Failed to clear corrupt candidate file: \(error.localizedDescription)")
            }
        }
        self.cachedCandidate = nil
        self._lastLoadError = nil
    }

    private func loadFromDisk() -> CandidateDevice? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            _lastLoadError = nil
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            _lastLoadError = .persistenceFailed("Unreadable candidate store: \(error.localizedDescription)")
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let candidate = try decoder.decode(CandidateDevice.self, from: data)
            _lastLoadError = nil
            return candidate
        } catch {
            _lastLoadError = .invalidCandidateData
            return nil
        }
    }
}
