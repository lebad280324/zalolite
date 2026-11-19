import SwiftUI
import NativeBridge

private func jsonArray(_ value: JSONValue) -> [JSONValue]? { if case .array(let items) = value { return items } else { return nil } }

/// A group poll as the core reports it (re-notes/74).
struct PollSnapshot: Equatable {
    struct Option: Equatable, Identifiable {
        let id: UInt64
        let content: String
        let votes: Int
        let voted: Bool
        let voters: [String]
    }
    let id: UInt64
    let threadID: String
    let question: String
    let options: [Option]
    let joined: Bool
    let closed: Bool
    let multiple: Bool
    let expires: Date?
    var totalVotes: Int { options.reduce(0) { $0 + $1.votes } }
    var expired: Bool { expires.map { $0 < Date() } ?? false }

    init?(_ data: JSONValue?) {
        guard let poll = data?["poll"], let id = poll["poll_id"]?.number, id > 0, let thread = data?["thread_id"]?.string else { return nil }
        self.id = UInt64(id); threadID = thread
        question = poll["question"]?.string ?? ""
        options = (poll["options"].flatMap(jsonArray) ?? []).compactMap { option in
            guard let optionID = option["option_id"]?.number else { return nil }
            return Option(id: UInt64(optionID), content: option["content"]?.string ?? "", votes: Int(option["votes"]?.number ?? 0),
                          voted: option["voted"]?.bool ?? false, voters: (option["voters"].flatMap(jsonArray) ?? []).compactMap(\.string))
        }
        joined = poll["joined"]?.bool ?? false
        closed = poll["closed"]?.bool ?? false
        multiple = poll["multiple"]?.bool ?? false
        let expiry = poll["expired_time"]?.number ?? 0
        expires = expiry > 0 ? Date(timeIntervalSince1970: expiry > 1e11 ? expiry / 1000 : expiry) : nil
    }
}

extension AppStore {
    /// Loads a poll once a notice for it is on screen; repeated notices share one request a minute.
    func loadPoll(_ id: UInt64, thread: ThreadSnapshot, force: Bool = false) {
        guard supports("poll_detail"), thread.isGroup else { return }
        if !force, let last = pollRequested[id], Date().timeIntervalSince(last) < 60 { return }
        pollRequested[id] = Date()
        send("poll_detail", parameters: ["thread_id": .string(thread.id), "poll_id": .number(Double(id))], threadID: thread.id)
    }

    func vote(_ poll: PollSnapshot, options: Set<UInt64>) {
        guard supports("poll_vote"), !options.isEmpty else { return }
        send("poll_vote", parameters: ["thread_id": .string(poll.threadID), "poll_id": .number(Double(poll.id)),
                                       "option_ids": .array(options.sorted().map { .number(Double($0)) })], threadID: poll.threadID)
    }

    func handlePollResult(_ data: JSONValue?) {
        guard let poll = PollSnapshot(data), polls[poll.id] != poll else { return }
        polls[poll.id] = poll
        // The card grows once its options arrive; transcript rows re-measure.
        transcript.presentationVersion += 1
    }
}

/// The poll in place of its vote notices: question, options with their share of votes, and voting.
struct PollCard: View {
    @EnvironmentObject private var store: AppStore
    let message: MessageSnapshot
    let thread: ThreadSnapshot
    let pollID: UInt64
    @State private var choice: Set<UInt64> = []
    @State private var editing = false

    private var poll: PollSnapshot? { store.polls[pollID] }
    private var voting: Bool { store.busy.contains("poll_vote") }
    private var canVote: Bool { poll.map { !$0.closed && !$0.expired } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal").foregroundStyle(Color.accentColor)
                Text(verbatim: poll?.question.isEmpty == false ? poll!.question : "Bình chọn")
                    .font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let poll {
                ForEach(poll.options) { option in optionRow(option, poll: poll) }
                footer(poll)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Đang tải bình chọn…").font(.callout).foregroundStyle(.secondary) }
            }
            Text(verbatim: message.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: 380, alignment: .leading)
        .nativeGlass(18)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .onAppear { store.loadPoll(pollID, thread: thread) }
        .onValueChange(of: poll) { _, poll in
            if let poll, !editing { choice = Set(poll.options.filter(\.voted).map(\.id)) }
        }
        .contextMenu {
            Button("Tải lại bình chọn", systemImage: "arrow.clockwise") { store.loadPoll(pollID, thread: thread, force: true) }
            Button("Sao chép", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
        }
    }

    private func optionRow(_ option: PollSnapshot.Option, poll: PollSnapshot) -> some View {
        let share = poll.totalVotes > 0 ? Double(option.votes) / Double(poll.totalVotes) : 0
        let selected = choice.contains(option.id)
        return Button {
            guard canVote else { return }
            editing = true
            if poll.multiple { if selected { choice.remove(option.id) } else { choice.insert(option.id) } }
            else { choice = [option.id] }
        } label: {
            HStack(spacing: 8) {
                if canVote {
                    Image(systemName: selected ? (poll.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                                               : (poll.multiple ? "square" : "circle"))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                Text(verbatim: option.content).font(.callout).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(option.votes)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(option.voted ? 0.28 : 0.14))
                        .frame(width: max(0, proxy.size.width * share))
                }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.content), \(option.votes) phiếu\(option.voted ? ", bạn đã chọn" : "")")
    }

    @ViewBuilder private func footer(_ poll: PollSnapshot) -> some View {
        HStack(spacing: 8) {
            Text(poll.closed ? "Đã khóa · \(poll.totalVotes) phiếu" : poll.expired ? "Đã hết hạn · \(poll.totalVotes) phiếu"
                 : poll.multiple ? "Chọn nhiều · \(poll.totalVotes) phiếu" : "\(poll.totalVotes) phiếu")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if canVote {
                let current = Set(poll.options.filter(\.voted).map(\.id))
                Button(poll.joined ? "Đổi bình chọn" : "Bình chọn") { editing = false; store.vote(poll, options: choice) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(choice.isEmpty || choice == current || voting)
            }
        }
    }
}
