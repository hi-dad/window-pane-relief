import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Keeps another app's window visible on top of everything.
///
/// macOS doesn't let one app keep another app's real window on top, so this lays a live,
/// same-size copy exactly over the real window whenever the real one isn't in front. Clicking
/// the copy hides it, brings the real window forward and passes the click on, so you work in
/// the real window. When you click back into another window, the copy covers it again.
final class PinnedWindow: NSObject, SCStreamOutput, SCStreamDelegate {
    let target: AppWindow
    var onClose: ((PinnedWindow) -> Void)?

    private let scWindow: SCWindow
    private let panel: NSPanel
    private let preview = PreviewView(frame: .zero)
    private let frameQueue = DispatchQueue(label: "window-pin.frames")
    private var stream: SCStream?
    private var watchTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var capturedSize: CGSize
    private var hasFrame = false
    /// After handing off to the real window, give it a moment to come forward before the
    /// copy is allowed to cover it again.
    private var hiddenUntil = Date.distantPast
    private var isClosed = false

    init(target: AppWindow, scWindow: SCWindow) {
        self.target = target
        self.scWindow = scWindow
        capturedSize = target.bounds.size

        panel = NSPanel(
            contentRect: Self.cocoaFrame(for: target.bounds),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.isFloatingPanel = true
        // This app is never the active one, so the panel must not hide when it isn't.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = preview

        preview.onClick = { [weak self] in self?.handOffClick() }
        preview.menu = makeContextMenu()
    }

    func start() {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: capturedSize), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            debugLog("couldn't add stream output: \(error)")
            close()
            return
        }
        self.stream = stream
        stream.startCapture { [weak self] error in
            DispatchQueue.main.async {
                // Unpinned while capture was still starting: stop it now, or it runs on with
                // nothing left to stop it and the screen-sharing indicator stays on.
                if self?.isClosed ?? true {
                    Self.stop(stream, output: self)
                    return
                }
                guard let error else { return }
                debugLog("couldn't start capture of \(self?.target.menuTitle ?? "?"): \(error)")
                self?.close()
            }
        }

        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.update()
        }
        // React to app switches straight away rather than on the next tick.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.update()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        watchTimer?.invalidate()
        watchTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let stream { Self.stop(stream, output: self) }
        stream = nil
        panel.close()
        onClose?(self)
    }

    /// Stops a capture for good. The closure holds on to the stream until macOS confirms it
    /// stopped; letting it go sooner can leave the capture (and the indicator) running.
    private static func stop(_ stream: SCStream, output: SCStreamOutput?) {
        if let output { try? stream.removeStreamOutput(output, type: .screen) }
        stream.stopCapture { error in
            if let error { debugLog("stop capture: \(error)") }
            _ = stream
        }
    }

    // MARK: Showing and hiding the copy

    /// Covers the real window with the copy whenever the real window isn't the front one.
    private func update() {
        guard !isClosed else { return }
        guard let current = WindowCatalog.window(id: target.id) else {
            debugLog("\(target.menuTitle) closed")
            close()
            return
        }
        followSize(current.bounds.size)

        let isFront = WindowCatalog.frontWindow()?.id == target.id
        let shouldShow = hasFrame && current.isOnScreen && !isFront && Date() >= hiddenUntil
        if shouldShow {
            let frame = Self.cocoaFrame(for: current.bounds)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Hides the copy, brings the real window forward, and repeats the click on it.
    private func handOffClick() {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: location.x, y: primaryHeight - location.y)

        hiddenUntil = Date().addingTimeInterval(0.6)
        panel.orderOut(nil)
        WindowFocus.bringToFront(target)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.isClosed, Permissions.hasAccessibility,
                  let front = WindowCatalog.frontWindow(), front.id == self.target.id,
                  front.bounds.contains(point)
            else { return }
            Self.postClick(at: point)
        }
    }

    private static func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    // MARK: Capture

    private static func configuration(for size: CGSize) -> SCStreamConfiguration {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preview.show(surface)
            if !self.hasFrame {
                self.hasFrame = true
                self.update()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        debugLog("capture of \(target.menuTitle) stopped: \(error)")
        DispatchQueue.main.async { [weak self] in self?.close() }
    }

    private func followSize(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1,
              abs(size.width - capturedSize.width) > 1 || abs(size.height - capturedSize.height) > 1
        else { return }
        capturedSize = size
        stream?.updateConfiguration(Self.configuration(for: size)) { error in
            if let error { debugLog("couldn't follow resize: \(error)") }
        }
    }

    /// Converts a top-left-origin global rect to AppKit's bottom-left-origin coordinates.
    private static func cocoaFrame(for rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 85, 70, 50, 30] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = percent == 100 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        let unpinItem = NSMenuItem(title: "Unpin", action: #selector(unpin), keyEquivalent: "")
        unpinItem.target = self
        menu.addItem(unpinItem)
        return menu
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        panel.alphaValue = CGFloat(sender.tag) / 100
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func unpin() {
        close()
    }
}

/// Shows the latest captured frame, filling the view.
private final class PreviewView: NSView {
    var onClick: (() -> Void)?
    private let contentLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentLayer.contentsGravity = .resize
        layer = contentLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = surface
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        onClick?()
    }
}
