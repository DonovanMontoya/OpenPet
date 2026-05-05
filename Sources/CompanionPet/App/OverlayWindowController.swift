import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let appModel: AppModel
    private let petHostingView: PetHostingView<OverlayPetView>
    private let bubbleHostingView: BubbleHostingView<OverlayBubbleView>
    private let petWindow: NSWindow
    private let bubbleWindow: NSWindow
    private var hasRestoredInitialPosition = false
    private var hasAttachedBubbleWindow = false

    init(appModel: AppModel) {
        self.appModel = appModel
        self.petHostingView = PetHostingView(
            rootView: OverlayPetView(appModel: appModel),
            appModel: appModel
        )
        self.bubbleHostingView = BubbleHostingView(rootView: OverlayBubbleView(appModel: appModel), appModel: appModel)

        self.petWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: appModel.petCanvasSize()),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.bubbleWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: appModel.bubbleCanvasSize()),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configurePetWindow()
        configureBubbleWindow()
    }

    func install() {
        petWindow.contentView = petHostingView
        bubbleWindow.contentView = bubbleHostingView
        attachBubbleWindowIfNeeded()
        restorePosition()
        syncBubbleWindow()
        hasRestoredInitialPosition = true
        petWindow.orderFrontRegardless()
    }

    func apply(settings: CompanionSettings, selectedPetChanged: Bool) {
        resizePetWindow(to: appModel.petCanvasSize())
        bubbleWindow.setContentSize(appModel.bubbleCanvasSize())
        restorePosition(selectedPetChanged: selectedPetChanged)
        syncBubbleWindow()
    }

    var currentOrigin: CGPoint {
        petWindow.frame.origin
    }

    func setOrigin(_ origin: CGPoint, snap: Bool) {
        guard let screen = screenForPetWindow() ?? NSScreen.main else {
            return
        }
        let visibleFrame = screen.visibleFrame
        let size = petWindow.frame.size
        let targetOrigin = snap
            ? OverlayGeometry.snappedOrigin(for: origin, size: size, visibleFrame: visibleFrame)
            : OverlayGeometry.clampedOrigin(for: origin, size: size, visibleFrame: visibleFrame)
        petWindow.setFrameOrigin(targetOrigin)
        syncBubbleWindow()
    }

    func snapToVisibleFrame() -> OverlayPlacement? {
        guard let screen = screenForPetWindow() ?? NSScreen.main else {
            return nil
        }
        let origin = OverlayGeometry.snappedOrigin(
            for: petWindow.frame.origin,
            size: petWindow.frame.size,
            visibleFrame: screen.visibleFrame
        )
        petWindow.setFrameOrigin(origin)
        syncBubbleWindow()
        return OverlayGeometry.placement(for: origin, screen: screen)
    }

    private func configurePetWindow() {
        configureSharedWindowChrome(petWindow)
        petWindow.isMovable = false
        petWindow.acceptsMouseMovedEvents = true
    }

    private func configureBubbleWindow() {
        configureSharedWindowChrome(bubbleWindow)
        bubbleWindow.ignoresMouseEvents = false
    }

    private func configureSharedWindowChrome(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }

    private func restorePosition(selectedPetChanged: Bool = false) {
        guard let mainScreen = NSScreen.main else {
            return
        }

        let size = petWindow.frame.size
        if let placement = appModel.settings.overlayPlacement,
           let screen = OverlayGeometry.screen(for: placement.screenID, screens: NSScreen.screens) {
            let restoredOrigin = CGPoint(x: placement.originX, y: placement.originY)
            let origin = OverlayGeometry.clampedOrigin(for: restoredOrigin, size: size, visibleFrame: screen.visibleFrame)
            petWindow.setFrameOrigin(origin)
            return
        }

        if selectedPetChanged || (!hasRestoredInitialPosition && appModel.settings.overlayPlacement == nil) {
            petWindow.setFrameOrigin(OverlayGeometry.defaultOrigin(for: size, on: mainScreen))
        }
    }

    private func resizePetWindow(to size: CGSize) {
        guard petWindow.frame.size != size else {
            return
        }

        let oldFrame = petWindow.frame
        let newOrigin = CGPoint(
            x: oldFrame.maxX - size.width,
            y: oldFrame.minY
        )
        petWindow.setFrame(CGRect(origin: newOrigin, size: size), display: true)
    }

    private func syncBubbleWindow() {
        attachBubbleWindowIfNeeded()

        guard appModel.showsOverlayBubble() else {
            bubbleWindow.orderOut(nil)
            return
        }

        let bubbleSize = appModel.bubbleCanvasSize()
        bubbleWindow.setContentSize(bubbleSize)
        let visibleFrame = screenForPetWindow()?.visibleFrame ?? NSScreen.main?.visibleFrame
        let origin = OverlayGeometry.bubbleOrigin(
            forPetFrame: petWindow.frame,
            bubbleSize: bubbleSize,
            visibleFrame: visibleFrame
        )
        bubbleWindow.setFrameOrigin(origin)
        bubbleWindow.orderFront(nil)
    }

    private func attachBubbleWindowIfNeeded() {
        guard !hasAttachedBubbleWindow else {
            return
        }
        petWindow.addChildWindow(bubbleWindow, ordered: .above)
        hasAttachedBubbleWindow = true
    }

    private func screenForPetWindow() -> NSScreen? {
        let center = CGPoint(x: petWindow.frame.midX, y: petWindow.frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
    }
}

private let petHoverDwellSeconds: TimeInterval = 1.1

private final class BubbleHostingView<Content: View>: NSHostingView<Content> {
    private let appModel: AppModel

    init(rootView: Content, appModel: AppModel) {
        self.appModel = appModel
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class PetHostingView<Content: View>: NSHostingView<Content> {
    private let appModel: AppModel
    private var dragStartOrigin: CGPoint = .zero
    private var dragStartLocation: CGPoint = .zero
    private var isDraggingOverlay = false
    private var didTriggerJumpThisGesture = false
    private var trackingAreaRef: NSTrackingArea?
    private var hoverDwellWorkItem: DispatchWorkItem?

    init(rootView: Content, appModel: AppModel) {
        self.appModel = appModel
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef

        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        appModel.setOverlayHovered(true)
        scheduleHoverDwell()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        appModel.setOverlayHovered(false)
        cancelHoverDwell()
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        appModel.setOverlayHovered(true)
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        cancelHoverDwell()
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        dragStartOrigin = window.frame.origin
        dragStartLocation = window.convertPoint(toScreen: event.locationInWindow)
        isDraggingOverlay = false
        didTriggerJumpThisGesture = false

        if event.clickCount >= 2 {
            didTriggerJumpThisGesture = true
            appModel.handleOverlayDoubleTap()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else {
            super.mouseDragged(with: event)
            return
        }

        guard !appModel.settings.isLocked else {
            return
        }

        let currentLocation = window.convertPoint(toScreen: event.locationInWindow)
        let deltaX = currentLocation.x - dragStartLocation.x
        let deltaY = currentLocation.y - dragStartLocation.y

        if !isDraggingOverlay {
            isDraggingOverlay = true
            appModel.beginDrag()
        }

        appModel.updateOverlayPosition(
            to: CGPoint(
                x: dragStartOrigin.x + deltaX,
                y: dragStartOrigin.y + deltaY
            ),
            horizontalMotion: event.deltaX
        )
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingOverlay {
            appModel.finishOverlayDrag()
        } else if !didTriggerJumpThisGesture {
            appModel.handleOverlayTap()
        }

        isDraggingOverlay = false
        didTriggerJumpThisGesture = false
        let stillHovered = bounds.contains(convert(event.locationInWindow, from: nil))
        appModel.setOverlayHovered(stillHovered)
        if stillHovered {
            scheduleHoverDwell()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func scheduleHoverDwell() {
        cancelHoverDwell()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.hoverDwellWorkItem = nil
            guard self.appModel.isOverlayHovered else {
                return
            }
            self.appModel.handleHoverDwell()
        }
        hoverDwellWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + petHoverDwellSeconds, execute: workItem)
    }

    private func cancelHoverDwell() {
        hoverDwellWorkItem?.cancel()
        hoverDwellWorkItem = nil
    }
}
