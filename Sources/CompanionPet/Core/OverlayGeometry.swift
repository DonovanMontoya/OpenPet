import AppKit
import CoreGraphics

enum OverlayGeometry {
    static let edgeSnapThreshold: CGFloat = 20

    static func screenIdentifier(_ screen: NSScreen) -> String {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return screenNumber.stringValue
        }
        return screen.localizedName
    }

    static func screen(for identifier: String, screens: [NSScreen]) -> NSScreen? {
        screens.first(where: { screenIdentifier($0) == identifier })
    }

    static func defaultOrigin(for size: CGSize, on screen: NSScreen) -> CGPoint {
        let visibleFrame = screen.visibleFrame
        return CGPoint(
            x: visibleFrame.maxX - size.width - 24,
            y: visibleFrame.minY + 24
        )
    }

    static func clampedOrigin(for proposedOrigin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }

    static func snappedOrigin(for proposedOrigin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        var origin = clampedOrigin(for: proposedOrigin, size: size, visibleFrame: visibleFrame)

        if abs(origin.x - visibleFrame.minX) <= edgeSnapThreshold {
            origin.x = visibleFrame.minX
        } else if abs((origin.x + size.width) - visibleFrame.maxX) <= edgeSnapThreshold {
            origin.x = visibleFrame.maxX - size.width
        }

        if abs(origin.y - visibleFrame.minY) <= edgeSnapThreshold {
            origin.y = visibleFrame.minY
        } else if abs((origin.y + size.height) - visibleFrame.maxY) <= edgeSnapThreshold {
            origin.y = visibleFrame.maxY - size.height
        }

        return origin
    }

    static func placement(for origin: CGPoint, screen: NSScreen) -> OverlayPlacement {
        OverlayPlacement(
            screenID: screenIdentifier(screen),
            originX: origin.x,
            originY: origin.y
        )
    }

    static func bubbleOrigin(
        forPetFrame petFrame: CGRect,
        bubbleSize: CGSize,
        visibleFrame: CGRect? = nil
    ) -> CGPoint {
        let tailInset = min(14, petFrame.width * 0.1)
        let petOverlap: CGFloat = 28
        let x = petFrame.maxX - bubbleSize.width + tailInset
        let y = petFrame.maxY - petOverlap
        let origin = CGPoint(x: x, y: y)

        guard let visibleFrame else {
            return origin
        }

        return clampedOrigin(for: origin, size: bubbleSize, visibleFrame: visibleFrame)
    }
}
