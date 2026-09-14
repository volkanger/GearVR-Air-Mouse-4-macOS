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
    static let off: [UInt8]       = [0x00, 0x00]
    static let sensor: [UInt8]    = [0x01, 0x00]
    static let keepAlive: [UInt8] = [0x04, 0x00]
    static let lpmEnable: [UInt8] = [0x06, 0x00]
    static let lpmDisable: [UInt8] = [0x07, 0x00]
    static let vrMode: [UInt8]    = [0x08, 0x00]
}

let args = CommandLine.arguments
let dumpMode = args.contains("--dump")

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    print("[\(f.string(from: Date()))] \(s)")
}

// MARK: - Settings

struct Settings {
    static let d = UserDefaults.standard
    static func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }

    static var touchSpeed: Double   { double("touchSpeed", 2.5) }    // px per touchpad unit (pad is 0..315)
    static var touchAccel: Double   { double("touchAccel", 0.12) }   // extra gain per unit/packet of finger speed
    static var touchFilter: Double  { double("touchFilter", 0.7) }   // 0..1, lower = smoother touch position
    static var maxPacing: Double    { double("maxPacing", 0.035) }   // max seconds a burst's motion is spread over
    static var gyroSpeedX: Double   { double("gyroSpeedX", 0.012) }  // px per raw gyro unit per packet
    static var gyroSpeedY: Double   { double("gyroSpeedY", 0.012) }
    static var gyroAccel: Double    { double("gyroAccel", 0.0007) }  // extra gain per raw unit of rotation speed
    static var gyroMultiplier: Double { double("gyroMultiplier", 1) } // set from the menu
    static var gyroDeadzone: Double { double("gyroDeadzone", 60) }   // raw units after bias removal
    static var scrollLines: Int32   { Int32(double("scrollLines", 3)) }
    static var touchScrollDiv: Double { double("touchScrollDiv", 6) } // touch units per scroll line in gyro mode
    static var tapToClick: Bool     { d.object(forKey: "tapToClick") == nil ? true : d.bool(forKey: "tapToClick") }
    static var triggerAirMouse: Bool { d.bool(forKey: "triggerAirMouse") } // hold trigger = air mouse (set from the menu)
    static var triggerHoldDelay: Double { double("triggerHoldDelay", 0.1) } // seconds before a held trigger starts pointing
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

// MARK: - Mouse output

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
        let p = cursor()
        if down {
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval && hypot(p.x - lastClickPos.x, p.y - lastClickPos.y) < 6 {
                clickCount += 1
            } else { clickCount = 1 }
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
}

// MARK: - Input mapping

final class InputMapper {
    let mouse = Mouse()
    var gyroMode = false { didSet { onGyroModeChange?(gyroMode); onPointingChange?(gyroActive) } }
    var onPointingChange: ((Bool) -> Void)?
    // Air mouse while the trigger is held (when enabled in the menu)
    private(set) var airHeld = false { didSet { if airHeld != oldValue { onPointingChange?(gyroActive) } } }
    var gyroActive: Bool { gyroMode || airHeld }
    private var airPressedAt: Date?   // trigger down, waiting to see if it's a tap or a hold
    var onGyroModeChange: ((Bool) -> Void)?

    private var prev: Packet?
    private var smoothTouch: (x: Double, y: Double)?
    private var touchFrames = 0
    private var touchStart: (time: Date, x: Int, y: Int, moved: Bool)?
    private var scrollAcc = 0.0
    private var volHeldSince: Date?, lastVolRepeat = Date.distantPast
    private var padPressedAt = Date.distantPast

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
        var mdx = 0.0, mdy = 0.0
        noteArrival()
        defer {
            prev = p
            ax.add(mdx, gap: burstGap); ay.add(mdy, gap: burstGap)
        }
        func pressed(_ k: KeyPath<Packet, Bool>) -> Bool { p[keyPath: k] && !old[keyPath: k] }
        func released(_ k: KeyPath<Packet, Bool>) -> Bool { !p[keyPath: k] && old[keyPath: k] }

        // Left button: touchpad click, plus trigger unless it's reserved for the air mouse (hold = drag)
        let triggerAir = Settings.triggerAirMouse
        let leftNow = (!triggerAir && p.trigger) || p.padClick, leftOld = (!triggerAir && old.trigger) || old.padClick
        if leftNow && !leftOld { mouse.button(.left, down: true); touchStart?.moved = true }
        if !leftNow && leftOld { mouse.button(.left, down: false) }
        if p.padClick && !old.padClick { padPressedAt = Date() }

        // Hold trigger: point with the controller once held past the delay; releasing sooner is a left click.
        // The cursor stays put during the delay so squeezing the trigger doesn't nudge it.
        if triggerAir {
            if p.trigger && !old.trigger { airPressedAt = Date() }
            if p.trigger, let t = airPressedAt, Date().timeIntervalSince(t) >= Settings.triggerHoldDelay {
                airHeld = true; airPressedAt = nil
            }
            if !p.trigger && old.trigger {
                if airPressedAt != nil && !p.padClick { mouse.click(.left) }
                airHeld = false; airPressedAt = nil
            }
        } else { airHeld = false; airPressedAt = nil }
        // Pressing the pad makes the finger wobble; freeze touch motion briefly, then allow click-drag
        let padWobble = p.padClick && Date().timeIntervalSince(padPressedAt) < 0.15

        // Home: right click (hold = right drag)
        if pressed(\.home) { mouse.button(.right, down: true) }
        if released(\.home) { mouse.button(.right, down: false) }

        // Back: toggle gyro mode
        if pressed(\.back) { gyroMode.toggle(); log("Gyro mode \(gyroMode ? "ON" : "OFF")") }

        // Volume: scroll, with auto-repeat while held
        let vol: Int32 = p.volUp ? -1 : p.volDown ? 1 : 0   // sign accounts for macOS natural scrolling: + scrolls up
        if vol != 0 {
            let now = Date()
            if pressed(\.volUp) || pressed(\.volDown) {
                mouse.scroll(lines: vol * Settings.scrollLines); volHeldSince = now
            } else if let since = volHeldSince, now.timeIntervalSince(since) > 0.35, now.timeIntervalSince(lastVolRepeat) > 0.06 {
                mouse.scroll(lines: vol); lastVolRepeat = now
            }
        } else { volHeldSince = nil }

        // Touchpad
        if p.touching {
            let rx = Double(p.touchX), ry = Double(p.touchY)
            touchFrames += 1
            if let s = smoothTouch {
                if abs(rx - s.x) + abs(ry - s.y) > 40 + 25 * frames {
                    smoothTouch = (rx, ry)                     // spurious jump; resync without moving
                } else {
                    let a = Settings.touchFilter
                    let n = (x: s.x + (rx - s.x) * a, y: s.y + (ry - s.y) * a)
                    smoothTouch = n
                    let dx = n.x - s.x, dy = n.y - s.y
                    if touchFrames > 2 && !padWobble {           // skip finger-landing jitter and pad-click wobble
                        if gyroActive {
                            scrollAcc += dy / Settings.touchScrollDiv
                            let lines = Int32(scrollAcc)
                            if lines != 0 { mouse.scroll(lines: -lines); scrollAcc -= Double(lines) }
                        } else {
                            // Acceleration: slow swipes are precise, fast swipes cover distance
                            let v = min(hypot(dx, dy) / frames, 20)   // finger speed per packet interval
                            let gain = Settings.touchSpeed * (0.5 + v * Settings.touchAccel)
                            mdx += dx * gain; mdy += dy * gain
                        }
                    }
                }
                if var ts = touchStart, abs(p.touchX - ts.x) + abs(p.touchY - ts.y) > 12 { ts.moved = true; touchStart = ts }
            } else {
                smoothTouch = (rx, ry)
                touchStart = (Date(), p.touchX, p.touchY, false); scrollAcc = 0
            }
        } else if smoothTouch != nil {
            if Settings.tapToClick, let ts = touchStart, !ts.moved, Date().timeIntervalSince(ts.time) < 0.2, !leftNow {
                mouse.click(.left)
            }
            smoothTouch = nil; touchStart = nil; touchFrames = 0
        }

        // Gravity estimate (low-pass accelerometer) — points "up" in controller frame
        if simd_length(p.accel) > 100 {
            up = up == nil ? simd_normalize(p.accel) : simd_normalize(simd_mix(up!, simd_normalize(p.accel), SIMD3(repeating: 0.08)))
        }

        // Gyro
        if gyroActive && !calibrating, let up {
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
            mdx += gx; mdy += gy
        }
    }

    func releaseAll() {
        if mouse.leftDown { mouse.button(.left, down: false) }
        if mouse.rightDown { mouse.button(.right, down: false) }
        prev = nil; smoothTouch = nil; touchStart = nil; touchFrames = 0; airHeld = false; airPressedAt = nil
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

    func findController() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        if let p = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            status("Found connected controller: \(p.name ?? "?")"); connect(p); return
        }
        status("Scanning — press the Home button on the controller…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let services = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if dumpMode && !name.isEmpty { log("  seen: \(name) rssi=\(rssi) services=\(services)") }
        guard name.localizedCaseInsensitiveContains("Gear VR") || services.contains(serviceUUID) else { return }
        c.stopScan()
        status("Discovered \(name) (RSSI \(rssi))"); connect(p)
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
                if args.contains("--hid-init"), svc.uuid == CBUUID(string: "1879") {
                    if ch.uuid == CBUUID(string: "2A4E") { log("  HID: protocol mode = report"); p.writeValue(Data([0x01]), for: ch, type: .withoutResponse) }
                    if ch.uuid == CBUUID(string: "2A4C") { log("  HID: control point = exit suspend"); p.writeValue(Data([0x01]), for: ch, type: .withoutResponse) }
                }
                if args.contains("--subscribe-all"), svc.uuid != CBUUID(string: "FEF5"), svc.uuid != serviceUUID,
                   ch.properties.contains(.notify) {
                    log("  subscribing \(ch.uuid.uuidString)")
                    p.setNotifyValue(true, for: ch)
                }
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
            if Date().timeIntervalSince(self.lastPacket) > 2 { log("No data — resending sensor command"); self.startSensors() }
            else if args.contains("--keepalive") { self.send(Command.keepAlive) }
        }
        if let pollArg = args.first(where: { $0.hasPrefix("--poll=") }) {
            // Experiment: keep ATT traffic going so macOS keeps a fast connection interval
            let mode = pollArg.dropFirst("--poll=".count)
            let ms = Double(args.first(where: { $0.hasPrefix("--pollms=") })?.dropFirst("--pollms=".count) ?? "100") ?? 100
            let battery = p.services?.first(where: { $0.uuid == CBUUID(string: "180F") })
            if mode == "read", let battery { p.discoverCharacteristics(nil, for: battery) }
            Timer.scheduledTimer(withTimeInterval: ms / 1000, repeats: true) { [weak self] t in
                guard let self, let per = self.peripheral, self.writeChar != nil else { t.invalidate(); return }
                if mode == "read" {
                    if let ch = battery?.characteristics?.first { per.readValue(for: ch) }
                } else {
                    self.send(Command.keepAlive)
                }
            }
        }
        if args.contains("--vrmode") {
            // VR mode stops streaming without frequent keep-alives
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
                guard let self, self.writeChar != nil else { t.invalidate(); return }
                self.send(Command.keepAlive)
            }
        }
    }

    func startSensors() {
        if args.contains("--nocmd") { return }
        if let seq = args.first(where: { $0.hasPrefix("--seq=") }) {
            // Experiment: explicit command order, e.g. --seq=vr,sensor
            let map: [Substring: [UInt8]] = ["sensor": Command.sensor, "vr": Command.vrMode, "lpmoff": Command.lpmDisable,
                                             "lpmon": Command.lpmEnable, "ka": Command.keepAlive, "off": Command.off]
            for name in seq.dropFirst("--seq=".count).split(separator: ",") { if let c = map[name] { send(c) } }
            return
        }
        // Low-power mode off first: otherwise the controller drops to ~100 ms Bluetooth bursts and loses
        // more than half its packets. Order matters — sending it after sensor mode stops the stream.
        send(Command.lpmDisable)
        send(Command.sensor)
        if args.contains("--vrmode") { send(Command.vrMode) }
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
    let gyroItem = NSMenuItem(title: "Gyro Mode", action: #selector(toggleGyro), keyEquivalent: "g")
    let speedMenu = NSMenu()
    let holdDelayMenu = NSMenu()
    let triggerAirItem = NSMenuItem(title: "Hold Trigger for Air Mouse", action: #selector(toggleTriggerAir), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon(active: false)
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        gyroItem.target = self; menu.addItem(gyroItem)
        triggerAirItem.target = self; triggerAirItem.state = Settings.triggerAirMouse ? .on : .off
        menu.addItem(triggerAirItem)
        let holdDelayItem = NSMenuItem(title: "Trigger Hold Delay", action: nil, keyEquivalent: "")
        holdDelayItem.submenu = holdDelayMenu
        for ms in [100, 150, 200, 250, 300] {
            let item = NSMenuItem(title: "\(ms) ms", action: #selector(setHoldDelay(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = Double(ms) / 1000
            holdDelayMenu.addItem(item)
        }
        updateHoldDelayChecks()
        menu.addItem(holdDelayItem)
        let speedItem = NSMenuItem(title: "Gyro Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        for m in [0.5, 1, 1.5, 2, 3, 4] {
            let item = NSMenuItem(title: "\(m.formatted())×", action: #selector(setGyroSpeed(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = m
            speedMenu.addItem(item)
        }
        updateSpeedChecks()
        menu.addItem(speedItem)
        menu.addItem(withTitle: "Recalibrate Gyro", action: #selector(recalibrate), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Reconnect", action: #selector(reconnect), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        link.onStatus = { [weak self] s in self?.statusLine.title = s }
        link.mapper.onGyroModeChange = { [weak self] on in
            self?.gyroItem.state = on ? .on : .off
        }
        link.mapper.onPointingChange = { [weak self] on in
            self?.statusItem.button?.image = menuBarIcon(active: on)
        }

        if !dumpMode {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) {
                log("Accessibility permission needed — grant it in System Settings › Privacy & Security › Accessibility, then relaunch")
            }
        } else {
            log("Dump mode: printing packets, mouse output disabled")
        }
    }

    @objc func toggleGyro() { link.mapper.gyroMode.toggle() }

    @objc func toggleTriggerAir() {
        let on = !Settings.triggerAirMouse
        Settings.d.set(on, forKey: "triggerAirMouse")
        triggerAirItem.state = on ? .on : .off
    }

    @objc func setGyroSpeed(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? Double else { return }
        Settings.d.set(m, forKey: "gyroMultiplier")
        updateSpeedChecks()
    }

    @objc func setHoldDelay(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.d.set(v, forKey: "triggerHoldDelay")
        updateHoldDelayChecks()
    }

    func updateHoldDelayChecks() {
        for item in holdDelayMenu.items {
            item.state = abs((item.representedObject as? Double ?? -1) - Settings.triggerHoldDelay) < 0.001 ? .on : .off
        }
    }

    func updateSpeedChecks() {
        for item in speedMenu.items {
            item.state = (item.representedObject as? Double) == Settings.gyroMultiplier ? .on : .off
        }
    }
    @objc func recalibrate() { link.mapper.recalibrate() }
    @objc func reconnect() { link.reconnect() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
