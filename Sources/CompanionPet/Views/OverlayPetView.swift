import AppKit
import SwiftUI

struct OverlayPetView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        let petDimension = appModel.settings.overlayScalePreset.petDimension
        let canvasSize = appModel.petCanvasSize()

        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
            GeometryReader { geometry in
                let renderFrame = appModel.renderFrame(at: context.date)

                ZStack(alignment: .bottomTrailing) {
                    if let renderFrame {
                        PetArtView(renderFrame: renderFrame)
                            .frame(width: petDimension, height: petDimension)
                            .scaleEffect(
                                x: appModel.dragFacingDirection == .left ? -1 : 1,
                                y: 1,
                                anchor: .center
                            )
                            .scaleEffect(appModel.isOverlayHovered ? 1.04 : 1.0, anchor: .bottomTrailing)
                            .shadow(
                                color: .white.opacity(appModel.isOverlayHovered ? 0.18 : 0.0),
                                radius: appModel.isOverlayHovered ? 14 : 0
                            )
                    } else {
                        Color.clear
                    }

                    if appModel.isOverlayHovered {
                        RoundedRectangle(cornerRadius: geometry.size.width * 0.26, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            .foregroundStyle(.white.opacity(0.65))
                            .padding(4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: appModel.isOverlayHovered)
                .contextMenu {
                    Button("Open Settings") {
                        appModel.openSettings()
                    }

                    Divider()

                    Button("Close Pet") {
                        appModel.quit()
                    }
                }
            }
        }
        .frame(
            width: canvasSize.width,
            height: canvasSize.height
        )
        .background(Color.clear)
    }
}

struct OverlayBubbleView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        if appModel.overlayBubbles.isEmpty {
            Color.clear
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(appModel.overlayBubbles) { bubble in
                    SpeechBubbleView(
                        title: bubble.title,
                        text: bubble.text,
                        symbolName: bubble.symbolName,
                        sourceBadge: bubble.sourceBadge,
                        onTap: {
                            appModel.handleOverlayBubbleTap(id: bubble.id)
                        },
                        onClose: {
                            appModel.dismissOverlayBubble(id: bubble.id)
                        }
                    )
                }
            }
            .padding(6)
            .frame(
                width: appModel.bubbleCanvasSize().width,
                height: appModel.bubbleCanvasSize().height,
                alignment: .topTrailing
            )
            .background(Color.clear)
        }
    }
}

private struct SpeechBubbleView: View {
    let title: String?
    let text: String
    let symbolName: String?
    let sourceBadge: OverlaySourceBadge
    let onTap: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if let symbolName {
                BubbleStatusIcon(symbolName: symbolName, hasTitle: title != nil)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }

                ScrollView(.vertical) {
                    Text(text)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: title == nil ? 48 : 34)
                .simultaneousGesture(TapGesture().onEnded(onTap))
            }

            BubbleSourceBadgeView(badge: sourceBadge)
        }
            .foregroundStyle(.primary.opacity(0.96))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.55), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(.regularMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(.white.opacity(0.5), lineWidth: 0.75)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close bubble")
                    .help("Close bubble")
                    .padding(5)
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            .overlay(alignment: .bottomTrailing) {
                SpeechBubbleTail()
                    .fill(.white.opacity(0.92))
                    .frame(width: 16, height: 12)
                    .rotationEffect(.degrees(-10))
                    .offset(x: -26, y: 10)
            }
            .frame(maxWidth: 270, alignment: .leading)
            .frame(height: 98, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct BubbleSourceBadgeView: View {
    let badge: OverlaySourceBadge

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: badge.symbolName)
                .font(.system(size: 8, weight: .bold))
                .symbolRenderingMode(.hierarchical)

            Text(badge.label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.45), lineWidth: 0.75)
        }
        .frame(maxWidth: 72, alignment: .trailing)
        .accessibilityLabel(badge.accessibilityLabel)
    }
}

private struct BubbleStatusIcon: View {
    let symbolName: String
    let hasTitle: Bool

    var body: some View {
        Group {
            if symbolName == "progress" {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.58)
                    .frame(width: 13, height: 13)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
            }
        }
        .padding(.top, hasTitle ? 2 : 1)
    }
}

private struct SpeechBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct PetArtView: View {
    let renderFrame: PetRenderFrame

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let backgroundColor = Color(hex: renderFrame.frame.backgroundHex ?? "#355A87") ?? .blue
            let accentColor = Color(hex: renderFrame.frame.tintHex ?? "#FFFFFF") ?? .white
            let usesOrbChrome = renderFrame.frame.kind == .symbol
            let motion = motionProfile(size: size)

            ZStack {
                if usesOrbChrome {
                    Ellipse()
                        .fill(backgroundColor.gradient)
                        .frame(width: size * 0.78, height: size * 0.84)
                        .overlay {
                            Ellipse()
                                .stroke(.white.opacity(0.22), lineWidth: size * 0.02)
                        }
                        .shadow(color: .black.opacity(0.18), radius: size * 0.05, y: size * 0.04)
                        .rotationEffect(.degrees(motion.bodyRotation))
                        .scaleEffect(motion.bodyScale)

                    facialFeatures(size: size)
                        .offset(x: motion.faceOffsetX, y: motion.faceOffsetY)
                } else {
                    Ellipse()
                        .fill(.black.opacity(0.24))
                        .frame(width: size * 0.66, height: size * 0.18)
                        .blur(radius: size * 0.035)
                        .offset(y: size * 0.36)
                }

                frameAsset(size: size, accentColor: accentColor)
                    .offset(
                        x: motion.assetOffsetX,
                        y: usesOrbChrome ? size * 0.05 + motion.assetOffsetY : motion.assetOffsetY
                    )
                    .rotationEffect(.degrees(motion.assetRotation))
            }
            .overlay {
                if renderFrame.semanticState != .sleeping {
                    Ellipse()
                        .stroke(.white.opacity(0.35), lineWidth: size * 0.018)
                        .blur(radius: size * 0.008)
                        .opacity(renderFrame.semanticState == .ambient ? 0.55 : 0.0)
                }
            }
            .offset(y: motion.floatOffsetY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func frameAsset(size: CGFloat, accentColor: Color) -> some View {
        switch renderFrame.frame.kind {
        case .symbol:
            Image(systemName: renderFrame.frame.value)
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accentColor)
                .frame(width: size * 0.38, height: size * 0.38)
        case .file:
            if let url = renderFrame.petPack.resolvedFrameURL(for: renderFrame.frame),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: size * 0.9, height: size * 0.9)
                    .shadow(color: .white.opacity(0.42), radius: size * 0.025)
                    .shadow(color: .black.opacity(0.5), radius: size * 0.04, y: size * 0.025)
            } else {
                Image(systemName: "questionmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(accentColor)
                    .frame(width: size * 0.3, height: size * 0.3)
            }
        }
    }

    @ViewBuilder
    private func facialFeatures(size: CGFloat) -> some View {
        VStack(spacing: size * 0.06) {
            HStack(spacing: size * 0.12) {
                eye(for: renderFrame.semanticState, left: true, size: size)
                eye(for: renderFrame.semanticState, left: false, size: size)
            }
            mouth(for: renderFrame.semanticState, size: size)
        }
        .offset(y: -size * 0.12)
    }

    @ViewBuilder
    private func eye(for state: CompanionStateName, left: Bool, size: CGFloat) -> some View {
        switch state {
        case .sleeping:
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: size * 0.08, height: size * 0.022)
                .rotationEffect(.degrees(left ? 10 : -10))
        case .error:
            Circle()
                .fill(.white)
                .frame(width: size * 0.055, height: size * 0.055)
                .overlay {
                    Circle()
                        .fill(.red.opacity(0.4))
                        .frame(width: size * 0.025, height: size * 0.025)
                }
        case .thinking, .working:
            RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                .fill(.white)
                .frame(width: size * 0.05, height: size * 0.07)
        default:
            Circle()
                .fill(.white)
                .frame(width: size * 0.06, height: size * 0.06)
        }
    }

    @ViewBuilder
    private func mouth(for state: CompanionStateName, size: CGFloat) -> some View {
        switch state {
        case .success, .ambient:
            ArcSmile()
                .stroke(.white.opacity(0.9), lineWidth: size * 0.018)
                .frame(width: size * 0.18, height: size * 0.1)
        case .error, .disconnected:
            ArcSmile()
                .rotation(Angle.degrees(180))
                .stroke(.white.opacity(0.9), lineWidth: size * 0.018)
                .frame(width: size * 0.18, height: size * 0.1)
        case .sleeping:
            Text("z")
                .font(.system(size: size * 0.12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        default:
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: size * 0.11, height: size * 0.025)
        }
    }

    private func motionProfile(size: CGFloat) -> PetMotionProfile {
        switch renderFrame.semanticState {
        case .working:
            return .init(
                bodyRotation: 8,
                bodyScale: 1.04,
                faceOffsetX: size * 0.04,
                faceOffsetY: -size * 0.01,
                assetOffsetX: size * 0.08,
                assetOffsetY: size * 0.035,
                assetRotation: -10,
                floatOffsetY: -size * 0.02
            )
        case .replying:
            return .init(
                bodyRotation: -4,
                bodyScale: 1.02,
                faceOffsetX: size * 0.015,
                faceOffsetY: -size * 0.005,
                assetOffsetX: size * 0.04,
                assetOffsetY: -size * 0.01,
                assetRotation: 4,
                floatOffsetY: -size * 0.012
            )
        case .thinking:
            return .init(
                bodyRotation: 3,
                bodyScale: 1.01,
                faceOffsetX: size * 0.012,
                faceOffsetY: 0,
                assetOffsetX: size * 0.02,
                assetOffsetY: 0,
                assetRotation: 0,
                floatOffsetY: -size * 0.008
            )
        default:
            // .jumping and .waving rely on baked sprite frames; no extra motion overlay.
            return .zero
        }
    }
}

private struct PetMotionProfile {
    var bodyRotation: Double
    var bodyScale: CGFloat
    var faceOffsetX: CGFloat
    var faceOffsetY: CGFloat
    var assetOffsetX: CGFloat
    var assetOffsetY: CGFloat
    var assetRotation: Double
    var floatOffsetY: CGFloat

    static let zero = PetMotionProfile(
        bodyRotation: 0,
        bodyScale: 1,
        faceOffsetX: 0,
        faceOffsetY: 0,
        assetOffsetX: 0,
        assetOffsetY: 0,
        assetRotation: 0,
        floatOffsetY: 0
    )
}

private struct ArcSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: .degrees(20),
            endAngle: .degrees(160),
            clockwise: false
        )
        return path
    }
}

private extension Color {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard trimmed.count == 6,
              let value = Int(trimmed, radix: 16) else {
            return nil
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
