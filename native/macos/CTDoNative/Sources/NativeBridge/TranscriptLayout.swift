import Foundation

public struct TranscriptRow: Identifiable, Sendable {
    public let message: MessageSnapshot
    public let showsTimestamp: Bool
    public let startsRun: Bool
    public let endsRun: Bool
    /// Every photo of a batch sent together, in order; empty for an ordinary message.
    public var album: [MessageSnapshot] = []
    public var id: String { message.id }
}

/// A single pass over a single filtered snapshot, independent of visible row count.
public enum TranscriptLayout {
    public static func rows(_ messages: [MessageSnapshot], mediaOnly: Bool = false) -> [TranscriptRow] {
        let filtered = latestPollNotices(mediaOnly ? messages.filter { $0.imageURL != nil || $0.fileURL != nil } : messages)
        let (visible, albums) = collapseAlbums(filtered)
        guard !visible.isEmpty else { return [] }
        let calendar = Calendar.current
        func stamp(_ index: Int) -> Bool {
            if index == 0 { return true }
            let previous = visible[index - 1].date, current = visible[index].date
            return !calendar.isDate(previous, inSameDayAs: current) || current.timeIntervalSince(previous) >= 900
        }
        func same(_ lhs: MessageSnapshot, _ rhs: MessageSnapshot) -> Bool {
            lhs.isOutgoing == rhs.isOutgoing && (lhs.isOutgoing || (lhs.senderID == rhs.senderID && lhs.senderName == rhs.senderName))
        }
        let stamps = visible.indices.map(stamp)
        return visible.indices.map { index in
            TranscriptRow(message: visible[index], showsTimestamp: stamps[index],
                startsRun: index == 0 || stamps[index] || !same(visible[index-1],visible[index]),
                endsRun: index == visible.count-1 || stamps[index+1] || !same(visible[index],visible[index+1]),
                album: albums[visible[index].id] ?? [])
        }
    }

    /// Every vote in a poll arrives as its own notice; only the newest stays, drawn as the poll itself.
    public static func latestPollNotices(_ messages: [MessageSnapshot]) -> [MessageSnapshot] {
        var seen = Set<UInt64>()
        var keep = [Bool](repeating: true, count: messages.count)
        for index in messages.indices.reversed() {
            guard let poll = messages[index].pollID else { continue }
            if !seen.insert(poll).inserted { keep[index] = false }
        }
        return messages.indices.filter { keep[$0] }.map { messages[$0] }
    }

    /// Adjacent photos from one sender that share a batch ID become one row, keyed by the first photo.
    public static func collapseAlbums(_ messages: [MessageSnapshot]) -> ([MessageSnapshot], [String: [MessageSnapshot]]) {
        var rows: [MessageSnapshot] = []
        var albums: [String: [MessageSnapshot]] = [:]
        var index = 0
        while index < messages.count {
            let head = messages[index]
            guard let group = head.photoGroup?.groupID, head.imageURL != nil else { rows.append(head); index += 1; continue }
            var members = [head]
            var next = index + 1
            while next < messages.count, let other = messages[next].photoGroup?.groupID, other == group,
                  messages[next].imageURL != nil, messages[next].isOutgoing == head.isOutgoing, messages[next].senderID == head.senderID {
                members.append(messages[next]); next += 1
            }
            rows.append(head)
            if members.count > 1 { albums[head.id] = members.sorted { ($0.photoGroup?.index ?? 0, $0.timestamp) < ($1.photoGroup?.index ?? 0, $1.timestamp) } }
            index = next
        }
        return (rows, albums)
    }
}
