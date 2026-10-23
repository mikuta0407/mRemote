import UIKit
import SessionCore

/// What a trackpad drives: the surface, which owns the remote pointer.
@MainActor
protocol RemotePointerControl: AnyObject {
    func moveRemotePointer(dx: Double, dy: Double, speed: Double)
    func clickRemote(_ button: PointerButton)
    func setLaptopButton(_ button: PointerButton, pressed: Bool)
    func scrollRemote(dx: Double, dy: Double)
    /// What the host takes beyond the above; asked at each gesture's start.
    var macGestures: TrackpadMacGestures { get }
    /// A scroll as pixel deltas with its phase, for `preciseScroll`.
    func scrollRemote(dx: Double, dy: Double, phase: MacGesturePhase)
    func sendMacGesture(_ input: MacGestureInput)
    func sendSwipeShortcut(_ direction: SwipeDirection)
}

extension RemotePointerControl {
    var macGestures: TrackpadMacGestures { .none }
    func scrollRemote(dx: Double, dy: Double, phase: MacGesturePhase) { scrollRemote(dx: dx, dy: dy) }
    func sendMacGesture(_ input: MacGestureInput) {}
    func sendSwipeShortcut(_ direction: SwipeDirection) {}
}

/// Turns touches on any area used as a trackpad into remote pointer input:
/// the laptop deck's pad, or the desktop itself when the deck shows only
/// the keyboard.
///
/// - one finger moves the pointer, by travel rather than position;
/// - a tap is a left click, a two-finger tap a right click;
/// - two fingers moving scroll;
/// - a tap and then a finger put down again and moved drags with the left
///   button, as in the Windows App; two taps are a double click;
/// - a finger held still and then moved also drags.
///
/// A Mac host may also take (`TrackpadMacGestures`):
/// - two fingers pinching or turning: the Mac's magnify and rotate;
/// - two two-finger taps: smart zoom (the right click waits for the second);
/// - three or four fingers swiping: Spaces, Mission Control and App Exposé,
///   as their shortcuts or as the Dock's own swipe following the fingers;
/// - two fingers scrolling as pixel deltas with phases.
///
/// A tap's click waits `doubleTapInterval` for a second touch, so that a
/// drag starting from it is a press alone: sent at once, the click would
/// make the drag's press a double click, which opens what it was to drag.
///
/// The owner forwards its touches; this keeps no reference to them beyond
/// their identity and last position.
@MainActor
final class TrackpadGestureTracker {
    /// One finger's position at a moment. UIKit's touches are reduced to
    /// this so the gesture logic can be exercised without UIKit's touches,
    /// which tests cannot create.
    struct Sample {
        let id: ObjectIdentifier
        let location: CGPoint
        let timestamp: TimeInterval
    }

    /// Arms the long-press that starts a drag; returns a cancel. A Timer in
    /// the app, replaced by tests that fire it themselves.
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    private let target: () -> (any RemotePointerControl)?
    private let schedule: Scheduler
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private var touches: [ObjectIdentifier: CGPoint] = [:]
    private var maximumTouches = 0
    private var travel: CGFloat = 0
    private var startTime: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    private var isDragging = false
    private var cancelLongPress: (() -> Void)?
    /// A tap's left click, held back for a second touch.
    private var cancelPendingClick: (() -> Void)?
    /// This touch came down while a tap's click was held back.
    private var isSecondTouch = false

    // Two fingers and more.
    private enum MultiFinger { case undecided, scroll, transform, swipe }
    private var multi = MultiFinger.undecided
    /// The host's gestures, as they were when this sequence began.
    private var gestures = TrackpadMacGestures.none
    /// The first two fingers down, whose span and angle a pinch measures.
    private var pair: (ObjectIdentifier, ObjectIdentifier)?
    private var pairStart: (span: CGFloat, angle: CGFloat) = (0, 0)
    private var pairLast: (span: CGFloat, angle: CGFloat) = (0, 0)
    /// The fingers' shared travel since the second came down.
    private var multiTravel = CGPoint.zero
    private var scrollBegan = false
    private var transformBegan = false
    private var swipeAxisHorizontal: Bool?
    private var swipeProgress = 0.0
    private var swipeVelocity = 0.0
    private var swipeBegan = false
    private var swipeShortcutSent = false
    /// A gesture ran its course while a finger is still down: the rest of the
    /// sequence is not the pointer's.
    private var multiFinished = false
    /// A two-finger tap's right click, held back for a second one (smart zoom).
    private var cancelPendingRightClick: (() -> Void)?
    private var heldRightClick = false

    /// The pad's size, for a Dock swipe's progress: a swipe across most of
    /// it is a whole Space.
    var padSize = CGSize(width: 400, height: 300)

    private(set) var isEnabled = false

    static let tapTravel: CGFloat = 8
    static let tapDuration: TimeInterval = 0.3
    static let dragHold: TimeInterval = 0.45
    /// Long enough to catch the second touch of a tap-then-drag at an
    /// unhurried pace, as a Mac's tap to drag does.
    static let doubleTapInterval: TimeInterval = 0.35
    /// A two-finger tap waits this long for another before it is a right click.
    static let smartZoomInterval: TimeInterval = 0.3
    /// Travel that makes three fingers a swipe along one axis, and that
    /// makes it the swipe's shortcut.
    static let swipeDecision: CGFloat = 12
    static let swipeShortcutTravel: CGFloat = 50
    /// Progress per second onwards that carries a short Dock swipe through.
    static let swipeFlickSpeed = 1.0
    /// How far the span or the angle must change, before the fingers travel
    /// together, for two fingers to be a pinch rather than a scroll.
    static let pinchSpanChange: CGFloat = 0.08
    static let pinchAngleChange: CGFloat = 10 * .pi / 180

    init(
        target: @escaping () -> (any RemotePointerControl)?,
        schedule: @escaping Scheduler = TrackpadGestureTracker.runLoopTimer
    ) {
        self.target = target
        self.schedule = schedule
    }

    static func runLoopTimer(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    var isTracking: Bool { !touches.isEmpty }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { reset() }
    }

    /// Forgets the sequence, releasing a drag's button on the way: the
    /// button must not outlive the finger that held it. A click still held
    /// back is dropped with it.
    func reset() {
        cancelPendingClick?()
        cancelPendingClick = nil
        cancelPendingRightClick?()
        cancelPendingRightClick = nil
        heldRightClick = false
        isSecondTouch = false
        resetTouches()
    }

    private func resetTouches() {
        disarmLongPress()
        if isDragging {
            isDragging = false
            target()?.setLaptopButton(.left, pressed: false)
        }
        finishMultiFinger(cancelled: true)
        touches = [:]
        maximumTouches = 0
        travel = 0
        multi = .undecided
        multiFinished = false
        pair = nil
    }

    // MARK: - UIKit touches

    func began(_ touch: UITouch, in view: UIView) {
        padSize = view.bounds.size
        began(Self.sample(touch, in: view))
    }

    func moved(_ moved: [UITouch], in view: UIView) {
        self.moved(moved.map { Self.sample($0, in: view) })
    }

    func ended(_ touch: UITouch, cancelled: Bool) {
        ended(id: ObjectIdentifier(touch), at: touch.timestamp, cancelled: cancelled)
    }

    private static func sample(_ touch: UITouch, in view: UIView) -> Sample {
        Sample(id: ObjectIdentifier(touch), location: touch.location(in: view), timestamp: touch.timestamp)
    }

    // MARK: - Gesture

    func began(_ sample: Sample) {
        if touches.isEmpty {
            resetTouches()
            startTime = sample.timestamp
            lastTime = sample.timestamp
            // Down again while the tap's click waits: what this touch does
            // decides what the click becomes.
            isSecondTouch = cancelPendingClick != nil
            cancelPendingClick?()
            cancelPendingClick = nil
            // Down again while a two-finger tap waits: perhaps its second.
            if let cancel = cancelPendingRightClick {
                cancel()
                cancelPendingRightClick = nil
                heldRightClick = true
            }
            gestures = target()?.macGestures ?? .none
        }
        touches[sample.id] = sample.location
        maximumTouches = max(maximumTouches, touches.count)
        if touches.count == 2 {
            let ids = Array(touches.keys)
            pair = (ids[0], ids[1])
            pairStart = pairMetrics() ?? (0, 0)
            pairLast = pairStart
            multiTravel = .zero
        }
        if touches.count >= 3, gestures.swipes != .off, multi == .undecided || multi == .scroll {
            // A third finger: a swipe, whatever two were doing.
            finishMultiFinger(cancelled: false)
            multi = .swipe
            multiTravel = .zero
        }
        if touches.count == 1 {
            disarmLongPress()
            cancelLongPress = schedule(Self.dragHold) { [weak self] in self?.beginDrag() }
        } else {
            disarmLongPress()
            // Two fingers are a scroll or a right click, not a drag: the
            // first tap was a click after all.
            sendHeldClick()
        }
    }

    func moved(_ samples: [Sample]) {
        var sum = CGPoint.zero
        var count = 0
        var timestamp = lastTime
        for sample in samples {
            guard let previous = touches[sample.id] else { continue }
            sum.x += sample.location.x - previous.x
            sum.y += sample.location.y - previous.y
            touches[sample.id] = sample.location
            count += 1
            timestamp = max(timestamp, sample.timestamp)
        }
        guard count > 0 else { return }
        let delta = CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
        travel += hypot(delta.x, delta.y)
        let elapsed = max(timestamp - lastTime, 1.0 / 240)
        lastTime = timestamp
        if travel >= Self.tapTravel, !isDragging {
            disarmLongPress()
            if isSecondTouch, touches.count == 1, isEnabled {
                isSecondTouch = false
                isDragging = true
                target()?.setLaptopButton(.left, pressed: true)
            }
        }

        guard isEnabled, let target = target() else { return }
        if travel >= Self.tapTravel { flushHeldRightClick() }
        if multiFinished {
            return
        } else if touches.count >= 2, !isDragging {
            multiFinger(delta: delta, elapsed: elapsed, target: target)
        } else {
            let speed = Double(hypot(delta.x, delta.y)) / elapsed
            target.moveRemotePointer(dx: Double(delta.x), dy: Double(delta.y), speed: speed)
        }
    }

    func ended(id: ObjectIdentifier, at timestamp: TimeInterval, cancelled: Bool) {
        guard touches.removeValue(forKey: id) != nil else { return }
        // A gesture needs all its fingers: one lifted ends it.
        if multi != .undecided, multi != .scroll || touches.count < 2 {
            finishMultiFinger(cancelled: cancelled)
            if !touches.isEmpty { multiFinished = true }
        }
        guard touches.isEmpty else { return }
        let wasTap = !cancelled
            && !isDragging
            && multi != .transform && multi != .swipe
            && travel < Self.tapTravel
            && timestamp - startTime < Self.tapDuration
        let heldClick = isSecondTouch
        if heldRightClick {
            heldRightClick = false
            if wasTap, maximumTouches == 2, isEnabled {
                // The second two-finger tap.
                haptics.impactOccurred()
                target()?.sendMacGesture(MacGestureInput(kind: .smartZoom, phase: nil))
                resetTouches()
                return
            }
            if isEnabled { target()?.clickRemote(.right) }
        }
        if wasTap, isEnabled {
            haptics.impactOccurred()
            if maximumTouches >= 2, gestures.pinch, maximumTouches == 2 {
                // Perhaps the first of two: smart zoom.
                cancelPendingRightClick = schedule(Self.smartZoomInterval) { [weak self] in
                    guard let self else { return }
                    self.cancelPendingRightClick = nil
                    if self.isEnabled { self.target()?.clickRemote(.right) }
                }
            } else if maximumTouches >= 2 {
                target()?.clickRemote(.right)
            } else if heldClick {
                // The second tap: a double click, both clicks now.
                isSecondTouch = false
                target()?.clickRemote(.left)
                target()?.clickRemote(.left)
            } else {
                cancelPendingClick = schedule(Self.doubleTapInterval) { [weak self] in
                    guard let self else { return }
                    self.cancelPendingClick = nil
                    if self.isEnabled { self.target()?.clickRemote(.left) }
                }
            }
        }
        // A second touch that was neither a tap nor a drag (held, then let
        // go) still owes the first tap its click.
        sendHeldClick()
        resetTouches()
    }

    /// A two-finger tap's right click that was waiting: what came next was
    /// not a second tap.
    private func flushHeldRightClick() {
        guard heldRightClick else { return }
        heldRightClick = false
        if isEnabled { target()?.clickRemote(.right) }
    }

    // MARK: - Two fingers and more

    /// The span and angle of the pair, or nil once one of them is gone.
    private func pairMetrics() -> (span: CGFloat, angle: CGFloat)? {
        guard let pair, let a = touches[pair.0], let b = touches[pair.1] else { return nil }
        return (hypot(b.x - a.x, b.y - a.y), atan2(b.y - a.y, b.x - a.x))
    }

    private static func angleBetween(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    private func multiFinger(delta: CGPoint, elapsed: TimeInterval, target: any RemotePointerControl) {
        multiTravel.x += delta.x
        multiTravel.y += delta.y
        if multi == .undecided {
            if touches.count == 2, gestures.pinch, let now = pairMetrics(), pairStart.span > 1 {
                let spanChange = abs(now.span / pairStart.span - 1)
                let turn = abs(Self.angleBetween(now.angle, pairStart.angle))
                if spanChange > Self.pinchSpanChange || turn > Self.pinchAngleChange {
                    multi = .transform
                } else if hypot(multiTravel.x, multiTravel.y) >= Self.tapTravel / 2 {
                    multi = .scroll
                } else {
                    return
                }
            } else {
                multi = touches.count >= 3 && gestures.swipes != .off ? .swipe : .scroll
            }
        }
        switch multi {
        case .undecided:
            break
        case .scroll:
            if gestures.preciseScroll {
                target.scrollRemote(dx: Double(delta.x), dy: Double(delta.y), phase: scrollBegan ? .changed : .began)
                scrollBegan = true
            } else {
                // The deltas are the fingers' own, which is what
                // `ScrollWheelAccumulator` expects.
                target.scrollRemote(dx: Double(delta.x), dy: Double(delta.y))
            }
        case .transform:
            guard let now = pairMetrics(), pairLast.span > 1 else { return }
            let phase: MacGesturePhase = transformBegan ? .changed : .began
            transformBegan = true
            target.sendMacGesture(MacGestureInput(
                kind: .magnify, phase: phase, value: Double(now.span / pairLast.span - 1)
            ))
            // Screen angles grow clockwise; the Mac's rotation is
            // counter-clockwise positive.
            target.sendMacGesture(MacGestureInput(
                kind: .rotate, phase: phase,
                value: -Double(Self.angleBetween(now.angle, pairLast.angle)) * 180 / .pi
            ))
            pairLast = now
        case .swipe:
            swipe(elapsed: elapsed, target: target)
        }
    }

    private func swipe(elapsed: TimeInterval, target: any RemotePointerControl) {
        if swipeAxisHorizontal == nil {
            guard hypot(multiTravel.x, multiTravel.y) >= Self.swipeDecision else { return }
            swipeAxisHorizontal = abs(multiTravel.x) >= abs(multiTravel.y)
        }
        guard let horizontal = swipeAxisHorizontal else { return }
        let along = horizontal ? multiTravel.x : multiTravel.y
        switch gestures.swipes {
        case .off:
            break
        case .shortcuts:
            guard !swipeShortcutSent, abs(along) >= Self.swipeShortcutTravel else { return }
            swipeShortcutSent = true
            haptics.impactOccurred()
            let direction: SwipeDirection = horizontal
                ? (along < 0 ? .left : .right)
                : (along < 0 ? .up : .down)
            target.sendSwipeShortcut(direction)
        case .followFingers:
            // Most of the pad's width (height) is a whole Space (the whole
            // way into Mission Control); positive as the fingers go left (up).
            let extent = max((horizontal ? padSize.width : padSize.height) * 0.7, 1)
            let progress = -Double(along / extent)
            let instant = (progress - swipeProgress) / max(elapsed, 1.0 / 240)
            swipeVelocity = swipeBegan ? swipeVelocity * 0.6 + instant * 0.4 : instant
            swipeProgress = progress
            target.sendMacGesture(MacGestureInput(
                kind: horizontal ? .dockHorizontal : .dockVertical,
                phase: swipeBegan ? .changed : .began,
                value: progress
            ))
            swipeBegan = true
        }
    }

    /// Whether a Dock swipe let go here goes on to the next Space (into
    /// Mission Control) rather than back: past halfway, or flicked onwards.
    /// The Dock completes every swipe that ends, whatever its speed, so the
    /// choice is made here and a swipe going back is sent as cancelled.
    static func swipeCompletes(progress: Double, velocity: Double) -> Bool {
        guard progress != 0 else { return false }
        let onwards = progress > 0 ? velocity : -velocity
        return abs(progress) >= 0.5 || (onwards >= Self.swipeFlickSpeed && abs(progress) >= 0.05)
    }

    /// Ends whatever the fingers were doing on the host.
    private func finishMultiFinger(cancelled: Bool) {
        guard let target = target() else { return }
        if scrollBegan {
            scrollBegan = false
            target.scrollRemote(dx: 0, dy: 0, phase: cancelled ? .cancelled : .ended)
        }
        if transformBegan {
            transformBegan = false
            let phase: MacGesturePhase = cancelled ? .cancelled : .ended
            target.sendMacGesture(MacGestureInput(kind: .magnify, phase: phase))
            target.sendMacGesture(MacGestureInput(kind: .rotate, phase: phase))
        }
        if swipeBegan {
            swipeBegan = false
            target.sendMacGesture(MacGestureInput(
                kind: swipeAxisHorizontal == true ? .dockHorizontal : .dockVertical,
                phase: cancelled || !Self.swipeCompletes(progress: swipeProgress, velocity: swipeVelocity)
                    ? .cancelled : .ended,
                value: swipeProgress,
                velocity: swipeVelocity
            ))
        }
        swipeAxisHorizontal = nil
        swipeProgress = 0
        swipeVelocity = 0
        swipeShortcutSent = false
    }

    private func sendHeldClick() {
        guard isSecondTouch else { return }
        isSecondTouch = false
        if isEnabled { target()?.clickRemote(.left) }
    }

    private func disarmLongPress() {
        cancelLongPress?()
        cancelLongPress = nil
    }

    private func beginDrag() {
        cancelLongPress = nil
        guard isEnabled, touches.count == 1, travel < Self.tapTravel, !isDragging else { return }
        // Held after a tap: the drag is what the tap led to.
        isSecondTouch = false
        isDragging = true
        haptics.impactOccurred(intensity: 1)
        target()?.setLaptopButton(.left, pressed: true)
    }
}
