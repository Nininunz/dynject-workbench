import AppKit
import DynjectCore
import SwiftUI

struct Chip: View {
    var text: String
    var color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

struct GateRow: View {
    var title: String
    var outcome: GateOutcome

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: outcome.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.passed ? .green : .red)
            Text(title).fontWeight(.medium)
            Text(outcome.reason).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct BannerView: View {
    var banner: Banner
    var dismiss: () -> Void

    var color: Color {
        switch banner.kind {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).fontWeight(.semibold)
                if let d = banner.detail {
                    Text(d).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.3)))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityIdentifier("banner")
    }
}

struct DiffView: View {
    var old: String
    var new: String

    var body: some View {
        let ops = LineDiff.diff(old, new)
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ops.enumerated()), id: \.offset) { _, op in
                    switch op {
                    case let .same(l): line(" ", l, .clear, .secondary)
                    case let .added(l): line("+", l, .green.opacity(0.15), .primary)
                    case let .removed(l): line("-", l, .red.opacity(0.15), .primary)
                    }
                }
            }
            .padding(6)
        }
        .font(.system(.callout, design: .monospaced))
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("config-diff")
    }

    func line(_ mark: String, _ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text("\(mark) \(text)")
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bg)
            .textSelection(.enabled)
    }
}

struct DiagnosticsList: View {
    var diagnostics: [ConfigDiagnostic]
    var onSelect: (Int?) -> Void = { _ in }

    var body: some View {
        if diagnostics.isEmpty {
            Label("No problems found. Parsed with dynjectd's own rules.", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
                .font(.callout)
                .padding(8)
                .accessibilityIdentifier("diagnostics-list")
        } else {
            List(diagnostics) { d in
                Button { onSelect(d.line) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: d.severity == .error ? "xmark.octagon.fill" : d.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(d.severity == .error ? .red : d.severity == .warning ? .orange : .blue)
                        Text(d.line.map { "Line \($0 + 1)" } ?? "File").monospacedDigit().frame(width: 60, alignment: .leading)
                        Text(d.message).textSelection(.enabled)
                    }
                }
                .buttonStyle(.plain)
            }
            .accessibilityIdentifier("diagnostics-list")
        }
    }
}

extension String {
    var lastPathComponent: String { (self as NSString).lastPathComponent }
}

extension View {
    /// Identifies a container without overriding its children's identifiers (a bare
    /// `.accessibilityIdentifier` on a stack propagates to every child).
    func axContainer(_ id: String) -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }
}
