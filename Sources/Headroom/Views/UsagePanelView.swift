import AppKit
import HeadroomCore
import SwiftUI

/// The popover content: one card per provider with a bar per quota window.
struct UsagePanelView: View {
    static let width: CGFloat = 360

    @ObservedObject var model: MainViewModel
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        // Sized to the content; only a panel taller than the screen scrolls.
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
        }
        .frame(width: Self.width)
        .frame(maxHeight: maxHeight)
    }

    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 40
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.visibleProviders.isEmpty {
                Text(model.noProvidersText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(model.visibleProviders) { provider in
                    ProviderCard(provider: provider, now: model.now)
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Headroom")
                .font(.headline)
            Spacer()
            Button {
                model.refresh(manual: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .keyboardShortcut("r", modifiers: .command)

            Menu {
                Button("Settings…", action: onSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Quit Headroom", action: onQuit)
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}

private struct ProviderCard: View {
    let provider: ProviderRow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(provider.subtitle(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if provider.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
            }

            if let windows = provider.snapshot?.windows, !windows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        WindowRow(window: window, now: now)
                    }
                }
            }

            if let note = provider.snapshot?.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = provider.error, !error.isEmpty {
                Label {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .monospacedDigit()
            }
            .font(.caption)

            QuotaBar(fraction: window.remainingPercent / 100, color: barColor)

            let reset = Formatting.resetText(window.resetsAt, description: window.resetDescription, now: now)
            if !reset.isEmpty {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        window.group.map { "\($0) · \(window.label)" } ?? window.label
    }

    private var barColor: Color {
        switch window.remainingPercent {
        case ...10: return .red
        case ...25: return .orange
        default: return .accentColor
        }
    }
}

/// A slim capsule meter, like the ones in Control Center.
private struct QuotaBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if fraction > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(proxy.size.width * min(fraction, 1), 6))
                }
            }
        }
        .frame(height: 6)
    }
}
