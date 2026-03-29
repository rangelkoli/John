import AppKit
import SwiftUI

class NotchWindow: NSPanel {
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: Any?
    private var statusObserver: Any?
    
    var onHover: (() -> Void)?
    var isPanelVisible: (() -> Bool)?
    var harness: AgentHarness?
    
    private var notchWidth: CGFloat = 180
    private var notchHeight: CGFloat = 37
    
    private var isExpanded = false
    private var collapseDebounceTimer: Timer?
    private var isHovered = false
    
    private let pillView = NotchPillView()
    private var pillContentHost: NSHostingView<NotchPillContent>?
    
    // Smooth animation state
    private var animationDisplayLink: CVDisplayLink?
    private var animationStartTime: Double = 0
    private var animationDuration: Double = 0
    private var startFrame: NSRect = .zero
    private var targetFrame: NSRect = .zero
    private var completion: (() -> Void)?
    private var isAnimating = false
    
    init(onHover: @escaping () -> Void, harness: AgentHarness? = nil) {
        self.onHover = onHover
        self.harness = harness
        
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        alphaValue = 1
        
        setupPillView()
        detectNotchSize()
        positionAtNotch()
        orderFrontRegardless()
        setupTracking()
        observeScreenChanges()
        observeStatusChanges()
    }
    
    private func setupPillView() {
        guard let cv = contentView else { return }
        
        pillView.frame = cv.bounds
        pillView.autoresizingMask = [.width, .height]
        pillView.alphaValue = 1
        cv.addSubview(pillView)
        cv.wantsLayer = true
        cv.layer?.masksToBounds = false
        
        let hostView = NSHostingView(rootView: NotchPillContent(harness: harness))
        hostView.frame = cv.bounds
        hostView.autoresizingMask = [.width, .height]
        hostView.alphaValue = 1
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = CGColor.clear
        cv.addSubview(hostView)
        pillContentHost = hostView
    }
    
    deinit {
        stopAnimation()
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = statusObserver { NotificationCenter.default.removeObserver(observer) }
    }
    
    // MARK: - Smooth Animation System
    
    private func animateTo(_ target: NSRect, duration: Double, completion: (() -> Void)? = nil) {
        self.startFrame = frame
        self.targetFrame = target
        self.animationDuration = duration
        self.animationStartTime = CACurrentMediaTime()
        self.completion = completion
        self.isAnimating = true
        
        ensureDisplayLink()
    }
    
    private func ensureDisplayLink() {
        guard animationDisplayLink == nil else { return }
        
        CVDisplayLinkCreateWithActiveCGDisplays(&animationDisplayLink)
        guard let displayLink = animationDisplayLink else { return }
        
        let opaqueSelf = Unmanaged.passRetained(self)
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let window = Unmanaged<NotchWindow>.fromOpaque(userInfo).takeUnretainedValue()
            window.tick()
            return kCVReturnSuccess
        }, opaqueSelf.toOpaque())
        
        CVDisplayLinkStart(displayLink)
    }
    
    private func tick() {
        guard isAnimating else {
            stopAnimation()
            return
        }
        
        let elapsed = CACurrentMediaTime() - animationStartTime
        let progress = min(elapsed / animationDuration, 1.0)
        
        // Ultra smooth ease-out curve (no bounce)
        let t = smoothStep(progress)
        
        let interpolated = NSRect(
            x: startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * t,
            y: startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * t,
            width: startFrame.width + (targetFrame.width - startFrame.width) * t,
            height: startFrame.height + (targetFrame.height - startFrame.height) * t
        )
        
        DispatchQueue.main.async { [weak self] in
            self?.setFrame(interpolated, display: true)
        }
        
        if progress >= 1.0 {
            DispatchQueue.main.async { [weak self] in
                self?.isAnimating = false
                self?.stopAnimation()
                self?.completion?()
                self?.completion = nil
            }
        }
    }
    
    private func stopAnimation() {
        isAnimating = false
        guard let displayLink = animationDisplayLink else { return }
        CVDisplayLinkStop(displayLink)
        animationDisplayLink = nil
    }
    
    // Smooth ease-out function (cubic bezier approximation)
    private func smoothStep(_ t: Double) -> Double {
        // Smooth step: 3t² - 2t³ (very smooth, no overshoot)
        return t * t * (3.0 - 2.0 * t)
    }
    
    // MARK: - Expand / Collapse
    
    private func observeStatusChanges() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .JohnStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateExpansionState()
        }
        
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateExpansionState()
        }
    }
    
    private func updateExpansionState() {
        let shouldExpand: Bool
        if let harness = Self.currentHarness {
            switch harness.status {
            case .thinking:
                shouldExpand = true
            case .idle, .waitingForInput, .error, .taskCompleted:
                shouldExpand = false
            }
        } else {
            shouldExpand = false
        }
        
        if shouldExpand && !isExpanded {
            collapseDebounceTimer?.invalidate()
            collapseDebounceTimer = nil
            expandSmooth()
        } else if !shouldExpand && isExpanded {
            guard collapseDebounceTimer == nil else { return }
            collapseDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.collapseDebounceTimer = nil
                if !Self.shouldExpand {
                    self.collapseSmooth()
                }
            }
        } else if shouldExpand && isExpanded {
            collapseDebounceTimer?.invalidate()
            collapseDebounceTimer = nil
        }
    }
    
    private static var shouldExpand: Bool {
        guard let harness = currentHarness else { return false }
        switch harness.status {
        case .thinking:
            return true
        case .idle, .waitingForInput, .error, .taskCompleted:
            return false
        }
    }
    
    static var currentHarness: AgentHarness? {
        (NSApplication.shared.delegate as? AppDelegate)?.harness
    }
    
    private func expandSmooth() {
        isExpanded = true
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        
        let targetWidth: CGFloat = notchWidth + 80
        var target = NSRect(
            x: screenFrame.midX - targetWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: targetWidth,
            height: notchHeight
        )
        
        if isHovered {
            target = applyHoverGrow(to: target)
        }
        
        pillView.alphaValue = 1
        pillContentHost?.alphaValue = 1
        
        animateTo(target, duration: 0.5)
    }
    
    private func collapseSmooth() {
        isExpanded = false
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.pillContentHost?.animator().alphaValue = 0
        }
        
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        
        var target = NSRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        
        if isHovered {
            target = applyHoverGrow(to: target)
        }
        
        animateTo(target, duration: 0.4) { [weak self] in
            self?.pillContentHost?.alphaValue = 1
        }
    }
    
    // MARK: - Notch size detection
    
    private func detectNotchSize() {
        guard let screen = NSScreen.builtIn else { return }
        
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
            notchHeight = screen.frame.maxY - min(left.minY, right.minY)
        } else {
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            notchWidth = 180
            notchHeight = max(menuBarHeight, 25)
        }
    }
    
    // MARK: - Positioning
    
    private func positionAtNotch() {
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let x = screenFrame.midX - notchWidth / 2
        let y = screenFrame.maxY - notchHeight
        setFrame(NSRect(x: x, y: y, width: notchWidth, height: notchHeight), display: true)
    }
    
    // MARK: - Mouse tracking
    
    private func setupTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.checkMouse()
        }
        
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkMouse()
            return event
        }
    }
    
    private func checkMouse() {
        let mouseLocation = NSEvent.mouseLocation
        
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let effectiveWidth = isExpanded ? notchWidth + 80 : notchWidth
        let notchRect = NSRect(
            x: screenFrame.midX - effectiveWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: effectiveWidth,
            height: notchHeight + 1
        )
        
        let mouseInNotch = notchRect.contains(mouseLocation)
        
        if mouseInNotch {
            if !isHovered {
                isHovered = true
                hoverGrowSmooth()
            }
            onHover?()
            return
        }
        
        if isHovered {
            let panelShowing = isPanelVisible?() ?? false
            if !panelShowing {
                isHovered = false
                hoverShrinkSmooth()
            }
        }
    }
    
    func endHover() {
        guard isHovered else { return }
        isHovered = false
        hoverShrinkSmooth()
    }
    
    // MARK: - Hover grow / shrink
    
    private static let hoverGrowX: CGFloat = NotchPillView.earRadius * 2
    private static let hoverGrowY: CGFloat = 2
    
    private func applyHoverGrow(to rect: NSRect) -> NSRect {
        NSRect(
            x: rect.origin.x - Self.hoverGrowX / 2,
            y: rect.origin.y - Self.hoverGrowY,
            width: rect.width + Self.hoverGrowX,
            height: rect.height + Self.hoverGrowY
        )
    }
    
    private func hoverGrowSmooth() {
        pillView.isHovered = true
        pillContentHost?.rootView = NotchPillContent(isHovering: true, harness: harness)
        
        let target = applyHoverGrow(to: frame)
        animateTo(target, duration: 0.35)
    }
    
    private func hoverShrinkSmooth() {
        pillView.isHovered = false
        pillContentHost?.rootView = NotchPillContent(isHovering: false, harness: harness)
        
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let baseWidth = isExpanded ? notchWidth + 80 : notchWidth
        let target = NSRect(
            x: screenFrame.midX - baseWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: baseWidth,
            height: notchHeight
        )
        
        animateTo(target, duration: 0.35)
    }
    
    // MARK: - Observers
    
    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.detectNotchSize()
            self?.positionAtNotch()
        }
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - NSScreen helper

extension NSScreen {
    static var builtIn: NSScreen? {
        screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(id) != 0
        } ?? main
    }
}

// MARK: - Notch pill background view with smooth shape animation

class NotchPillView: NSView {
    var isHovered: Bool = false {
        didSet {
            guard isHovered != oldValue else { return }
            animateShape()
        }
    }
    
    private let shapeLayer = CAShapeLayer()
    static let earRadius: CGFloat = 10
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = CGColor.clear
        shapeLayer.fillColor = NSColor.black.cgColor
        shapeLayer.actions = ["path": NSNull()]
        layer?.addSublayer(shapeLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        updateShape(animated: false)
    }
    
    private func animateShape() {
        let fromPath = shapeLayer.path
        let toPath = createPath(for: bounds, isHovered: isHovered)
        
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = fromPath
        animation.toValue = toPath
        animation.duration = 0.35
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.add(animation, forKey: "pathMorph")
        shapeLayer.path = toPath
        CATransaction.commit()
    }
    
    private func updateShape(animated: Bool) {
        let path = createPath(for: bounds, isHovered: isHovered)
        
        if animated {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = shapeLayer.path
            animation.toValue = path
            animation.duration = 0.35
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shapeLayer.add(animation, forKey: "pathMorph")
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        shapeLayer.path = path
        CATransaction.commit()
    }
    
    private func createPath(for bounds: NSRect, isHovered: Bool) -> CGPath {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return CGMutablePath() }
        
        let ear = Self.earRadius
        let path = CGMutablePath()
        
        if isHovered {
            let bodyLeft = ear
            let bodyRight = w - ear
            
            path.move(to: CGPoint(x: 0, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: bodyLeft, y: ear),
                control: CGPoint(x: bodyLeft, y: 0)
            )
            path.addLine(to: CGPoint(x: bodyLeft, y: h))
            path.addLine(to: CGPoint(x: bodyRight, y: h))
            path.addLine(to: CGPoint(x: bodyRight, y: ear))
            path.addQuadCurve(
                to: CGPoint(x: w, y: 0),
                control: CGPoint(x: bodyRight, y: 0)
            )
        } else {
            let cr: CGFloat = 9.5
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w, y: cr))
            path.addQuadCurve(
                to: CGPoint(x: w - cr, y: 0),
                control: CGPoint(x: w, y: 0)
            )
            path.addLine(to: CGPoint(x: cr, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: cr),
                control: CGPoint(x: 0, y: 0)
            )
            path.closeSubpath()
        }
        
        return path
    }
}