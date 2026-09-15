// GearVRMouse — use a Samsung Gear VR controller as a mouse on macOS.
//
// Protocol (reverse-engineered by the community, e.g. jsyang/gearvr-controller-webbluetooth):
//   Service  4f63756c-7573-2054-6872-65656d6f7465  ("Oculus Threemote")
//   Notify   c8c51726-81bc-483b-a052-f7a14ea3d281  (60-byte sensor/button packets)
//   Write    c8c51726-81bc-483b-a052-f7a14ea3d282  (2-byte commands)

import Cocoa
import CoreBluetooth
import ApplicationServices
import simd

setvbuf(stdout, nil, _IOLBF, 0)

let serviceUUID = CBUUID(string: "4F63756C-7573-2054-6872-65656D6F7465")
let notifyUUID  = CBUUID(string: "C8C51726-81BC-483B-A052-F7A14EA3D281")
let writeUUID   = CBUUID(string: "C8C51726-81BC-483B-A052-F7A14EA3D282")

enum Command {
    static let sensor: [UInt8]     = [0x01, 0x00]
    static let lpmDisable: [UInt8] = [0x07, 0x00]   // low-power mode off
}

let args = CommandLine.arguments
let dumpMode = args.contains("--dump")

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    print("[\(f.string(from: Date()))] \(s)")
}

// MARK: - Control modes

enum ControlMode: Int, CaseIterable {
    // Raw values are the menu numbers and are saved in preferences
    case triggerPointPadMouse = 1, homeToggle, triggerPoint, touchPoint, backToggle, touchpadOnly, triggerPointPadScroll

    var title: String {
        switch self {
        case .triggerPointPadMouse: return "1 · Hold Trigger to Point, Pad Mouse"
        case .homeToggle:   return "2 · Home Toggles Gyro"
        case .triggerPoint: return "3 · Hold Trigger to Point"
        case .touchPoint:   return "4 · Touch Pad to Point"
        case .backToggle:   return "5 · Back Toggles Gyro"
        case .touchpadOnly: return "6 · Touchpad Only"
        case .triggerPointPadScroll: return "7 · Hold Trigger to Point, Press Pad to Scroll"
        }
    }

    var help: String {
        let volume = " · Volume ±: scroll"
        switch self {
        case .triggerPointPadMouse:
            return "Hold trigger: point · trigger tap: click · swipe pad: move cursor (scroll while pointing) · tap / pad click: left click · hold pad pressed + tilt: scroll · trigger + pad held: click-and-drag · Back: browser back · Home: right click" + volume
        case .homeToggle:
            return "Home: gyro on/off · touching the pad pauses gyro and moves the cursor · trigger tap: click, hold: grab-scroll · pad click: left click · Back: right click" + volume
        case .triggerPoint:
            return "Hold trigger: point · trigger tap: click · swipe pad: scroll · pad click: left click · Back: browser back · Home: right click" + volume
        case .touchPoint:
            return "Touch pad: point · trigger: click (hold = drag) · pad press tap: click, hold: grab-scroll · Back: browser back · Home: right click" + volume
        case .backToggle:
            return "Back tap: gyro on/off, hold: scroll · swipe pad: move (gyro on: scroll) · trigger/pad click: left click · Home: right click" + volume
        case .touchpadOnly:
            return "Swipe pad: move · tap / pad click: left click · trigger: right click · Back / Volume +: scroll up · Home / Volume −: scroll down (hold to repeat)"
        case .triggerPointPadScroll:
            return "Hold trigger: point · trigger tap: click · swipe pad: scroll · hold pad pressed: move the controller to scroll · Back: browser back · Home: right click" + volume
        }
    }

    var hasGyroToggle: Bool { self == .homeToggle || self == .backToggle }
}

// MARK: - Settings (override with `defaults write local.gearvrmouse <key> -float <value>`)

struct Settings {
    static let d = UserDefaults.standard
    static func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }

    static var controlMode: ControlMode { ControlMode(rawValue: d.integer(forKey: "controlMode")) ?? .triggerPointPadMouse }
    static var touchSpeed: Double   { double("touchSpeed", 2.5) }    // px per touchpad unit (pad is 0..315)
    static var touchAccel: Double   { double("touchAccel", 0.12) }   // extra gain per unit/packet of finger speed
    static var touchFilter: Double  { double("touchFilter", 0.7) }   // 0..1, lower = smoother touch position
    static var maxPacing: Double    { double("maxPacing", 0.035) }   // max seconds a burst's motion is spread over
    static var gyroSpeedX: Double   { double("gyroSpeedX", 0.012) }  // px per raw gyro unit per packet
    static var gyroSpeedY: Double   { double("gyroSpeedY", 0.012) }
    static var gyroAccel: Double    { double("gyroAccel", 0.0007) }  // extra gain per raw unit of rotation speed
    static var gyroMultiplier: Double { double("gyroMultiplier", 1) } // set from the menu
    static var gyroDeadzone: Double { double("gyroDeadzone", 60) }   // raw units after bias removal
    static var scrollLines: Int32   { Int32(double("scrollLines", 3)) } // lines per Volume (or Touchpad Only Back/Home) press
    static var tapToClick: Bool     { d.object(forKey: "tapToClick") == nil ? true : d.bool(forKey: "tapToClick") }
    static var holdDelay: Double    { double("holdDelay", 0.15) }    // trigger / pad press held this long = hold
    static var backHoldDelay: Double { double("backHoldDelay", 0.25) } // Back Toggles Gyro: Back held this long = scroll
    static var scrollSign: Double   { double("scrollSign", 1) }      // -1 reverses swipe and grab scrolling
    static var touchScrollSpeed: Double { double("touchScrollSpeed", 4) } // scroll px per touchpad unit
    static var grabScrollSpeed: Double  { double("grabScrollSpeed", 1.5) } // scroll px per cursor px while grabbing
    static var gyroScrollSpeed: Double  { double("gyroScrollSpeed", 1.5) } // Back-hold / pad-hold tilt scroll speed
    static var gyroScrollSign: Double   { double("gyroScrollSign", 1) }
    static var backMethod: String   { d.string(forKey: "backMethod") ?? "auto" } // auto | mouse4 | cmdLeft
    // Gyro pointing: yaw = rotation around real-world vertical (from accelerometer gravity),
    // pitch = rotation around the controller's right axis. Flip signs with `defaults write local.gearvrmouse gyroSignX -float 1`.
    static var gyroSignX: Double    { double("gyroSignX", -1) }
    static var gyroSignY: Double    { double("gyroSignY", -1) }
    // Which raw axis runs along the controller's length (0=x, 1=y, 2=z).
    static var forwardAxis: Int     { Int(double("forwardAxis", 1)) }
}

// MARK: - Packet parsing

struct Packet {
    var touchX: Int
    var touchY: Int
    var buttons: UInt8
    var gyro: SIMD3<Double>   // raw int16 averaged over the 3 samples in the packet
    var accel: SIMD3<Double>
    var raw: [UInt8]
    var deviceTime: UInt32

    var trigger: Bool  { buttons & 0x01 != 0 }
    var home: Bool     { buttons & 0x02 != 0 }
    var back: Bool     { buttons & 0x04 != 0 }
    var padClick: Bool { buttons & 0x08 != 0 }
    var volUp: Bool    { buttons & 0x10 != 0 }
    var volDown: Bool  { buttons & 0x20 != 0 }
    var touching: Bool { touchX != 0 || touchY != 0 }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 60 else { return nil }
        raw = b
        deviceTime = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        func i16(_ o: Int) -> Double { Double(Int16(bitPattern: UInt16(b[o]) | UInt16(b[o + 1]) << 8)) }
        touchX = (Int(b[54] & 0x0F) << 6) | (Int(b[55] & 0xFC) >> 2)
        touchY = (Int(b[55] & 0x03) << 8) | Int(b[56])
        buttons = b[58]
        var g = SIMD3<Double>(repeating: 0), a = SIMD3<Double>(repeating: 0)
        for k in 0..<3 {
            let base = 16 * k
            a += SIMD3(i16(4 + base), i16(6 + base), i16(8 + base))
            g += SIMD3(i16(10 + base), i16(12 + base), i16(14 + base))
        }
        gyro = g / 3; accel = a / 3
    }
}

// MARK: - Mouse / keyboard output

final class Mouse {
    let src = CGEventSource(stateID: .hidSystemState)
    var leftDown = false, rightDown = false
    var lastClickTime = Date.distantPast, lastClickPos = CGPoint.zero, clickCount = 0

    func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func clamp(_ p: CGPoint, from old: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let rects = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        if rects.contains(where: { $0.contains(p) }) { return p }
        let r = rects.first(where: { $0.contains(old) }) ?? rects.first ?? .zero
        return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }

    func move(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        let old = cursor()
        let p = clamp(CGPoint(x: old.x + dx, y: old.y + dy), from: old)
        let type: CGEventType = leftDown ? .leftMouseDragged : rightDown ? .rightMouseDragged : .mouseMoved
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: rightDown && !leftDown ? .right : .left)
        e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e?.post(tap: .cghidEventTap)
    }

    func button(_ btn: CGMouseButton, down: Bool) {
        if btn == .left ? leftDown == down : rightDown == down { return }
        let p = cursor()
        if down {
            let now = Date()
            let near = hypot(p.x - lastClickPos.x, p.y - lastClickPos.y) < 6
            clickCount = now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval && near ? clickCount + 1 : 1
            lastClickTime = now; lastClickPos = p
        }
        let type: CGEventType = btn == .left ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: btn)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        e?.post(tap: .cghidEventTap)
        if btn == .left { leftDown = down } else { rightDown = down }
    }

    func click(_ btn: CGMouseButton) { button(btn, down: true); button(btn, down: false) }

    func scroll(lines: Int32) {
        CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    /// Smooth pixel scrolling for swipe, grab and tilt scrolling.
    func scroll(pixelsY: Int32, pixelsX: Int32) {
        CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: pixelsY, wheel2: pixelsX, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    /// Browser back. Chromium browsers and Firefox understand the mouse "back" button (no side effects in
    /// text fields); Safari doesn't, so it gets ⌘← — layout-independent, unlike ⌘[ on non-US keyboards.
    func browserBack() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let mouseBackApps = ["com.google.Chrome", "com.brave.Browser", "org.mozilla.firefox", "company.thebrowser",
                             "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
        let method = Settings.backMethod
        if method == "mouse4" || (method == "auto" && mouseBackApps.contains(where: { front.hasPrefix($0) })) {
            let p = cursor()
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: CGMouseButton(rawValue: 3)!)
                e?.setIntegerValueField(.mouseEventButtonNumber, value: 3)
                e?.post(tap: .cghidEventTap)
            }
        } else {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 123, keyDown: down)   // left arrow
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
        }
    }
}

// MARK: - Input mapping

/// Distinguishes a quick tap from a press-and-hold.
struct HoldTracker {
    enum Event { case none, tap, holdBegan, holdEnded }
    private var downAt: Date?
    private(set) var holding = false
    var pressed: Bool { downAt != nil || holding }

    mutating func update(down: Bool, delay: Double) -> Event {
        if down {
            if downAt == nil && !holding { downAt = Date(); return .none }
            if let t = downAt, Date().timeIntervalSince(t) >= delay { downAt = nil; holding = true; return .holdBegan }
            return .none
        }
        defer { downAt = nil; holding = false }
        if holding { return .holdEnded }
        return downAt != nil ? .tap : .none
    }

    mutating func reset() { downAt = nil; holding = false }
}

final class InputMapper {
    let mouse = Mouse()
    var mode = Settings.controlMode {
        didSet { releaseAll(); if !mode.hasGyroToggle { gyroMode = false }; log("Control mode: \(mode.title)") }
    }
    private var gyroMode = false
    var onPointingChange: ((Bool) -> Void)?
    private var pointing = false { didSet { if pointing != oldValue { onPointingChange?(pointing) } } }

    private var prev: Packet?
    private var trigger = HoldTracker(), pad = HoldTracker(), back = HoldTracker()
    private var padDownAt = Date.distantPast
    private var smoothTouch: (x: Double, y: Double)?
    private var touchFrames = 0
    private var touchStart: (time: Date, x: Int, y: Int, moved: Bool)?
    private var scrollAccX = 0.0, scrollAccY = 0.0
    private var volHeldSince: Date?, lastVolRepeat = Date.distantPast
    private var tiltScrolling = false
    private var comboLatch = false       // Pad Mouse: trigger + pad drag in progress (until both released)

    // Bluetooth delivers packets in small bursts (typically 2 packets every 30 ms). Motion from each
    // burst is paced out by a 120 Hz timer over the measured gap between bursts, so the cursor glides
    // with only a few ms of added delay.
    private struct Axis {
        var pending = 0.0, rate = 0.0

        mutating func add(_ d: Double, gap: Double) { pending += d; rate = pending / gap }

        mutating func step(dt: Double) -> Double {
            let s = rate * dt
            let out = (abs(pending) < 0.5 || abs(s) >= abs(pending) || s * pending <= 0) ? pending : s
            pending -= out
            return out
        }

        mutating func reset() { pending = 0; rate = 0 }
    }
    private var ax = Axis(), ay = Axis()
    private var fracX = 0.0, fracY = 0.0
    private var lastArrival = 0.0, burstGap = 0.03, lastTick = 0.0
    private var outputTimer: Timer?

    static let deviceTicksPerPacket = 14325.0   // controller timestamp units between packets (~14.3 ms)

    init() {
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        outputTimer = t
    }

    private func noteArrival() {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastArrival
        if gap > 0.006 {                                   // packets closer than 6 ms belong to one burst
            if gap < 0.2 { burstGap = min(max(burstGap * 0.7 + gap * 0.3, 1.0 / 120), Settings.maxPacing) }
            lastArrival = now
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastTick == 0 ? 1.0 / 120 : min(now - lastTick, 0.05)
        lastTick = now
        fracX += ax.step(dt: dt); fracY += ay.step(dt: dt)
        let mx = fracX.rounded(.towardZero), my = fracY.rounded(.towardZero)
        if mx != 0 || my != 0 { mouse.move(dx: mx, dy: my); fracX -= mx; fracY -= my }
    }

    /// Scroll by a motion in pixels. With scrollSign 1 the content follows the motion (grab / natural).
    private func scroll(dx: Double, dy: Double) {
        scrollAccX += dx * Settings.scrollSign; scrollAccY += dy * Settings.scrollSign
        let sx = scrollAccX.rounded(.towardZero), sy = scrollAccY.rounded(.towardZero)
        if sx != 0 || sy != 0 {
            mouse.scroll(pixelsY: Int32(sy), pixelsX: Int32(sx))
            scrollAccX -= sx; scrollAccY -= sy
        }
    }

    private func toggleGyro() { gyroMode.toggle(); log("Gyro mode \(gyroMode ? "ON" : "OFF")") }

    // Gyro bias calibration
    private var bias = SIMD3<Double>(repeating: 0)
    private var calibSamples: [SIMD3<Double>] = []
    private(set) var calibrating = false
    private var up: SIMD3<Double>?

    var hasBias: Bool { calibrating || bias != SIMD3(repeating: 0) }

    func recalibrate() { calibSamples = []; calibrating = true; log("Calibrating gyro — keep controller still…") }

    func handle(_ p: Packet) {
        if calibrating {
            calibSamples.append(p.gyro)
            if calibSamples.count >= 120 {
                bias = calibSamples.reduce(SIMD3(repeating: 0), +) / Double(calibSamples.count)
                calibrating = false
                log("Gyro bias: \(bias)")
            }
        }
        let old = prev ?? p
        // Packets since the previous one we received (>1 means some were dropped over the air)
        var delta = Double(p.deviceTime) - Double(old.deviceTime)
        if delta < 0 { delta += 4_294_967_296 }
        let frames = prev == nil ? 1 : min(max((delta / Self.deviceTicksPerPacket).rounded(), 1), 30)
        var cursorX = 0.0, cursorY = 0.0
        noteArrival()
        defer {
            prev = p
            ax.add(cursorX, gap: burstGap); ay.add(cursorY, gap: burstGap)
        }
        func pressed(_ k: KeyPath<Packet, Bool>) -> Bool { p[keyPath: k] && !old[keyPath: k] }
        func released(_ k: KeyPath<Packet, Bool>) -> Bool { !p[keyPath: k] && old[keyPath: k] }
        func direct(_ k: KeyPath<Packet, Bool>, _ btn: CGMouseButton) {
            if pressed(k) { mouse.button(btn, down: true); touchStart?.moved = true }
            if released(k) { mouse.button(btn, down: false) }
        }
        if pressed(\.padClick) { padDownAt = Date() }
        let touching = p.touching

        // ---- Buttons ----
        var grab = false            // motion scrolls the content instead of moving the cursor
        var leverScroll = false     // Back Toggles Gyro, Back hold: tilt/turn scrolls like a joystick
        var gyroPoints = false      // gyro moves the cursor
        var touchMoves = false      // touchpad moves the cursor (otherwise swipes scroll)

        switch mode {
        case .homeToggle:
            if pressed(\.home) { toggleGyro() }
            direct(\.back, .right)
            direct(\.padClick, .left)
            if trigger.update(down: p.trigger, delay: Settings.holdDelay) == .tap { mouse.click(.left) }
            grab = trigger.holding
            gyroPoints = gyroMode && !touching
            touchMoves = true

        case .triggerPoint:
            direct(\.home, .right)
            if pressed(\.back) { mouse.browserBack() }
            direct(\.padClick, .left)
            if trigger.update(down: p.trigger, delay: Settings.holdDelay) == .tap { mouse.click(.left) }
            gyroPoints = trigger.holding

        case .touchPoint:
            direct(\.home, .right)
            if pressed(\.back) { mouse.browserBack() }
            direct(\.trigger, .left)
            if pad.update(down: p.padClick, delay: Settings.holdDelay) == .tap { mouse.click(.left) }
            grab = pad.holding
            gyroPoints = touching && !pad.pressed   // cursor holds still while the pad is being pressed

        case .backToggle:
            direct(\.home, .right)
            let left = p.trigger || p.padClick, leftOld = old.trigger || old.padClick
            if left && !leftOld { mouse.button(.left, down: true); touchStart?.moved = true }
            if !left && leftOld { mouse.button(.left, down: false) }
            if back.update(down: p.back, delay: Settings.backHoldDelay) == .tap { toggleGyro() }
            leverScroll = back.holding
            gyroPoints = gyroMode && !leverScroll
            touchMoves = !gyroMode && !leverScroll

        case .triggerPointPadScroll:
            direct(\.home, .right)
            if pressed(\.back) { mouse.browserBack() }
            if trigger.update(down: p.trigger, delay: Settings.holdDelay) == .tap { mouse.click(.left) }
            grab = p.padClick                       // pad pressed: gyro scrolls, swipes are ignored
            gyroPoints = trigger.holding && !grab

        case .triggerPointPadMouse:
            direct(\.home, .right)
            if pressed(\.back) { mouse.browserBack() }
            let trigEvent = trigger.update(down: p.trigger, delay: Settings.holdDelay)
            let padEvent = pad.update(down: p.padClick, delay: Settings.holdDelay)
            // Trigger + pad together: click-and-drag, pointing with the gyro. Releasing either drops;
            // nothing else fires until both are released.
            if p.trigger && p.padClick && !comboLatch { comboLatch = true; tiltScrolling = false; mouse.button(.left, down: true) }
            if comboLatch {
                if !(p.trigger && p.padClick) { mouse.button(.left, down: false) }
                if !p.trigger && !p.padClick { comboLatch = false }
                gyroPoints = p.trigger && p.padClick
                tiltScrolling = false
            } else {
                if trigEvent == .tap { mouse.click(.left) }
                // Pad click: tap = left click, press and hold = tilt up/down to scroll
                if padEvent == .tap { mouse.click(.left) }
                tiltScrolling = pad.holding
                gyroPoints = trigger.holding && !pad.pressed
                touchMoves = !trigger.holding && !pad.pressed   // swipes scroll while pointing with the gyro
            }

        case .touchpadOnly:
            direct(\.padClick, .left)
            direct(\.trigger, .right)
            touchMoves = true
        }

        // Volume ± scroll in every mode, with auto-repeat while held. Touchpad Only also scrolls with
        // Back (up) and Home (down).
        let buttonScroll = mode == .touchpadOnly
        let vol: Int32 = p.volUp || (buttonScroll && p.back) ? -1 : p.volDown || (buttonScroll && p.home) ? 1 : 0   // sign accounts for macOS natural scrolling: + scrolls up
        if vol != 0 {
            let now = Date()
            if pressed(\.volUp) || pressed(\.volDown) || (buttonScroll && (pressed(\.back) || pressed(\.home))) {
                mouse.scroll(lines: vol * Settings.scrollLines); volHeldSince = now
            } else if let since = volHeldSince, now.timeIntervalSince(since) > 0.35, now.timeIntervalSince(lastVolRepeat) > 0.06 {
                mouse.scroll(lines: vol); lastVolRepeat = now
            }
        } else { volHeldSince = nil }

        // ---- Touchpad ----
        var tdx = 0.0, tdy = 0.0, tspeed = 0.0
        if touching {
            let rx = Double(p.touchX), ry = Double(p.touchY)
            touchFrames += 1
            if let s = smoothTouch {
                if abs(rx - s.x) + abs(ry - s.y) > 40 + 25 * frames {
                    smoothTouch = (rx, ry)                     // spurious jump; resync without moving
                } else {
                    let a = Settings.touchFilter
                    let n = (x: s.x + (rx - s.x) * a, y: s.y + (ry - s.y) * a)
                    smoothTouch = n
                    // Skip finger-landing jitter and the wobble of pressing the pad
                    let wobble = p.padClick && Date().timeIntervalSince(padDownAt) < 0.15
                    if touchFrames > 2 && !wobble {
                        tdx = n.x - s.x; tdy = n.y - s.y
                        tspeed = min(hypot(tdx, tdy) / frames, 20)   // finger speed per packet interval
                    }
                }
                if var ts = touchStart, abs(p.touchX - ts.x) + abs(p.touchY - ts.y) > 12 { ts.moved = true; touchStart = ts }
            } else {
                smoothTouch = (rx, ry)
                touchStart = (Date(), p.touchX, p.touchY, false)
            }
        } else if smoothTouch != nil {
            let tapModes: Set<ControlMode> = [.homeToggle, .backToggle, .touchpadOnly, .triggerPointPadMouse]
            if tapModes.contains(mode), Settings.tapToClick, let ts = touchStart, !ts.moved, Date().timeIntervalSince(ts.time) < 0.2,
               !p.trigger, !p.padClick, !p.back {
                mouse.click(.left)
            }
            smoothTouch = nil; touchStart = nil; touchFrames = 0
        }
        if tdx != 0 || tdy != 0 {
            if touchMoves {
                // Acceleration: slow swipes are precise, fast swipes cover distance
                let gain = Settings.touchSpeed * (0.5 + tspeed * Settings.touchAccel)
                if grab { scroll(dx: tdx * gain * Settings.grabScrollSpeed, dy: tdy * gain * Settings.grabScrollSpeed) }
                else { cursorX += tdx * gain; cursorY += tdy * gain }
            } else if mode != .touchPoint,
                      !((mode == .triggerPointPadScroll || mode == .triggerPointPadMouse) && p.padClick) {   // pad pressed: ignore swipes
                // Swipe = natural scroll; Pad Mouse reverses the vertical direction
                let vSign: Double = mode == .triggerPointPadMouse ? -1 : 1
                scroll(dx: tdx * Settings.touchScrollSpeed, dy: tdy * Settings.touchScrollSpeed * vSign)
            }
        }

        // ---- Gyro ----
        // Gravity estimate (low-pass accelerometer) — points "up" in controller frame
        if simd_length(p.accel) > 100 {
            up = up == nil ? simd_normalize(p.accel) : simd_normalize(simd_mix(up!, simd_normalize(p.accel), SIMD3(repeating: 0.08)))
        }
        // Grabbing moves content with whatever would have moved the cursor (in Touch Pad to Point and Press Pad to Scroll that's the gyro)
        let gyroGrab = grab && (mode == .touchPoint || mode == .triggerPointPadScroll || gyroPoints)
        pointing = gyroPoints && !grab && !tiltScrolling
        if (gyroPoints || gyroGrab || leverScroll || tiltScrolling) && !calibrating, let up {
            let g = p.gyro - bias
            var fwd = SIMD3<Double>(repeating: 0); fwd[Settings.forwardAxis] = 1
            let rightVec = simd_cross(fwd, up)
            let right = simd_length(rightVec) > 0.2 ? simd_normalize(rightVec) : SIMD3(1, 0, 0) // pointing straight up/down
            func dead(_ v: Double) -> Double {
                let dz = Settings.gyroDeadzone
                return abs(v) < dz ? 0 : v - dz * (v > 0 ? 1 : -1)
            }
            let span = min(frames, 10)   // gyro reports a rate; cover the time of dropped packets too
            let yaw = dead(simd_dot(g, up)), pitch = dead(simd_dot(g, right))
            // Acceleration: slow turns stay precise, quick flicks cross the screen
            let gain = Settings.gyroMultiplier * (1 + hypot(yaw, pitch) * Settings.gyroAccel) * span
            let gx = yaw * Settings.gyroSignX * Settings.gyroSpeedX * gain
            let gy = pitch * Settings.gyroSignY * Settings.gyroSpeedY * gain
            if leverScroll {
                // Tilt up scrolls toward the top, turn left scrolls toward the left. Multiplying by scrollSign
                // cancels the one scroll() applies: this lever has its own gyroScrollSign.
                scroll(dx: -gx * Settings.gyroScrollSpeed * Settings.gyroScrollSign * Settings.scrollSign,
                       dy: -gy * Settings.gyroScrollSpeed * Settings.gyroScrollSign * Settings.scrollSign)
            } else if tiltScrolling {
                // Same lever feel, vertical only: tilt up scrolls toward the top
                scroll(dx: 0, dy: -gy * Settings.gyroScrollSpeed * Settings.gyroScrollSign * Settings.scrollSign)
            } else if gyroGrab {
                scroll(dx: gx * Settings.grabScrollSpeed, dy: gy * Settings.grabScrollSpeed)
            } else {
                cursorX += gx; cursorY += gy
            }
        }
    }

    func releaseAll() {
        if mouse.leftDown { mouse.button(.left, down: false) }
        if mouse.rightDown { mouse.button(.right, down: false) }
        prev = nil; smoothTouch = nil; touchStart = nil; touchFrames = 0
        trigger.reset(); pad.reset(); back.reset(); volHeldSince = nil; tiltScrolling = false; comboLatch = false
        pointing = false
        ax.reset(); ay.reset()
    }
}

// MARK: - Bluetooth

final class GearVRLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var writeChar: CBCharacteristic?
    let mapper = InputMapper()
    var lastPacket = Date.distantPast
    var watchdog: Timer?
    var onStatus: ((String) -> Void)?
    private var dumpCount = 0
    private var lastRawTail: String?
    private var manualReconnect = false
    private var stale = false          // no data for a while; held mouse buttons already released
    private var disconnectedAt: Date?
    private var statGaps: [Double] = [], statTSDeltas: [Int64] = [], statTouchChanges = 0
    private var statStart = Date(), statLastTS: UInt32?, statLastTouch = (0, 0)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func status(_ s: String) { log(s); onStatus?(s) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: findController()
        case .unauthorized: status("Bluetooth permission denied — enable in System Settings › Privacy › Bluetooth")
        case .poweredOff: status("Bluetooth is off")
        default: status("Bluetooth state: \(c.state.rawValue)")
        }
    }

    // The first controller that streams data is remembered; after that the app only connects to that device,
    // so another nearby device advertising the same name or service can't take over the mouse.
    private static let controllerKey = "controllerIdentifier"
    private var knownController: UUID? { Settings.d.string(forKey: Self.controllerKey).flatMap(UUID.init(uuidString:)) }

    func findController() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        if let id = knownController {
            if let p = connected.first(where: { $0.identifier == id }) {
                status("Found connected controller: \(p.name ?? "?")"); connect(p)
            } else if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                // A pending connection completes as soon as the controller wakes up and comes in range
                status("Waiting for your controller — press the Home button on it…"); connect(p)
            } else {
                status("Scanning for your controller — press the Home button on it…")
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
            return
        }
        if let p = connected.first {
            status("Found connected controller: \(p.name ?? "?")"); connect(p); return
        }
        status("Scanning — press the Home button on the controller…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let services = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if dumpMode && !name.isEmpty { log("  seen: \(name) rssi=\(rssi) services=\(services)") }
        if let id = knownController {
            guard p.identifier == id else { return }
        } else {
            guard name.localizedCaseInsensitiveContains("Gear VR") || services.contains(serviceUUID) else { return }
        }
        c.stopScan()
        status("Discovered \(name) (RSSI \(rssi))"); connect(p)
    }

    /// Forget the remembered controller and accept the next Gear VR controller that connects.
    func forgetController() {
        Settings.d.removeObject(forKey: Self.controllerKey)
        log("Forgot remembered controller")
        central.stopScan()
        guard let p = peripheral else { findController(); return }
        if p.state == .connected {
            manualReconnect = true   // skip the fast same-device reconnect; rescan instead
            central.cancelPeripheralConnection(p)
        } else {
            central.cancelPeripheralConnection(p)
            reset(retryAfter: 0.5)   // a pending connection may not report a disconnect
        }
    }

    func connect(_ p: CBPeripheral) {
        peripheral = p; p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status("Connected, discovering services…")
        p.discoverServices(args.contains("--gatt") || dumpMode ? nil : [serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "?"
        if msg.localizedCaseInsensitiveContains("pairing") {
            status("Stale pairing — forget the controller in System Settings › Bluetooth, then hold Home to re-pair")
            reset(retryAfter: 15)
        } else {
            status("Connect failed: \(msg)")
            reset(retryAfter: 2)
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        status("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        guard error != nil, !manualReconnect else {
            manualReconnect = false
            reset(retryAfter: 1); return
        }
        // The controller drops the link roughly every 20 s. It keeps advertising, so reconnect to the
        // same peripheral right away instead of rescanning; fall back to a scan if that stalls.
        mapper.releaseAll()
        watchdog?.invalidate(); watchdog = nil
        writeChar = nil
        disconnectedAt = Date()
        central.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.writeChar == nil, self.peripheral === p, p.state != .connected else { return }
            log("Fast reconnect stalled — rescanning")
            self.central.cancelPeripheralConnection(p)
            self.reset(retryAfter: 0.2)
        }
    }

    func reset(retryAfter s: Double) {
        mapper.releaseAll()
        watchdog?.invalidate(); watchdog = nil
        stale = false
        peripheral = nil; writeChar = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { self.findController() }
    }

    func reconnect() {
        if let p = peripheral { manualReconnect = true; central.cancelPeripheralConnection(p) } else { findController() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if dumpMode { log("  services: \(p.services?.map { $0.uuid.uuidString } ?? []) error=\(String(describing: error))") }
        if args.contains("--gatt") {
            for s in p.services ?? [] where s.uuid != serviceUUID { p.discoverCharacteristics(nil, for: s) }
        }
        guard let svc = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            status("Controller service not found: \(error?.localizedDescription ?? "")"); return
        }
        p.discoverCharacteristics(nil, for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        if args.contains("--gatt") {
            for ch in svc.characteristics ?? [] {
                log("  [\(svc.uuid.uuidString)] char \(ch.uuid.uuidString) props=0x\(String(ch.properties.rawValue, radix: 16))")
                if ch.properties.contains(.read) { p.readValue(for: ch) }
                p.discoverDescriptors(for: ch)
            }
        }
        guard svc.uuid == serviceUUID else { return }
        if dumpMode {
            for ch in svc.characteristics ?? [] { log("  char \(ch.uuid.uuidString) props=0x\(String(ch.properties.rawValue, radix: 16))") }
        }
        for ch in svc.characteristics ?? [] {
            if ch.uuid == notifyUUID { p.setNotifyValue(true, for: ch) }
            if ch.uuid == writeUUID { writeChar = ch }
        }
        guard writeChar != nil else { status("Command characteristic missing"); return }
        startSensors()
        if !mapper.hasBias { mapper.recalibrate() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let silence = Date().timeIntervalSince(self.lastPacket)
            if silence > 3 && !self.stale {
                // Don't leave a mouse button pressed while the controller is silent
                self.stale = true
                self.mapper.releaseAll()
            }
            if silence > 2 { log("No data — resending sensor command"); self.startSensors() }
        }
    }

    func startSensors() {
        // Low-power mode off first: otherwise the controller drops to ~100 ms Bluetooth bursts and loses
        // more than half its packets. Order matters — sending it after sensor mode stops the stream.
        send(Command.lpmDisable)
        send(Command.sensor)
    }

    func send(_ cmd: [UInt8]) {
        guard let p = peripheral, let ch = writeChar else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(cmd), for: ch, type: type)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error: Error?) {
        guard args.contains("--gatt") else { return }
        for d in ch.descriptors ?? [] { log("    desc \(d.uuid.uuidString) on \(ch.uuid.uuidString)") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error { status("Notify failed: \(error.localizedDescription)") }
        else { status("Receiving controller data") }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid != notifyUUID || (ch.value?.count ?? 0) < 60 {
            if args.contains("--gatt") || ch.uuid == notifyUUID {
                let hex = (ch.value ?? Data()).map { String(format: "%02x", $0) }.joined(separator: " ")
                let ascii = String(decoding: (ch.value ?? Data()).map { (32...126).contains($0) ? $0 : 46 }, as: UTF8.self)
                log("  value \(ch.uuid.uuidString): [\(hex)] \"\(ascii)\" err=\(error?.localizedDescription ?? "-")")
            }
            if ch.uuid != notifyUUID { return }
        }
        guard ch.uuid == notifyUUID, let data = ch.value else { return }
        if lastPacket == .distantPast { log("First packet: \(data.count) bytes") }
        if let t = disconnectedAt, data.count >= 60 {
            log(String(format: "Resumed after %.0f ms", Date().timeIntervalSince(t) * 1000)); disconnectedAt = nil
        }
        let now = Date()
        if args.contains("--stats"), lastPacket != .distantPast {
            let gap = now.timeIntervalSince(lastPacket)
            statGaps.append(gap)
            if let pkt = Packet(data) {
                let ts = UInt32(pkt.raw[0]) | UInt32(pkt.raw[1]) << 8 | UInt32(pkt.raw[2]) << 16 | UInt32(pkt.raw[3]) << 24
                if let lt = statLastTS { statTSDeltas.append(Int64(ts) - Int64(lt)) }
                statLastTS = ts
                if pkt.touchX != statLastTouch.0 || pkt.touchY != statLastTouch.1 { statTouchChanges += 1 }
                statLastTouch = (pkt.touchX, pkt.touchY)
            }
            if now.timeIntervalSince(statStart) >= 3 {
                let n = Double(statGaps.count), span = now.timeIntervalSince(statStart)
                let sorted = statGaps.sorted()
                let tsd = statTSDeltas.sorted()
                log(String(format: "stats: %.1f pkt/s  gap avg %.1fms p50 %.1fms p95 %.1fms max %.1fms  touchChanges %.1f/s  devTSdelta p50 %lld min %lld max %lld",
                           n / span, sorted.reduce(0, +) / n * 1000, sorted[sorted.count / 2] * 1000,
                           sorted[Int(n * 0.95)] * 1000, (sorted.last ?? 0) * 1000,
                           Double(statTouchChanges) / span, tsd.isEmpty ? 0 : tsd[tsd.count / 2], tsd.first ?? 0, tsd.last ?? 0))
                statGaps = []; statTSDeltas = []; statTouchChanges = 0; statStart = now
            }
        }
        lastPacket = now
        guard let pkt = Packet(data) else { return }
        stale = false
        if knownController == nil {
            Settings.d.set(p.identifier.uuidString, forKey: Self.controllerKey)
            log("Remembered controller \(p.name ?? "") — only this device will be used from now on")
        }
        if dumpMode {
            dumpCount += 1
            let tail = pkt.raw[57...59].map { String(format: "%02x", $0) }.joined(separator: " ")
            if let prevTail = lastRawTail, prevTail != tail { log("  bytes57-59: \(prevTail) -> \(tail)") }
            lastRawTail = tail
            if dumpCount % 6 == 0 || pkt.buttons & ~0x40 != 0 {
                let g = pkt.gyro, a = pkt.accel
                print(String(format: "touch=(%3d,%3d) btn=%08@ gyro=(%7.0f %7.0f %7.0f) accel=(%6.0f %6.0f %6.0f)",
                             pkt.touchX, pkt.touchY, String(pkt.buttons, radix: 2) as NSString, g.x, g.y, g.z, a.x, a.y, a.z))
            }
            return
        }
        mapper.handle(pkt)
    }
}

// MARK: - App / menu bar

/// Menu bar glyph: controller silhouette with a touchpad ring; motion waves while pointing is active.
func menuBarIcon(active: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 19, height: 18), flipped: false) { _ in
        let head = NSPoint(x: 8, y: 11.5)
        let body = NSBezierPath(ovalIn: NSRect(x: head.x - 5.2, y: head.y - 5.2, width: 10.4, height: 10.4))
        body.append(NSBezierPath(roundedRect: NSRect(x: 5, y: 0.8, width: 6, height: 9), xRadius: 3, yRadius: 3))
        let neck = NSBezierPath()
        neck.move(to: NSPoint(x: 4.0, y: 8.2))
        neck.curve(to: NSPoint(x: 5, y: 5.5), controlPoint1: NSPoint(x: 5, y: 7.4), controlPoint2: NSPoint(x: 5, y: 6.5))
        neck.line(to: NSPoint(x: 11, y: 5.5))
        neck.curve(to: NSPoint(x: 12.0, y: 8.2), controlPoint1: NSPoint(x: 11, y: 6.5), controlPoint2: NSPoint(x: 11, y: 7.4))
        neck.close()
        body.append(neck)
        NSColor.black.setFill()
        body.fill()
        // Touchpad ring
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: head.x - 3.6, y: head.y - 3.6, width: 7.2, height: 7.2)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: NSRect(x: head.x - 2.6, y: head.y - 2.6, width: 5.2, height: 5.2)).fill()
        if active {
            NSColor.black.setStroke()
            for radius in [7.2, 9.4] {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: head, radius: radius, startAngle: -22, endAngle: 30)
                arc.lineWidth = 1.5
                arc.lineCapStyle = .round
                arc.stroke()
            }
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = active ? "GearVRMouse, pointing active" : "GearVRMouse"
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let link = GearVRLink()
    var statusItem: NSStatusItem!
    let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    let modeMenu = NSMenu()
    let holdDelayMenu = NSMenu()
    let speedMenu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon(active: false)
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let modeItem = NSMenuItem(title: "Control Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        for m in ControlMode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(setMode(_:)), keyEquivalent: "\(m.rawValue)")
            item.target = self; item.tag = m.rawValue; item.toolTip = m.help
            modeMenu.addItem(item)
        }
        menu.addItem(modeItem)
        menu.addItem(.separator())

        let holdDelayItem = NSMenuItem(title: "Hold Delay", action: nil, keyEquivalent: "")
        holdDelayItem.submenu = holdDelayMenu
        for ms in [100, 150, 200, 250, 300] {
            let item = NSMenuItem(title: "\(ms) ms", action: #selector(setHoldDelay(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = Double(ms) / 1000
            holdDelayMenu.addItem(item)
        }
        menu.addItem(holdDelayItem)
        let speedItem = NSMenuItem(title: "Gyro Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        for m in [0.5, 1, 1.5, 2, 3, 4] {
            let item = NSMenuItem(title: "\(m.formatted())×", action: #selector(setGyroSpeed(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = m
            speedMenu.addItem(item)
        }
        menu.addItem(speedItem)
        menu.addItem(withTitle: "Recalibrate Gyro", action: #selector(recalibrate), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Reconnect", action: #selector(reconnect), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Forget Controller", action: #selector(forgetController), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        refreshMenu()

        link.onStatus = { [weak self] s in self?.statusLine.title = s }
        link.mapper.onPointingChange = { [weak self] on in
            self?.statusItem.button?.image = menuBarIcon(active: on)
        }
        log("Control mode: \(link.mapper.mode.title)")

        if !dumpMode {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) {
                log("Accessibility permission needed — grant it in System Settings › Privacy & Security › Accessibility, then relaunch")
            }
        } else {
            log("Dump mode: printing packets, mouse output disabled")
        }
    }

    func refreshMenu() {
        let mode = link.mapper.mode
        for item in modeMenu.items { item.state = item.tag == mode.rawValue ? .on : .off }
        for item in holdDelayMenu.items {
            item.state = abs((item.representedObject as? Double ?? -1) - Settings.holdDelay) < 0.001 ? .on : .off
        }
        for item in speedMenu.items {
            item.state = (item.representedObject as? Double) == Settings.gyroMultiplier ? .on : .off
        }
    }

    @objc func setMode(_ sender: NSMenuItem) {
        guard let m = ControlMode(rawValue: sender.tag) else { return }
        Settings.d.set(m.rawValue, forKey: "controlMode")
        link.mapper.mode = m
        refreshMenu()
    }

    @objc func setHoldDelay(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.d.set(v, forKey: "holdDelay")
        refreshMenu()
    }

    @objc func setGyroSpeed(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? Double else { return }
        Settings.d.set(m, forKey: "gyroMultiplier")
        refreshMenu()
    }

    @objc func recalibrate() { link.mapper.recalibrate() }
    @objc func reconnect() { link.reconnect() }
    @objc func forgetController() { link.forgetController() }

    func applicationWillTerminate(_ n: Notification) {
        link.mapper.releaseAll()   // never quit with a mouse button held down
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
