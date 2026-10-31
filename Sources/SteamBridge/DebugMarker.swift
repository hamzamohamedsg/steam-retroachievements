import Foundation

/// The empty file that makes Steam serve its DevTools port on 127.0.0.1.
public struct DebugMarker: Sendable {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS")

    public let url: URL

    public init(directory: URL = DebugMarker.defaultDirectory) {
        url = directory.appendingPathComponent(".cef-enable-remote-debugging")
    }

    public func exists() -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public func ensure() throws {
        if !exists() { try Data().write(to: url) }
    }

    public func remove() throws {
        if exists() { try FileManager.default.removeItem(at: url) }
    }

    public var createdAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
    }
}
