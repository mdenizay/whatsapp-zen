import SwiftUI

/// A group of chats the user put together ("Work", "Clients"). Lists live on
/// this Mac, one set per account.
struct ChatList: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var emoji: String
    var chats: [String] = []
    /// Its chats are left out of All and only shown under the list.
    var hideFromAll = false

    var title: String { emoji.isEmpty ? name : "\(emoji) \(name)" }

    init(id: String = UUID().uuidString, name: String, emoji: String, chats: [String] = [], hideFromAll: Bool = false) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.chats = chats
        self.hideFromAll = hideFromAll
    }

    // Lists saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        chats = try c.decodeIfPresent([String].self, forKey: .chats) ?? []
        hideFromAll = try c.decodeIfPresent(Bool.self, forKey: .hideFromAll) ?? false
    }
}

/// What the chat list is showing.
enum ChatFilter: Hashable {
    case all, unread, groups, archived
    case list(String)

    func includes(_ chat: Chat, lists: [ChatList]) -> Bool {
        guard chat.archived == (self == .archived) || isList else { return false }
        switch self {
        case .archived: return true
        case .all: return !lists.contains { $0.hideFromAll && $0.chats.contains(chat.jid) }
        case .unread: return chat.unread > 0
        case .groups: return chat.isGroup
        case .list(let id): return lists.first { $0.id == id }?.chats.contains(chat.jid) == true
        }
    }

    private var isList: Bool {
        if case .list = self { return true }
        return false
    }
}

extension AppStore {
    private var listsKey: String { "account.\(id).lists" }

    func loadLists() -> [ChatList] {
        if Self.isDemo { return Demo.lists }
        guard let data = UserDefaults.standard.data(forKey: listsKey) else { return [] }
        return (try? JSONDecoder().decode([ChatList].self, from: data)) ?? []
    }

    func saveLists() {
        // Demo data must never end up in the real account's lists.
        guard !Self.isDemo, let data = try? JSONEncoder().encode(lists) else { return }
        UserDefaults.standard.set(data, forKey: listsKey)
    }

    func save(list: ChatList) {
        if let index = lists.firstIndex(where: { $0.id == list.id }) {
            lists[index] = list
        } else {
            lists.append(list)
        }
    }

    func delete(list: ChatList) {
        lists.removeAll { $0.id == list.id }
    }

    func isInList(_ chat: String, _ list: ChatList) -> Bool { list.chats.contains(chat) }

    func setInList(_ chat: String, _ list: ChatList, _ on: Bool) {
        guard var updated = lists.first(where: { $0.id == list.id }) else { return }
        updated.chats.removeAll { $0 == chat }
        if on { updated.chats.append(chat) }
        save(list: updated)
    }

    /// Unread chats in a list, for its chip.
    func unreadCount(in list: ChatList) -> Int {
        let members = Set(list.chats)
        return chats.filter { members.contains($0.jid) && $0.unread > 0 }.count
    }
}

/// Opens the list editor for a new list or an existing one.
enum ListEditorTarget: Identifiable {
    case new(adding: String?)
    case edit(ChatList)

    var id: String {
        switch self {
        case .new(let jid): return "new-\(jid ?? "")"
        case .edit(let list): return list.id
        }
    }
}

/// The row of filter chips above the chat list: the fixed filters, then the
/// user's own lists, a button to make one, and the archive.
struct FilterBar: View {
    @EnvironmentObject var store: AppStore
    @Binding var filter: ChatFilter
    @Binding var editor: ListEditorTarget?
    /// The menu bar panel shows only what fits there.
    var compact = false

    @State private var deleting: ChatList?

    var body: some View {
        // Wraps onto more lines rather than scrolling sideways, which a mouse
        // wheel cannot do.
        FlowLayout(spacing: 6) {
            chip(L("All"), .all)
            chip(L("Unread"), .unread, count: compact ? 0 : store.chats.filter { $0.unread > 0 && !$0.archived }.count)
            if !compact {
                chip(L("Groups"), .groups)
                chip(L("Archived"), .archived)
                // Next to the fixed filters, so it does not start a line of its own.
                Button { editor = .new(adding: nil) } label: {
                    Image(systemName: "plus").font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.06), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("New List"))
            }
            ForEach(store.lists) { list in
                chip(list.title, .list(list.id), count: store.unreadCount(in: list))
                    .contextMenu {
                        Button(L("Edit List…"), systemImage: "pencil") { editor = .edit(list) }
                        Toggle(L("Hide These Chats from All"), isOn: Binding(get: { list.hideFromAll }, set: { on in
                            var updated = list
                            updated.hideFromAll = on
                            store.save(list: updated)
                        }))
                        Button(L("Delete List"), systemImage: "trash", role: .destructive) { deleting = list }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .confirmationDialog(L("Delete this list?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Delete List"), role: .destructive) {
                guard let list = deleting else { return }
                if filter == .list(list.id) { filter = .all }
                store.delete(list: list)
            }
        } message: {
            Text(L("The chats themselves are not deleted."))
        }
        // A list that is gone cannot stay selected.
        .onChange(of: store.lists) { _, lists in
            if case .list(let id) = filter, !lists.contains(where: { $0.id == id }) { filter = .all }
        }
    }

    private func chip(_ title: String, _ value: ChatFilter, count: Int = 0) -> some View {
        let selected = filter == value
        return Button { filter = value } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if count > 0 {
                    Text("\(count)").font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(selected ? AnyShapeStyle(Theme.accent.opacity(0.18)) : AnyShapeStyle(.primary.opacity(0.06)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The chat row's "Add to List" submenu.
struct AddToListMenu: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat
    @Binding var editor: ListEditorTarget?

    var body: some View {
        Menu(L("Add to List"), systemImage: "folder.badge.plus") {
            ForEach(store.lists) { list in
                Toggle(list.title, isOn: Binding(get: { store.isInList(chat.jid, list) },
                                                 set: { store.setInList(chat.jid, list, $0) }))
            }
            if !store.lists.isEmpty { Divider() }
            Button(L("New List…")) { editor = .new(adding: chat.jid) }
        }
    }
}

/// Creates or edits a list: its name, an emoji, and which chats are in it.
struct ListEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: ListEditorTarget

    @State private var name = ""
    @State private var emoji = ""
    @State private var members: [String] = []
    @State private var hideFromAll = false
    @State private var query = ""
    @FocusState private var nameFocused: Bool

    private static let emojis = ["💼", "🤝", "👥", "🏠", "❤️", "⭐️", "🛒", "📚",
                                 "🎯", "🧾", "🚀", "🎉", "⚽️", "✈️", "🏦", "🛠️"]

    private var existing: ChatList? {
        if case .edit(let list) = target { return list }
        return nil
    }

    private var shown: [Chat] {
        let all = store.chats.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        // Chats already in the list first, so they are easy to review.
        let set = Set(members)
        return all.filter { set.contains($0.jid) } + all.filter { !set.contains($0.jid) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(existing == nil ? L("New List") : L("Edit List")).font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    Text(emoji.isEmpty ? "🗂️" : emoji).font(.system(size: 26))
                        .frame(width: 44, height: 44)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    TextField(L("Name, e.g. Work or Clients"), text: $name)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($nameFocused)
                        .onSubmit(save)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                    ForEach(Self.emojis, id: \.self) { item in
                        Button { emoji = emoji == item ? "" : item } label: {
                            Text(item).font(.system(size: 17))
                                .frame(width: 30, height: 30)
                                .background(emoji == item ? AnyShapeStyle(Theme.accent.opacity(0.22)) : AnyShapeStyle(.clear),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Toggle(isOn: $hideFromAll) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Hide these chats from All"))
                        Text(L("They are shown only under this list. Unread still shows them."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(20)

            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search chats"), text: $query).textFieldStyle(.plain)
                Text(L("%lld selected", members.count)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            List(shown) { chat in
                let on = members.contains(chat.jid)
                Button {
                    if on { members.removeAll { $0 == chat.jid } } else { members.append(chat.jid) }
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(jid: chat.jid, name: chat.name, size: 28, tick: store.avatarTick)
                        Text(chat.name).lineLimit(1)
                        Spacer()
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    }
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)

            Divider()
            HStack {
                if let existing {
                    Button(L("Delete List"), role: .destructive) {
                        store.delete(list: existing)
                        dismiss()
                    }
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? L("Create") : L("Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440, height: 600)
        .onAppear {
            switch target {
            case .new(let jid):
                members = jid.map { [$0] } ?? []
            case .edit(let list):
                name = list.name
                emoji = list.emoji
                members = list.chats
                hideFromAll = list.hideFromAll
            }
            nameFocused = true
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = existing ?? ChatList(name: trimmed, emoji: emoji)
        list.name = trimmed
        list.emoji = emoji
        list.chats = members
        list.hideFromAll = hideFromAll
        store.save(list: list)
        dismiss()
    }
}

/// Lays its children out left to right, starting a new line when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row(items: [index], width: size.width, height: size.height))
            } else {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width = needed
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            }
        }
        return rows
    }
}
