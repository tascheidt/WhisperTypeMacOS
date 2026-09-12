import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    @Published var status = AppStatus()
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel?

    func show(status: AppStatus) {
        model.status = status
        if panel == nil { panel = makePanel() }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func update(status: AppStatus) { model.status = status }
    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentViewController = NSHostingController(rootView: DictationOverlayView(model: model))
        return panel
    }

    private func positionPanel() {
        guard let panel else { return }
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let screen = mouseScreen ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 52))
    }
}

private struct DictationOverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(statusColor.opacity(0.18)).frame(width: 42, height: 42)
                Image(systemName: model.status.phase.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: model.status.phase == .processing)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(model.status.mode == .command ? "Command" : model.status.phase.label)
                        .font(.system(size: 13, weight: .semibold))
                    if model.status.isHandsFree {
                        Text("HANDS-FREE")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                if model.status.phase == .listening {
                    HStack(spacing: 3) {
                        ForEach(0..<16, id: \.self) { index in
                            Capsule().fill(statusColor.opacity(0.85)).frame(width: 3, height: barHeight(index))
                        }
                    }.frame(height: 18)
                } else {
                    Text(model.status.message)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.status.phase == .listening {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 310, height: 64)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15)))
        .padding(5)
    }

    private var statusColor: Color {
        switch model.status.phase {
        case .error: .red
        case .success: .green
        case .processing, .inserting: .blue
        case .listening: model.status.mode == .command ? .orange : .purple
        case .idle: .secondary
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let rhythm = CGFloat((index * 7) % 9) / 9
        return max(3, CGFloat(model.status.level) * (8 + rhythm * 13))
    }
}
