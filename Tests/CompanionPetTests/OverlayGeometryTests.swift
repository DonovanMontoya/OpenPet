import AppKit
import CoreGraphics
import Testing
@testable import CompanionPet

struct OverlayGeometryTests {
    @Test
    func placesBubbleRelativeToPetWindow() {
        let petFrame = CGRect(x: 500, y: 100, width: 168, height: 168)
        let bubbleOrigin = OverlayGeometry.bubbleOrigin(
            forPetFrame: petFrame,
            bubbleSize: CGSize(width: 282, height: 110)
        )

        #expect(bubbleOrigin.x < petFrame.maxX)
        #expect(bubbleOrigin.x < petFrame.minX)
        #expect(bubbleOrigin.x + 282 > petFrame.maxX)
        #expect(bubbleOrigin.y == petFrame.maxY - 28)
    }

    @Test
    func clampsBubbleToVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let petFrame = CGRect(x: 0, y: 340, width: 100, height: 100)
        let bubbleSize = CGSize(width: 282, height: 110)
        let bubbleOrigin = OverlayGeometry.bubbleOrigin(
            forPetFrame: petFrame,
            bubbleSize: bubbleSize,
            visibleFrame: visibleFrame
        )

        #expect(bubbleOrigin.x == visibleFrame.minX)
        #expect(bubbleOrigin.y == visibleFrame.maxY - bubbleSize.height)
    }

    @Test
    func usesCompactCanvasWhenBubbleIsHidden() {
        let preset = OverlayScalePreset.medium

        #expect(preset.petCanvasSize.width < preset.bubbleCanvasSize.width)
        #expect(preset.petCanvasSize.height != preset.bubbleCanvasSize.height)
        #expect(preset.canvasSize(showingBubble: false) == preset.petCanvasSize)
        #expect(preset.canvasSize(showingBubble: true) == preset.bubbleCanvasSize)
    }

    @Test
    func snapsToEdgesWithinThreshold() {
        let visibleFrame = CGRect(x: 100, y: 100, width: 500, height: 400)
        let snapped = OverlayGeometry.snappedOrigin(
            for: CGPoint(x: 110, y: 475),
            size: CGSize(width: 120, height: 120),
            visibleFrame: visibleFrame
        )

        #expect(snapped.x == visibleFrame.minX)
        #expect(snapped.y == visibleFrame.maxY - 120)
    }

    @Test
    func clampsWhenOriginWouldOverflow() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let clamped = OverlayGeometry.clampedOrigin(
            for: CGPoint(x: 280, y: -25),
            size: CGSize(width: 80, height: 80),
            visibleFrame: visibleFrame
        )

        #expect(clamped.x == 220)
        #expect(clamped.y == 0)
    }
}
