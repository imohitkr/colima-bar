import SwiftUI

struct LogView: View {
    @Bindable var store: LogStore
    var openInTerminal: () -> Void

    // This body reads no line data. Each flush re-renders only the list,
    // the follow scroller and the footer.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter lines", text: $store.search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .hint("Show only lines containing this text (case-insensitive).")
                Toggle("Follow", isOn: $store.follow).hint("Keep scrolled to the newest line.")
                Toggle("Time", isOn: $store.showTime).hint("Show each line's timestamp (local time).")
                Toggle("Wrap", isOn: $store.wrap).hint("Wrap long lines instead of scrolling sideways.")
                Toggle("stderr", isOn: $store.stderrOnly).hint("Show only lines the container wrote to stderr.")
                Spacer()
                IconButton("doc.on.doc", "Copy all lines that pass the filters.") { Pasteboard.copy(store.allText) }
                IconButton("trash", "Clear the window. New lines keep arriving.") { store.clear() }
                IconButton("terminal", "Follow these logs in iTerm instead.") { openInTerminal() }
            }
            .toggleStyle(.checkbox).controlSize(.small)
            .padding(8)
            Divider()
            LogList(store: store)
            Divider()
            LogFooter(store: store)
            HintBar()
        }
        .frame(minWidth: 640, minHeight: 360)
    }
}

/// The newest visible lines (see `LogTail`). It reads `visible` but not
/// `lines`, so lines that the filter hides do not re-render it.
private struct LogList: View {
    let store: LogStore

    var body: some View {
        let showTime = store.showTime
        let wrap = store.wrap
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let shown = store.shown
                    if store.tailStart > 0 {
                        Text(
                            "Showing the newest \(shown.count) of \(store.visible.count) lines. Use the filter to find older lines. Copy includes all lines."
                        )
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    }
                    ForEach(shown) { line in
                        LogRow(line: line, showTime: showTime, wrap: wrap)
                            .id(line.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(FollowScroller(store: store, proxy: proxy))
        }
    }
}

private struct LogRow: View {
    let line: LogLine
    let showTime: Bool
    let wrap: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showTime {
                Text(line.time).foregroundStyle(.tertiary)
            }
            Text(line.text)
                .foregroundStyle(line.isStderr ? Color.red.opacity(0.9) : .primary)
                .fixedSize(horizontal: !wrap, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Scrolls to the newest visible line when Follow is on and the visible
/// lines change (new lines, a new search or stderr filter), and when Follow
/// is turned on. It is a separate view, so these reads do not re-render the list.
private struct FollowScroller: View {
    let store: LogStore
    let proxy: ScrollViewProxy

    private struct Key: Equatable {
        let last: Int?
        let count: Int
        let follow: Bool
    }

    var body: some View {
        Color.clear
            .onChange(of: Key(last: store.visible.last?.id, count: store.visible.count, follow: store.follow)) {
                if store.follow, let last = store.visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
    }
}

private struct LogFooter: View {
    let store: LogStore

    var body: some View {
        HStack {
            Circle().fill(store.status == .live ? Color.green : .orange).frame(width: 6, height: 6)
            Text(store.status.text)
            Spacer()
            Text("\(store.visible.count) of \(store.lines.count) lines").monospacedDigit()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}
