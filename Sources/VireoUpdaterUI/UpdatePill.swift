import SwiftUI
import VireoUpdater

/// A small pill in the window's bottom-left corner that surfaces the auto-update
/// state (mirrors cmux's "update pill"). It appears on its own when a new version
/// is published, is dismissable, and installs + relaunches on click.
///
/// The pill reads everything from ``UpdateModel``; all the Sparkle plumbing lives
/// in the `VireoUpdater` package.
public struct UpdatePill: View {
    @ObservedObject var model: UpdateModel
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: UpdateModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.isPillVisible {
                pill
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.85, anchor: .bottomLeading)
                            .combined(with: .opacity)
                            .combined(with: .offset(y: 6)),
                        removal: .opacity.combined(with: .offset(y: 4))
                    ))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 1),
                   value: model.isPillVisible)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 1),
                   value: model.phase)
    }

    private var pill: some View {
        HStack(spacing: 6) {
            actionable ? AnyView(actionButton) : AnyView(content)
            if hovering, model.isDismissable {
                dismissButton
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, hovering && model.isDismissable ? 5 : 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
                .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .foregroundStyle(.white)
        .font(.system(size: 11, weight: .semibold))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1),
                   value: hovering)
        .help(helpText)
        .fixedSize()
    }

    /// The tappable part (install / retry). Whether it's a button depends on the
    /// phase; download / install progress isn't clickable.
    private var actionable: Bool {
        model.phase == .available || model.phase == .error
    }

    private var actionButton: some View {
        Button {
            switch model.phase {
            case .available: model.install()
            case .error: model.retry()
            default: break
            }
        } label: {
            content
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 6) {
            indicator
            Text(label)
                .monospacedDigit()
                .fixedSize()
        }
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .checking, .installing:
            ProgressRing(progress: nil)
        case .downloading, .extracting:
            ProgressRing(progress: model.progress)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
        default: // .available
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 11, weight: .bold))
        }
    }

    private var label: String {
        switch model.phase {
        case .checking: return "Checking…"
        case .available: return "Update"
        case .downloading:
            if let p = model.progress { return "\(Int(p * 100))%" }
            return "Downloading…"
        case .extracting: return "Preparing…"
        case .installing: return "Installing…"
        case .error: return "Update failed"
        case .idle: return ""
        }
    }

    private var tint: Color {
        model.phase == .error ? Color(red: 0.80, green: 0.22, blue: 0.19) : .accentColor
    }

    private var dismissButton: some View {
        Button(action: model.dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 16, height: 16)
                .background(Circle().fill(.white.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help("Dismiss")
    }

    private var helpText: String {
        switch model.phase {
        case .available:
            if let v = model.availableVersion { return "Vireo \(v) is available — click to update" }
            return "An update is available — click to update"
        case .downloading, .extracting: return "Downloading the update…"
        case .installing: return "Installing — Vireo will relaunch"
        case .error: return model.errorMessage ?? "Update failed — click to retry"
        default: return ""
        }
    }
}

/// A tiny determinate/indeterminate progress ring for the pill indicator.
private struct ProgressRing: View {
    /// `nil` → indeterminate spinner; otherwise a `0...1` arc.
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let progress {
            ZStack {
                Circle().stroke(.white.opacity(0.28), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                               value: progress)
            }
            .frame(width: 12, height: 12)
        } else {
            IndeterminateRing()
        }
    }
}

private struct IndeterminateRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if reduceMotion {
            ZStack {
                Circle().stroke(.white.opacity(0.24), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.6,
                                                       lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
        } else {
            TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360
            ZStack {
                Circle().stroke(.white.opacity(0.24), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 12, height: 12)
            }
        }
    }
}

/// Tactile press feedback: a subtle scale on click (0.96), spring with no bounce.
private struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1),
                       value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
