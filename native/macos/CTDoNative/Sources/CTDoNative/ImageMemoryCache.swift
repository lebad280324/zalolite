import AppKit

/// Evicts decoded images before insertion so browsing new media has a fixed retention budget.
@MainActor
final class ImageMemoryCache<Key: Hashable> {
    private struct Entry {
        let image: NSImage
        let bytes: Int
        var lastUse: UInt64
    }

    private let byteLimit: Int
    private let countLimit: Int
    private let pressure: DispatchSourceMemoryPressure
    private var entries: [Key: Entry] = [:]
    private var sequence: UInt64 = 0
    private(set) var retainedBytes = 0

    init(byteLimit: Int, countLimit: Int) {
        precondition(byteLimit > 0 && countLimit > 0)
        self.byteLimit = byteLimit
        self.countLimit = countLimit
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.removeAll() }
        }
        pressure.activate()
    }

    deinit { pressure.cancel() }

    func image(for key: Key) -> NSImage? {
        guard let image = entries[key]?.image else { return nil }
        sequence &+= 1
        entries[key]?.lastUse = sequence
        return image
    }

    func insert(_ image: NSImage, for key: Key, bytes: Int) {
        if let previous = entries.removeValue(forKey: key) {
            retainedBytes -= previous.bytes
        }
        guard bytes > 0, bytes <= byteLimit else { return }
        while entries.count >= countLimit || retainedBytes > byteLimit - bytes {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            retainedBytes -= oldest.value.bytes
            entries.removeValue(forKey: oldest.key)
        }
        sequence &+= 1
        entries[key] = Entry(image: image, bytes: bytes, lastUse: sequence)
        retainedBytes += bytes
    }

    private func removeAll() {
        entries.removeAll()
        retainedBytes = 0
    }
}
