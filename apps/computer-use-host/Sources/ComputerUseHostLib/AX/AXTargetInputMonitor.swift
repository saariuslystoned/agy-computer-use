import Foundation
@preconcurrency import ApplicationServices
import AppKit
import Carbon

/// A target input epoch is sticky: returning focus to another app never restores
/// authority. Invalid monitoring must also reject two equally-invalid samples.
package final class AXTargetInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt32 = 0
    private var valid = true
    private var reason = "none"

    package init() {}
    package func receive(_ type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            invalidate(reason: "event tap disabled")
        } else if type != .mouseMoved {
            intervention(reason: "target event type \(type.rawValue)")
        }
    }
    package func updateHealth(tapEnabled: Bool, trusted: Bool, secureInput: Bool,
                              targetRunning: Bool, targetActive: Bool) {
        guard tapEnabled, trusted, !secureInput, targetRunning else {
            invalidate(reason: !tapEnabled ? "event tap unavailable" : !trusted ? "accessibility unavailable" : secureInput ? "secure input enabled" : "target terminated"); return
        }
        if targetActive { intervention(reason: "target became active") }
    }
    package func intervention(reason: String = "target activation notification") {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        self.reason = reason
    }
    package func invalidate(reason: String = "monitor coverage lost") {
        lock.lock(); defer { lock.unlock() }
        if valid { self.reason = reason }
        valid = false
    }
    package func diagnostic() -> String {
        lock.lock(); defer { lock.unlock() }
        return reason
    }
    package func epoch() -> OperatorInputEpoch {
        lock.lock(); defer { lock.unlock() }
        return OperatorInputEpoch(counters: [generation], coverageValid: valid)
    }
}

/// Read-only, app-scoped monitor. Never records key values or injects input.
/// A separate run loop keeps delivery independent of blocking AX calls. Its
/// lifetime belongs to the retained lease (including compound reinspection).
package final class AXTargetInputMonitor: OperatorInputEpochProviding, @unchecked Sendable {
    private final class Context: @unchecked Sendable {
        let pid: pid_t
        let state = AXTargetInputState()
        let started = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var loop: CFRunLoop?
        var tap: CFMachPort?
        var ready = false
        var stopping = false
        init(pid: pid_t) { self.pid = pid }

        func checkHealth() {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard frontmost != nil else {
                state.invalidate(reason: "foreground identity unavailable"); return
            }
            state.updateHealth(tapEnabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
                trusted: AXIsProcessTrusted(), secureInput: IsSecureEventInputEnabled(),
                targetRunning: kill(pid, 0) == 0,
                targetActive: frontmost == pid)
        }
    }

    private let context: Context
    package let interventionScope = "app"
    package var interventionReason: String { context.state.diagnostic() }
    // Pure movement changes no target state. Drag, scroll, button and keyboard
    // events delivered to ANY window in this app invalidate its lease.
    private static let events: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
        .otherMouseDragged, .keyDown, .keyUp, .flagsChanged, .scrollWheel
    ]
    private static let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

    package init?(pid: pid_t) {
        let context = Context(pid: pid)
        self.context = context
        let thread = Thread { Self.run(context) }
        thread.name = "AX target input monitor"
        thread.start()
        guard context.started.wait(timeout: .now() + 1) == .success else {
            stop(); return nil
        }
        context.lock.lock()
        let ready = context.ready
        context.lock.unlock()
        guard ready else { stop(); return nil }
    }

    deinit { stop() }

    private func stop() {
        context.lock.lock()
        context.stopping = true
        let loop = context.loop
        context.lock.unlock()
        context.state.invalidate()
        if let loop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
    }

    package func currentEpoch() -> OperatorInputEpoch {
        // A stalled/dead event loop cannot authorize a mutation. Sample health
        // on that loop, rather than reading an indefinitely stale counter.
        context.lock.lock()
        let loop = context.loop
        let ready = context.ready && !context.stopping
        context.lock.unlock()
        guard ready, let loop else {
            context.state.invalidate(); return context.state.epoch()
        }
        let sampled = DispatchSemaphore(value: 0)
        let context = self.context
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            context.checkHealth()
            sampled.signal()
        }
        CFRunLoopWakeUp(loop)
        if sampled.wait(timeout: .now() + .milliseconds(100)) != .success {
            context.state.invalidate(reason: "monitor event loop stalled")
        }
        return context.state.epoch()
    }

    private static func run(_ context: Context) {
        let loop = CFRunLoopGetCurrent()!
        context.lock.lock()
        context.loop = loop
        let stopping = context.stopping
        context.lock.unlock()
        guard !stopping, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSRunningApplication(processIdentifier: context.pid),
              !app.isTerminated, !app.isActive else {
            context.started.signal(); return
        }
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        guard let tap = CGEvent.tapCreateForPid(pid: context.pid, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<Context>.fromOpaque(userInfo).takeUnretainedValue()
                context.state.receive(type)
                return Unmanaged.passUnretained(event)
            }, userInfo: opaque) else {
            context.started.signal(); return
        }
        defer { CFMachPortInvalidate(tap) }
        // macOS can silently strip keyboard bits. Do not qualify a partial tap.
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0, count <= 4096 else {
            context.started.signal(); return
        }
        var infos = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &infos, &count) == .success,
              infos.prefix(Int(count)).contains(where: {
                  $0.tappingProcess == getpid() && $0.processBeingTapped == context.pid &&
                  $0.enabled && $0.options == .listenOnly && ($0.eventsOfInterest & mask) == mask
              }) else {
            context.started.signal(); return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            context.started.signal(); return
        }
        var observer: AXObserver?
        guard AXObserverCreate(context.pid, { _, _, _, userInfo in
            guard let userInfo else { return }
            Unmanaged<Context>.fromOpaque(userInfo).takeUnretainedValue().state.intervention()
        }, &observer) == .success, let observer else {
            context.started.signal(); return
        }
        let axApp = AXUIElementCreateApplication(context.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        guard AXObserverAddNotification(observer, axApp, kAXApplicationActivatedNotification as CFString, opaque) == .success else {
            context.started.signal(); return
        }
        defer { AXObserverRemoveNotification(observer, axApp, kAXApplicationActivatedNotification as CFString) }
        CFRunLoopAddSource(loop, source, .defaultMode)
        CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
        defer {
            CFRunLoopRemoveSource(loop, source, .defaultMode)
            CFRunLoopRemoveSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
            context.state.invalidate()
            context.lock.lock(); context.ready = false; context.lock.unlock()
        }
        context.tap = tap
        // Secure input/permission loss must poison the lease even if restored
        // before the next action. This timer also catches active target state.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent(), 0.01, 0, 0) { _ in context.checkHealth() }!
        CFRunLoopAddTimer(loop, timer, .defaultMode)
        defer { CFRunLoopTimerInvalidate(timer) }
        context.checkHealth()
        context.lock.lock()
        context.ready = !context.stopping
        let shouldRun = context.ready
        context.lock.unlock()
        context.started.signal()
        if shouldRun { CFRunLoopRun() }
    }
}
