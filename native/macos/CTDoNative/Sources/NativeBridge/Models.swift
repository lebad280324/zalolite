import Foundation

/// Values carried by the versioned, local JSON-lines boundary.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
    public subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

/// An event never contains authentication material; credentials stay in Rust.
public struct CoreEvent: Codable, Sendable {
    public var id: String?
    public var event: String
    public var command: String?
    public var ok: Bool?
    public var data: JSONValue?
    public var error: String?
    public var preparedThreads: [ThreadSnapshot]? = nil
    public var preparedMessages: MessagesSnapshot? = nil
    enum CodingKeys: String, CodingKey { case id,event,command,ok,data,error }
    /// Decode and reconcile large snapshots on the transport queue, before MainActor.
    public mutating func prepareForUI() throws {
        if event == "threads", let data {
            let rows = try data.decode([ThreadSnapshot].self)
            var unique: [String: ThreadSnapshot] = [:]
            for row in rows { unique[row.id] = row }
            preparedThreads = unique.values.sorted { $0.id < $1.id }
            self.data = nil
        } else if ["messages", "message_page"].contains(event), let data {
            var snapshot = try data.decode(MessagesSnapshot.self)
            var unique: [String: MessageSnapshot] = [:]
            for row in snapshot.messages { unique[row.id] = row }
            snapshot.messages = unique.values.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
            preparedMessages = snapshot
            self.data = nil
        }
    }
}

public struct SessionSnapshot: Codable, Sendable {
    public var loggedIn: Bool
    public var uin: String
    public var name: String
    public var avatar: String?
    public init(loggedIn: Bool = false, uin: String = "", name: String = "", avatar: String? = nil) {
        self.loggedIn = loggedIn; self.uin = uin; self.name = name; self.avatar = avatar
    }
    enum CodingKeys: String, CodingKey { case loggedIn = "logged_in", uin, name, avatar }
}

/// One member image of a composite group avatar.
public struct AvatarMember: Codable, Hashable, Sendable {
    public var name: String
    public var avatar: String?
    public init(name: String, avatar: String?) { self.name = name; self.avatar = avatar }
}

public struct ThreadSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isGroup: Bool
    public var avatar: String?
    public var avatarMembers: [AvatarMember]
    public var memberTotal: Int?
    public var unread: Int
    public var markedUnread: Bool
    public var hasUnread: Bool { unread > 0 || markedUnread }
    public var pinned: Bool
    public var muted: Bool
    public var hidden: Bool
    public var lastMessage: String
    public var lastMessageTimestamp: Double
    enum CodingKeys: String, CodingKey {
        case id, name, avatar, unread, pinned, muted, hidden
        case markedUnread = "marked_unread"
        case isGroup = "is_group", lastMessage = "last_message", lastMessageTimestamp = "last_message_ts"
        case avatarMembers = "avatar_members", memberTotal = "member_total"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Cuộc trò chuyện"
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        avatarMembers = (try? c.decodeIfPresent([AvatarMember].self, forKey: .avatarMembers)) ?? []
        memberTotal = try? c.decodeIfPresent(Int.self, forKey: .memberTotal)
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        markedUnread = try c.decodeIfPresent(Bool.self, forKey: .markedUnread) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage) ?? ""
        lastMessageTimestamp = try c.decodeIfPresent(Double.self, forKey: .lastMessageTimestamp) ?? 0
    }
    public var date: Date { bridgeDate(lastMessageTimestamp) }
}

public struct MessageSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var senderID: String
    public var senderName: String
    public var text: String
    public var timestamp: Double
    public var isOutgoing: Bool
    public var messageType: String
    public var imageURL: String?
    public var fileURL: String?
    public var fileName: String?
    public var reactions: JSONValue?
    /// Per-emoji counts and reactor IDs; empty for history that never carried them.
    public var reactionDetails: [ReactionDetail] = []
    public var replyToID: String?
    public var replyToSender: String?
    public var replyToText: String?
    public var linkURL: String?
    public var linkTitle: String?
    public var linkThumbnail: String?
    /// The page description of a link preview, when Zalo sent one.
    public var linkDescription: String?
    /// The attachment's copy on this Mac, imported from a Zalo export; preferred over the web copy.
    public var localPath: String?
    /// Contact (`kind: contact`) or call (`kind: call`) card read from the attachment.
    public var card: JSONValue?
    public var stickerID: UInt64?
    public var stickerCategoryID: UInt64?
    /// Place of this photo in a batch sent together (Zalo's `group_layout_id`).
    public var photoGroup: PhotoGroup?
    enum CodingKeys: String, CodingKey {
        case id, text, timestamp, reactions
        case reactionDetails = "reaction_details"
        case senderID = "sender_id", senderName = "sender_name", isOutgoing = "is_outgoing"
        case messageType = "msg_type", imageURL = "image_url", fileURL = "file_url", fileName = "file_name"
        case replyToID = "reply_to_id", replyToSender = "reply_to_sender", replyToText = "reply_to_text"
        case linkURL = "link_url", linkTitle = "link_title", linkThumbnail = "link_thumb", linkDescription = "link_desc", localPath = "local_path", card
        case stickerID = "sticker_id", stickerCategoryID = "sticker_cate_id", photoGroup = "photo_group"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        senderID = try c.decodeIfPresent(String.self, forKey: .senderID) ?? ""
        senderName = try c.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp) ?? 0
        isOutgoing = try c.decodeIfPresent(Bool.self, forKey: .isOutgoing) ?? false
        messageType = try c.decodeIfPresent(String.self, forKey: .messageType) ?? "text"
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        fileURL = try c.decodeIfPresent(String.self, forKey: .fileURL)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        reactions = try c.decodeIfPresent(JSONValue.self, forKey: .reactions)
        reactionDetails = (try? c.decodeIfPresent([ReactionDetail].self, forKey: .reactionDetails)) ?? []
        replyToID = try c.decodeIfPresent(String.self, forKey: .replyToID)
        replyToSender = try c.decodeIfPresent(String.self, forKey: .replyToSender)
        replyToText = try c.decodeIfPresent(String.self, forKey: .replyToText)
        linkURL = try c.decodeIfPresent(String.self, forKey: .linkURL)
        linkTitle = try c.decodeIfPresent(String.self, forKey: .linkTitle)
        linkThumbnail = try c.decodeIfPresent(String.self, forKey: .linkThumbnail)
        linkDescription = try? c.decodeIfPresent(String.self, forKey: .linkDescription)
        localPath = try? c.decodeIfPresent(String.self, forKey: .localPath)
        card = try? c.decodeIfPresent(JSONValue.self, forKey: .card)
        stickerID = try? c.decodeIfPresent(UInt64.self, forKey: .stickerID)
        stickerCategoryID = try? c.decodeIfPresent(UInt64.self, forKey: .stickerCategoryID)
        photoGroup = try? c.decodeIfPresent(PhotoGroup.self, forKey: .photoGroup)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id &&
        lhs.senderID == rhs.senderID &&
        lhs.senderName == rhs.senderName &&
        lhs.text == rhs.text &&
        lhs.timestamp == rhs.timestamp &&
        lhs.isOutgoing == rhs.isOutgoing &&
        lhs.messageType == rhs.messageType &&
        lhs.imageURL == rhs.imageURL &&
        lhs.fileURL == rhs.fileURL &&
        lhs.fileName == rhs.fileName &&
        lhs.reactions == rhs.reactions &&
        lhs.reactionDetails == rhs.reactionDetails &&
        lhs.replyToID == rhs.replyToID &&
        lhs.replyToSender == rhs.replyToSender &&
        lhs.replyToText == rhs.replyToText &&
        lhs.linkURL == rhs.linkURL &&
        lhs.linkTitle == rhs.linkTitle &&
        lhs.linkThumbnail == rhs.linkThumbnail &&
        lhs.linkDescription == rhs.linkDescription &&
        lhs.localPath == rhs.localPath &&
        lhs.card == rhs.card &&
        lhs.photoGroup == rhs.photoGroup
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public var date: Date { bridgeDate(timestamp) }
    /// The group poll a vote/create notice refers to.
    public var pollID: UInt64? {
        guard case .object(let card)? = card, case .number(let id)? = card["poll_id"], id > 0 else { return nil }
        return UInt64(exactly: id)
    }
}

/// A photo's place in a batch; photos sharing `groupID` are drawn as one grid.
public struct PhotoGroup: Codable, Hashable, Sendable {
    public var groupID: String
    public var index: Int
    public var total: Int?
    public var width: Int?
    public var height: Int?
    enum CodingKeys: String, CodingKey { case groupID = "group_id", index, total, width, height }
    public init(groupID: String, index: Int, total: Int? = nil, width: Int? = nil, height: Int? = nil) {
        self.groupID = groupID; self.index = index; self.total = total; self.width = width; self.height = height
    }
}

/// Stable pagination identity, including messages with identical timestamps.
public struct HistoryCursor: Codable, Equatable, Sendable {
    public var timestamp: Int64
    public var id: String
    public init(timestamp: Int64, id: String) {self.timestamp=timestamp;self.id=id}
}

public struct MessagesSnapshot: Codable, Sendable {
    public var threadID: String
    public var messages: [MessageSnapshot]
    public var account: String?
    public var hasMore: Bool?
    public var cursor: HistoryCursor?
    public var before: HistoryCursor?
    public var after: HistoryCursor?
    enum CodingKeys: String, CodingKey { case threadID = "thread_id", messages, account, cursor, before, after; case hasMore = "has_more" }
}

public struct StickerPack: Codable, Identifiable, Sendable {
    public var id: UInt64
    public var name: String
    public var totalImage: Int?
    public var iconURL: String?
    enum CodingKeys: String, CodingKey { case id, name, totalImage = "total_image", iconURL = "icon_url" }
}

public struct StickerItem: Codable, Identifiable, Sendable {
    public var stickerID: UInt64
    public var categoryID: UInt64
    public var stickerType: UInt32
    public var label: String?
    public var imageURL: String?
    /// Horizontal sprite strip for animated stickers, with its frame count and duration.
    public var spriteURL: String?
    public var totalFrames: Int?
    public var durationMs: Int?
    public var id: UInt64 { stickerID }
    enum CodingKeys: String, CodingKey {
        case stickerID = "sticker_id", categoryID = "cate_id", stickerType = "sticker_type", label, imageURL = "image_url"
        case spriteURL = "sprite_url", totalFrames = "total_frames", durationMs = "duration_ms"
    }
}

public struct ScheduledMessage: Codable, Identifiable, Sendable {
    public var id: Int64
    public var threadID: String
    public var threadName: String
    public var isGroup: Bool
    public var text: String
    public var deliverAt: Int64
    public var status: String
    public var hasError: Bool
    enum CodingKeys: String, CodingKey {
        case id, text, status, threadID = "thread_id", threadName = "thread_name", isGroup = "is_group"
        case deliverAt = "deliver_at", hasError = "has_error"
    }
    public var date: Date { Date(timeIntervalSince1970: Double(deliverAt)) }
}

/// Older captures use milliseconds while some local stores use seconds.
public func bridgeDate(_ timestamp: Double) -> Date {
    Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp)
}

/// Only standard web URLs can leave the local application through message actions.
public func safeWebURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
          url.user == nil, url.password == nil else { return nil }
    return url
}

/// One reaction type on a message: its emoji, total count and who reacted.
public struct ReactionDetail: Codable, Hashable, Sendable {
    public var emoji: String
    public var count: Int
    public var reactors: [String]
    /// Reactions per person in `reactors`, same order; one when Zalo did not say.
    public var reactorCounts: [Int] = []
    public init(emoji: String, count: Int, reactors: [String], reactorCounts: [Int] = []) {
        self.emoji = emoji; self.count = count; self.reactors = reactors; self.reactorCounts = reactorCounts
    }
    enum CodingKeys: String, CodingKey { case emoji, count, reactors; case reactorCounts = "reactor_counts" }
    public func count(for index: Int) -> Int { reactorCounts.indices.contains(index) ? max(1, reactorCounts[index]) : 1 }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try c.decode(String.self, forKey: .emoji)
        count = Int(try c.decodeIfPresent(Double.self, forKey: .count) ?? 1)
        reactors = try c.decodeIfPresent([String].self, forKey: .reactors) ?? []
        reactorCounts = (try? c.decodeIfPresent([Int].self, forKey: .reactorCounts)) ?? []
    }
}
