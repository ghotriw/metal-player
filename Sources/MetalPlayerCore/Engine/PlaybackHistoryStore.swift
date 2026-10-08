import CryptoKit
import Foundation
import os

/// Represents a persistent playback progress record for a media resource.
public struct PlaybackRecord: Codable, Sendable, Equatable {
    public let position: Double
    public let duration: Double
    public let lastUpdated: Date

    public init(position: Double, duration: Double, lastUpdated: Date = Date()) {
        self.position = position
        self.duration = duration
        self.lastUpdated = lastUpdated
    }
}

/// Thread-safe storage manager for recording and restoring media playback positions (Watch Later / Resume Playback).
public final class PlaybackHistoryStore: Sendable {
    public static let shared = PlaybackHistoryStore()

    nonisolated(unsafe) private let userDefaults: UserDefaults
    private let keyPrefix = "MetalPlayer.PlaybackHistory."
    private let lock = OSAllocatedUnfairLock()
    public let maxRecordsLimit = 10_000

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Normalizes a media path or URL into a persistent storage key using SHA-256.
    public func storageKey(for path: String) -> String {
        let normalized: String
        if let url = URL(string: path), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.query = nil
                components.fragment = nil
                normalized = components.string ?? path
            } else {
                normalized = url.path
            }
        } else {
            normalized = URL(fileURLWithPath: path).standardized.path
        }

        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hexString = digest.map { String(format: "%02x", $0) }.joined()
        return keyPrefix + hexString
    }

    /// Saves the current playback position for a media resource, respecting start and end thresholds.
    public func savePosition(
        for path: String,
        position: Double,
        duration: Double,
        startThreshold: Double = 15.0,
        endThresholdRatio: Double = 0.95
    ) {
        guard duration > 0 else { return }

        // If watched for less than start threshold, treat as unwatched (clear)
        if position < startThreshold {
            clearPosition(for: path)
            return
        }

        // If watched past end threshold (e.g. credits at 95% or last 30s), mark as finished (clear)
        let endThresholdSeconds = duration * endThresholdRatio
        if position >= endThresholdSeconds || (duration - position) <= 30.0 {
            clearPosition(for: path)
            return
        }

        let record = PlaybackRecord(position: position, duration: duration, lastUpdated: Date())
        let key = storageKey(for: path)

        lock.withLock {
            if let encoded = try? JSONEncoder().encode(record) {
                userDefaults.set(encoded, forKey: key)
            }
            pruneExcessRecordsIfNeeded()
        }
    }

    /// Retrieves the saved playback position for a media resource, or `nil` if not eligible.
    public func savedPosition(
        for path: String,
        startThreshold: Double = 15.0,
        endThresholdRatio: Double = 0.95
    ) -> Double? {
        let key = storageKey(for: path)

        return lock.withLock {
            guard let data = userDefaults.data(forKey: key),
                let record = try? JSONDecoder().decode(PlaybackRecord.self, from: data)
            else {
                return nil
            }

            guard record.duration > 0 else { return nil }
            guard record.position >= startThreshold else { return nil }

            let endThresholdSeconds = record.duration * endThresholdRatio
            guard record.position < endThresholdSeconds && (record.duration - record.position) > 30.0 else {
                return nil
            }

            return record.position
        }
    }

    /// Removes the saved playback position for a specific media path.
    public func clearPosition(for path: String) {
        let key = storageKey(for: path)
        lock.withLock {
            userDefaults.removeObject(forKey: key)
        }
    }

    /// Clears all stored playback positions.
    public func clearAll() {
        lock.withLock {
            let dict = userDefaults.dictionaryRepresentation()
            for key in dict.keys where key.hasPrefix(keyPrefix) {
                userDefaults.removeObject(forKey: key)
            }
        }
    }

    /// Ensures the stored records count does not exceed `maxRecordsLimit` (removes oldest by `lastUpdated`).
    private func pruneExcessRecordsIfNeeded() {
        let dict = userDefaults.dictionaryRepresentation()
        let matchingKeys = dict.keys.filter { $0.hasPrefix(keyPrefix) }

        guard matchingKeys.count > maxRecordsLimit else { return }

        // Decode records with keys to sort by date
        var recordsWithKeys: [(key: String, date: Date)] = []
        for key in matchingKeys {
            if let data = dict[key] as? Data,
                let record = try? JSONDecoder().decode(PlaybackRecord.self, from: data)
            {
                recordsWithKeys.append((key: key, date: record.lastUpdated))
            } else {
                // Invalid or corrupted data, remove immediately
                userDefaults.removeObject(forKey: key)
            }
        }

        // Sort ascending (oldest first)
        recordsWithKeys.sort { $0.date < $1.date }

        let excessCount = recordsWithKeys.count - maxRecordsLimit
        if excessCount > 0 {
            for i in 0..<excessCount {
                userDefaults.removeObject(forKey: recordsWithKeys[i].key)
            }
        }
    }
}
