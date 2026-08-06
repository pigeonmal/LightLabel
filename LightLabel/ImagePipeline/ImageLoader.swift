import Foundation
import ImageIO
import CoreGraphics

public enum ImageLoaderError: LocalizedError, Sendable { case unreadable(URL); case noImage(URL)
    public var errorDescription: String? { switch self { case let .unreadable(url): "Could not read image at \(url.path)."; case let .noImage(url): "No image frame exists at \(url.path)." } }
}

public actor ImageLoader {
    public let maximumConcurrentLoads: Int
    private var activeLoads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maximumConcurrentLoads: Int = 3) { self.maximumConcurrentLoads = max(1, maximumConcurrentLoads) }

    public func thumbnail(at url: URL, maximumPixelSize: Int) async throws -> CGImage {
        await acquire()
        defer { release() }
        return try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageLoaderError.unreadable(url) }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize), kCGImageSourceCreateThumbnailWithTransform: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageLoaderError.noImage(url) }
            return image
        }.value
    }

    public func fullImage(at url: URL) async throws -> CGImage {
        await acquire()
        defer { release() }
        return try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageLoaderError.unreadable(url) }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else { throw ImageLoaderError.noImage(url) }
            return image
        }.value
    }

    private func acquire() async {
        if activeLoads < maximumConcurrentLoads { activeLoads += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        activeLoads += 1
    }
    private func release() {
        activeLoads -= 1
        if let waiter = waiters.first { waiters.removeFirst(); waiter.resume() }
    }
}
