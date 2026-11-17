import Foundation
import Testing
@testable import Rune

@Suite("Phase 2 Shell Parity Tests (P2-03..P2-13)")
struct Phase2ShellParityTests {
    private final class AtomicIntBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ initial: Int = 0) { self.value = initial }
        @discardableResult
        func add(_ delta: Int) -> Int {
            lock.lock()
            value += delta
            let out = value
            lock.unlock()
            return out
        }
        func get() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class SignalChannel<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let sem = DispatchSemaphore(value: 0)
        private var items: [T] = []

        func send(_ item: T) {
            lock.lock()
            items.append(item)
            lock.unlock()
            sem.signal()
        }

        func receive(timeoutSeconds: Double = 10.0) -> T? {
            let res = sem.wait(timeout: .now() + timeoutSeconds)
            guard res == .success else { return nil }
            lock.lock()
            let item = items.isEmpty ? nil : items.removeFirst()
            lock.unlock()
            return item
        }
    }

    private final class ThreadBarrier: @unchecked Sendable {
        private let count: Int
        private let cond = NSCondition()
        private var arrived = 0
        private var generation = 0

        init(_ count: Int) {
            self.count = count
        }

        func wait() {
            cond.lock()
            let gen = generation
            arrived += 1
            if arrived == count {
                arrived = 0
                generation += 1
                cond.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(3.0)
                while gen == generation {
                    if !cond.wait(until: deadline) {
                        cond.unlock()
                        Issue.record("ThreadBarrier timed out at gen=\(gen) arrived=\(arrived)")
                        return
                    }
                }
            }
            cond.unlock()
        }
    }

    private final class MockBackendDriver: ShortcutBackendDriver, @unchecked Sendable {
        let onRegister: @Sendable (UInt32, ParsedShortcut) -> Result<Void, ShortcutError>
        let onUnregister: @Sendable (UInt32) -> Result<Void, ShortcutError>
        let onDrop: @Sendable () -> Void

        init(
            onRegister: @escaping @Sendable (UInt32, ParsedShortcut) -> Result<Void, ShortcutError> = { _, _ in .success(()) },
            onUnregister: @escaping @Sendable (UInt32) -> Result<Void, ShortcutError> = { _ in .success(()) },
            onDrop: @escaping @Sendable () -> Void = {}
        ) {
            self.onRegister = onRegister
            self.onUnregister = onUnregister
            self.onDrop = onDrop
        }

        func register(id: UInt32, shortcut: ParsedShortcut) -> Result<Void, ShortcutError> {
            onRegister(id, shortcut)
        }

        func unregister(id: UInt32) -> Result<Void, ShortcutError> {
            onUnregister(id)
        }

        deinit {
            onDrop()
        }
    }

    private func makeTestApp(_ title: String) -> App<Int> {
        App<Int>(title: title, size: Vec2(40, 40), state: 0) { _, _ in el() }
    }

    // Live mock backends share process-wide claims, so independent tests use distinct chords.
    private func chord(_ text: String) -> ParsedShortcut {
        try! ParsedShortcut.parseOn(text)
    }

    private func isSuccess(_ res: Result<Void, ShortcutError>) -> Bool {
        if case .success = res { return true }
        return false
    }

    private func isUnknownId(_ res: Result<Void, ShortcutError>) -> Bool {
        if case .failure(.unknownId) = res { return true }
        return false
    }

    private func isNotRunning(_ res: Result<Void, ShortcutError>) -> Bool {
        if case .failure(.notRunning) = res { return true }
        return false
    }

    // MARK: - P2-03 & P2-04: Cx.hoverNone & Cx.touchControls

    @Test("PrimaryPointer mapping, native Cx defaults, MemoScope hash, and ResizeBuildEnv tracking")
    func primaryPointerAndCxCapabilities() {
        #expect(PrimaryPointer.from(hover: true, coarse: false) == .hover)
        #expect(PrimaryPointer.from(hover: false, coarse: false) == .noHover)
        #expect(PrimaryPointer.from(hover: false, coarse: true) == .touch)
        #expect(PrimaryPointer.from(hover: true, coarse: true) == .hover)

        #expect(!PrimaryPointer.hover.hoverNone)
        #expect(!PrimaryPointer.hover.touchControls)
        #expect(PrimaryPointer.noHover.hoverNone)
        #expect(!PrimaryPointer.noHover.touchControls)
        #expect(PrimaryPointer.touch.hoverNone)
        #expect(PrimaryPointer.touch.touchControls)

        var seenHoverNone: [Bool] = []
        var seenTouchControls: [Bool] = []
        let memoRuns = AtomicIntBox()
        let memoCache = MemoCache()

        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 120),
            view: { _, cx in
                seenHoverNone.append(cx.hoverNone())
                seenTouchControls.append(cx.touchControls())
                return memo("ptr-cap", deps: "const", cache: memoCache) {
                    memoRuns.add(1)
                    return el().key("\(cx.hoverNone()):\(cx.touchControls())")
                }
            }
        )

        _ = rt.frame(at: 0.0)
        #expect(seenHoverNone == [false])
        #expect(seenTouchControls == [false])
        #expect(memoRuns.get() == 1)
        #expect(!rt.hoverNone())
        #expect(!rt.touchControls())
        #expect(rt.currentResizeBuildEnv().primaryPointer == .hover)

        // Setting the same capability is a no-op.
        #expect(!rt.setPrimaryPointer(.hover))
        _ = rt.frame(at: 0.016)
        #expect(memoRuns.get() == 1)

        // Switching to noHover invalidates view + memo.
        #expect(rt.setWebPointerCapability(hover: false, coarse: false))
        _ = rt.frame(at: 0.032)
        #expect(seenHoverNone == [false, true])
        #expect(seenTouchControls == [false, false])
        #expect(memoRuns.get() == 2)
        #expect(rt.hoverNone())
        #expect(!rt.touchControls())
        #expect(rt.currentResizeBuildEnv().primaryPointer == .noHover)

        // Switching to touch invalidates view + memo.
        #expect(rt.setWebPointerCapability(hover: false, coarse: true))
        _ = rt.frame(at: 0.048)
        #expect(seenHoverNone == [false, true, true])
        #expect(seenTouchControls == [false, false, true])
        #expect(memoRuns.get() == 3)
        #expect(rt.hoverNone())
        #expect(rt.touchControls())
        #expect(rt.currentResizeBuildEnv().primaryPointer == .touch)
    }

    @MainActor
    @Test("WebAppHost.handlePrimaryPointer updates Runtime capability and marks dirty only on transition")
    func webAppHostPrimaryPointerTransition() throws {
        let renders = AtomicIntBox()
        let app = App<Int>(title: "WebCap", size: Vec2(120, 80), state: 0) { _, cx in
            renders.add(1)
            return el().key(cx.touchControls() ? "touch" : (cx.hoverNone() ? "nohover" : "hover"))
        }
        let host = WebAppHost(spec: app.intoSpec(), devicePixelRatio: 1.0)
        _ = try host.renderFrame(at: 0.0)
        #expect(renders.get() == 1)

        #expect(!host.handlePrimaryPointer(hover: true, coarse: false))
        #expect(host.handlePrimaryPointer(hover: false, coarse: true))
        #expect(!host.handlePrimaryPointer(hover: false, coarse: true))
        _ = try host.renderFrame(at: 0.016)
        #expect(renders.get() == 2)
    }

    // MARK: - P2-11 & P2-12: Drain Ordering & Tx.elementAt*

    @Test("drainOrdersFocusAtPublicationNotAtWakeOrCollection (`drain_tests.rs:6`)")
    func drainOrdersFocusAtPublicationNotAtWakeOrCollection() {
        for publish in stride(from: 4, through: 0, by: -1) {
            for finish in publish..<5 {
                let app = makeTestApp("DrainOrder")
                let shared = app.sharedHandle.shared
                let handle = app.handle()
                let barrier = ThreadBarrier(2)
                let rt = app.makeRuntime()

                shared.setWaker(Waker {
                    barrier.wait() // Published; writer no longer holds shared lock.
                    barrier.wait() // Allow focus() to finish.
                })

                let done = SignalChannel<Void>()
                Thread {
                    barrier.wait()
                    handle.focus()
                    barrier.wait()
                    done.send(())
                }.start()

                let gap: @Sendable (Int) -> Void = { i in
                    if i == publish { barrier.wait(); barrier.wait() }
                    if i == finish { barrier.wait(); barrier.wait() }
                }

                shared.queueUpdateWithoutWake { _, tx in
                    gap(1)
                    tx.minimize()
                    gap(2)
                }

                gap(0)
                let batch = shared.applyStateUpdates(to: rt, at: 0.0) { _ in
                    gap(3)
                }
                gap(4)
                #expect(done.receive() != nil)

                #expect((batch.activation == AppActivation.focus) == (publish < 4))
                #expect(rt.minimizeRequested == !(2..<4).contains(publish))
                let next = shared.applyStateUpdates(to: rt, at: 0.016) { _ in
                    Issue.record("unexpected callback on second drain")
                }
                #expect((next.activation == AppActivation.focus) == (publish == 4))
            }
        }
    }

    @Test("drainOrdersRestoresEvenIfAShowReplacesTheWindowRequest (`drain_tests.rs:53`)")
    func drainOrdersRestoresEvenIfAShowReplacesTheWindowRequest() {
        for restore in [false, true] {
            let app = makeTestApp("DrainRestore")
            let shared = app.sharedHandle.shared
            let handle = app.handle()
            let rt = app.makeRuntime()

            handle.update { _, tx in tx.minimize() }
            let batch = shared.applyStateUpdates(to: rt, at: 0.0) { _ in
                if restore { handle.open() }
                handle.show()
            }
            #expect(batch.window == (restore ? AppWindowRequest.open : AppWindowRequest.show))
            #expect(rt.minimizeRequested == !restore)
        }
    }

    @Test("aPickCallbackThatPutsBackItsTxDiscardsTheMinimize (`drain_tests.rs:69`)")
    func pickCallbackPutsBackTxDiscardsMinimize() {
        let app = makeTestApp("PickRollback")
        let shared = app.sharedHandle.shared
        let rt = app.makeRuntime()

        shared.queueUpdateWithoutWake { _, tx in
            let before = tx
            tx.minimize()
            tx.elementAt(-50.0, -50.0) { (_: inout Int, hit: Picked?, innerTx: inout Tx) in
                #expect(hit == nil)
                innerTx = before
            }
        }

        _ = shared.applyStateUpdates(to: rt, at: 0.0)
        #expect(!rt.minimizeRequested)
    }

    @Test("Tx.elementAtWith, elementAtIn, elementAtInWith pick target element key")
    func txElementAtVariantsHitAndMiss() {
        final class CaptureBox: @unchecked Sendable {
            var directHit: Picked?
            var inHit: Picked?
            var missChecked = false
        }
        let box = CaptureBox()
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 100),
            view: { _, _ in
                el().size(200, 100)
                    .child(el().key("target").size(80, 40))
            }
        )
        _ = rt.frame(at: 0.0)

        rt.updateIf(at: 0.016) { _, tx in
            tx.elementAtIn("target", x: 10.0, y: 10.0) { (_: inout Int, hit: Picked?, _) in
                box.inHit = hit
            }
            tx.elementAt(10.0, 10.0) { (_: inout Int, hit: Picked?, _) in
                box.directHit = hit
            }
            tx.elementAtInWith("missing", x: 10.0, y: 10.0, pick: .default) { (_: inout Int, hit: Picked?, _) in
                #expect(hit == nil)
                box.missChecked = true
            }
            return false
        }
        #expect(box.inHit?.key == "target")
        #expect(box.directHit?.key == "target")
        #expect(box.missChecked)
    }

    // MARK: - P2-13: RuneStartup

    @Test("RuneStartup.handleResult formats error to stderr and invokes exit code 1 on failure")
    func startupStartedErrorHandling() {
        enum SampleError: Error, CustomStringConvertible {
            case boom
            var description: String { "sample startup boom" }
        }

        var written = ""
        var exitCode: Int32?
        let ok = RuneStartup.handleResult(
            .success(()),
            writeStderr: { written += $0 },
            exitProcess: { exitCode = $0 }
        )
        #expect(ok)
        #expect(written.isEmpty)
        #expect(exitCode == nil)

        let failed = RuneStartup.handleResult(
            .failure(SampleError.boom),
            writeStderr: { written += $0 },
            exitProcess: { exitCode = $0 }
        )
        #expect(!failed)
        #expect(written == "sample startup boom")
        #expect(exitCode == 1)
    }

    // MARK: - P2-05..P2-10: Shortcut Machine Tests (`machine_tests.rs`)

    @Test("ShortcutAttachmentState state machine attach/call/post/drain/replace/close (`machine_tests.rs`)")
    func shortcutAttachmentStateMachine() {
        var state: ShortcutAttachmentState<Int> = .detached
        let o1 = NSObject()
        let o2 = NSObject()
        let o3 = NSObject()
        withExtendedLifetime((o1, o2, o3)) {
            let t1 = ObjectIdentifier(o1)
            let t2 = ObjectIdentifier(o2)
            let t3 = ObjectIdentifier(o3)

            // Pending before attach refuses call and drops post.
            let e1 = stepShortcutAttachment(&state, event: .call(from: t1, shared: false))
            #expect(e1.count == 1)
            if case .refuse = e1[0] {} else { Issue.record("expected .refuse when detached") }
            let p1 = stepShortcutAttachment(&state, event: .post(42))
            #expect(p1.isEmpty)

            // Attach on t1: same-thread call runs immediately and wakes; off-thread waits.
            let wake1 = Waker {}
            _ = stepShortcutAttachment(&state, event: .attach(owner: t1, wake: wake1, host: 10))
            let sameThread = stepShortcutAttachment(&state, event: .call(from: t1, shared: false))
            #expect(sameThread.count == 1)
            if case .run = sameThread[0] {} else { Issue.record("expected .run") }

            let offThread = stepShortcutAttachment(&state, event: .call(from: t2, shared: false))
            #expect(offThread.count == 1)
            if case .wait = offThread[0] {} else { Issue.record("expected .wait") }

            let posted = stepShortcutAttachment(&state, event: .post(7))
            #expect(posted.count == 1)
            if case .wake = posted[0] {} else { Issue.record("expected .wake") }

            // Old host drain ignores wrong host 9; drains host 10.
            let wrongDrain = stepShortcutAttachment(&state, event: .drain(host: 9))
            #expect(wrongDrain.isEmpty)
            let rightDrain = stepShortcutAttachment(&state, event: .drain(host: 10))
            if case .jobs(let jobs) = rightDrain.first {
                #expect(jobs == [7])
            } else {
                Issue.record("expected .jobs([7])")
            }

            // Replace while queued moves jobs to host 20 and wakes host 20.
            _ = stepShortcutAttachment(&state, event: .post(99))
            let replaced = stepShortcutAttachment(&state, event: .attach(owner: t3, wake: Waker {}, host: 20))
            #expect(replaced.count == 1)
            let drained20 = stepShortcutAttachment(&state, event: .drain(host: 20))
            if case .jobs(let jobs20) = drained20.first {
                #expect(jobs20 == [99])
            } else {
                Issue.record("expected .jobs([99])")
            }

            // Close returns released queued jobs cleanly.
            _ = stepShortcutAttachment(&state, event: .post(5))
            let closed = stepShortcutAttachment(&state, event: .close)
            #expect(closed.count == 1)
            if case .release(let left) = closed[0] {
                #expect(left == [5])
            } else {
                Issue.record("expected .release([5])")
            }
            let afterClose = stepShortcutAttachment(&state, event: .call(from: t3, shared: false))
            #expect(afterClose.count == 1)
            if case .refuse = afterClose[0] {} else { Issue.record("expected .refuse when closed") }
        }
    }

    @Test("ShortcutBindingsState state machine virtual, connect, reject, disconnect (`machine_tests.rs`)")
    func shortcutBindingsStateMachine() {
        var virtualState: ShortcutBindingsState<String> = .virtual([:])
        let sc = chord("ctrl+alt+m")
        let regV = stepShortcutBindings(&virtualState, event: .register(id: 1, shortcut: sc, claimed: false))
        #expect(regV.isEmpty)
        #expect(virtualState.find(sc) == 1)
        let dupV = stepShortcutBindings(&virtualState, event: .register(id: 2, shortcut: sc, claimed: false))
        if case .some(.refuse(.alreadyInUse(owner: nil))) = dupV.first {} else {
            Issue.record("expected refuse(.alreadyInUse(owner: nil))")
        }

        var liveState: ShortcutBindingsState<String> = .disconnected
        let connEff = stepShortcutBindings(&liveState, event: .register(id: 1, shortcut: sc, claimed: false))
        if case .some(.connect(id: 1, shortcut: let sc0)) = connEff.first {
            #expect(sc0 == sc)
        } else {
            Issue.record("expected .connect")
        }

        let bindEff = stepShortcutBindings(&liveState, event: .opened(native: "drv", id: 1, shortcut: sc))
        if case .some(.bind(id: 1, shortcut: let sc1)) = bindEff.first {
            #expect(sc1 == sc)
        } else {
            Issue.record("expected .bind")
        }

        // Reject disconnects when nothing bound yet.
        let rejEff = stepShortcutBindings(&liveState, event: .rejected(.permissionDenied))
        #expect(rejEff.count == 2)
        if case .disconnect("drv") = rejEff[0], case .refuse(.permissionDenied) = rejEff[1] {} else {
            Issue.record("expected disconnect + refuse(.permissionDenied)")
        }

        // Retry after rejection connects again.
        let retryEff = stepShortcutBindings(&liveState, event: .register(id: 2, shortcut: sc, claimed: false))
        if case .some(.connect(id: 2, shortcut: _)) = retryEff.first {} else {
            Issue.record("expected .connect retry")
        }
        _ = stepShortcutBindings(&liveState, event: .opened(native: "drv2", id: 2, shortcut: sc))
        _ = stepShortcutBindings(&liveState, event: .bound(id: 2, shortcut: sc))
        #expect(liveState.find(sc) == 2)

        // Unregister last binding unbinds then disconnects.
        let unregEff = stepShortcutBindings(&liveState, event: .unregister(2))
        if case .some(.unbind(2)) = unregEff.first {} else {
            Issue.record("expected .unbind(2)")
        }
        let unboundEff = stepShortcutBindings(&liveState, event: .unbound(2))
        if case .some(.disconnect("drv2")) = unboundEff.first {} else {
            Issue.record("expected .disconnect(drv2)")
        }
    }

    // MARK: - P2-05..P2-10: Service Tests (`service.rs::tests`)

    @Test("Mock backend errors are not confused with conflicts (`service.rs:573`)")
    func mockBackendErrorsNotConfusedWithConflicts() {
        for err in [ShortcutError.unsupported, .permissionDenied, .rejectedByOS("denied")] {
            let app = makeTestApp("MockErr")
            let sc = chord("ctrl+alt+f1")
            let errCopy = err
            let guardObj = ShortcutGuard.attachWith(
                shared: app.sharedHandle.shared,
                wake: Waker {},
                headless: false,
                connect: { _, _ in
                    .success(MockBackendDriver(onRegister: { _, _ in .failure(errCopy) }))
                }
            )
            defer { guardObj.close() }

            let result = app.handle().registerShortcut(sc) { _, _ in }
            #expect(result == .failure(err))
            #expect(app.handle().shortcutOwner(sc) == nil)
        }
    }

    @Test("Conflicts name the App that holds the chord (`service.rs:601`)")
    func conflictsNameAppHoldingChord() {
        let sc = chord("ctrl+alt+f2")
        let first = makeTestApp("FirstApp")
        let firstGuard = ShortcutGuard.attachWith(
            shared: first.sharedHandle.shared,
            wake: Waker {},
            headless: false,
            connect: { _, _ in .success(MockBackendDriver()) }
        )
        defer { firstGuard.close() }
        _ = try! first.handle().registerShortcut(sc) { _, _ in }.get()

        let second = makeTestApp("SecondApp")
        let secondGuard = ShortcutGuard.attachWith(
            shared: second.sharedHandle.shared,
            wake: Waker {},
            headless: false,
            connect: { _, _ in
                .success(MockBackendDriver(onRegister: { _, _ in .failure(.alreadyInUse(owner: nil)) }))
            }
        )
        defer { secondGuard.close() }
        let res = second.handle().registerShortcut(sc) { _, _ in }
        #expect(res == .failure(.alreadyInUse(owner: "FirstApp")))
        #expect(second.handle().shortcutOwner(sc) == "FirstApp")
    }

    @Test("Headless handlers share state and unregister cancels queued activation (`service.rs:627`)")
    func headlessHandlersShareStateAndUnregisterCancelsActivation() {
        let app = makeTestApp("Headless")
        let shared = app.sharedHandle.shared
        let handle = app.handle()
        let rt = app.makeRuntime()
        let guardObj = ShortcutGuard.attach(shared: shared, wake: Waker {}, headless: true)
        defer { guardObj.close() }

        let a = chord("ctrl+alt+f3")
        let b = chord("ctrl+alt+f4")
        let idA = try! handle.registerShortcut(a) { s, _ in s += 10 }.get()
        _ = try! handle.registerShortcut(b) { s, _ in s += 1 }.get()

        #expect(isSuccess(shared.shortcuts.fire(a)))
        #expect(isSuccess(shared.shortcuts.fire(b)))
        #expect(isSuccess(handle.unregisterShortcut(idA)))

        guardObj.withReceiving {
            _ = shared.applyStateUpdates(to: rt, at: 0.0)
        }
        #expect(rt.state == 1)
    }

    @Test("Chord without modifier is refused unless function key (`service.rs:647`)")
    func chordWithoutModifierRefusedUnlessFunctionKey() {
        let app = makeTestApp("ModifierGate")
        let guardObj = ShortcutGuard.attach(shared: app.sharedHandle.shared, wake: Waker {}, headless: true)
        defer { guardObj.close() }

        let bare = chord("k")
        let bareRes = app.handle().registerShortcut(bare) { _, _ in }
        if case .failure(.invalidAccelerator) = bareRes {} else {
            Issue.record("expected invalidAccelerator for unmodified key")
        }
        #expect((try? app.handle().registerShortcut(chord("f5")) { _, _ in }.get()) != nil)
    }

    @Test("Background registration wakes owner and returns backend result (`service.rs:658`)")
    func backgroundRegistrationWakesAndReturnsResult() {
        let app = makeTestApp("BgReg")
        let woke = SignalChannel<Void>()
        let guardObj = ShortcutGuard.attachWith(
            shared: app.sharedHandle.shared,
            wake: Waker { woke.send(()) },
            headless: false,
            connect: { _, _ in
                .success(MockBackendDriver(onRegister: { _, _ in .failure(.rejectedByOS("bg failed")) }))
            }
        )
        defer { guardObj.close() }

        let answer = SignalChannel<Result<UInt32, ShortcutError>>()
        let handle = app.handle()
        let sc = chord("ctrl+alt+f6")
        Thread {
            answer.send(handle.registerShortcut(sc) { _, _ in })
        }.start()

        #expect(woke.receive() != nil)
        guardObj.drain()
        #expect(answer.receive() == .failure(.rejectedByOS("bg failed")))
    }

    @Test("Activation tokens are scoped to handler and shutdown breaks cycles (`service.rs:677`)")
    func activationTokensScopedAndShutdownBreaksCycles() {
        let app = makeTestApp("Tokens")
        let shared = app.sharedHandle.shared
        let rt = app.makeRuntime()

        weak var weakHooked: AnyObject?
        do {
            let localApp = makeTestApp("TokensLocal")
            weakHooked = localApp.sharedHandle.shared
            #expect(weakHooked != nil)
        }
        #expect(weakHooked == nil)

        do {
            let sinkBox = SignalChannel<ShortcutSink>()
            let guardObj = ShortcutGuard.attachWith(
                shared: shared,
                wake: Waker {},
                headless: false,
                connect: { _, sink in
                    sinkBox.send(sink)
                    return .success(MockBackendDriver())
                }
            )
            let sc = chord("ctrl+alt+f7")
            let id = try! app.handle().registerShortcut(sc) { s, tx in
                #expect(tx.activationToken() == "tok-77")
                s += 1
            }.get()

            let sink = sinkBox.receive()!
            sink(id, "tok-77")
            guardObj.withReceiving {
                _ = shared.applyStateUpdates(to: rt, at: 0.0)
            }
            #expect(rt.state == 1)

            shared.queueUpdateWithoutWake { _, tx in
                #expect(tx.activationToken() == nil)
            }
            guardObj.withReceiving {
                _ = shared.applyStateUpdates(to: rt, at: 0.016)
            }
            guardObj.close()
        }
        #expect(rt.state == 1)
    }

    @Test("Backend retires before its chord stops naming an owner (`service.rs:703`)")
    func backendRetiresBeforeChordStopsNamingOwner() {
        let sc = chord("ctrl+alt+f8")
        let drops = AtomicIntBox()

        let first = makeTestApp("FirstOwner")
        let firstGuard = ShortcutGuard.attachWith(
            shared: first.sharedHandle.shared,
            wake: Waker {},
            headless: false,
            connect: { _, _ in .success(MockBackendDriver(onDrop: { drops.add(1) })) }
        )
        _ = try! first.handle().registerShortcut(sc) { _, _ in }.get()
        #expect(first.handle().shortcutOwner(sc) == "FirstOwner")

        firstGuard.close()
        #expect(drops.get() == 1)

        let second = makeTestApp("SecondOwner")
        let secondGuard = ShortcutGuard.attachWith(
            shared: second.sharedHandle.shared,
            wake: Waker {},
            headless: false,
            connect: { _, _ in .success(MockBackendDriver()) }
        )
        defer { secondGuard.close() }
        #expect(second.handle().shortcutOwner(sc) == nil)
        #expect((try? second.handle().registerShortcut(sc) { _, _ in }.get()) != nil)
        #expect(second.handle().shortcutOwner(sc) == "SecondOwner")
    }

    // MARK: - P2-05..P2-10: Lifecycle, Host Handler, Closed Wake & Generation Concurrency Tests

    @Test("Closed service refuses calls and new host starts empty (`lifecycle_tests.rs:11`)")
    func closedServiceRefusesAndNewHostStartsEmpty() {
        let app = makeTestApp("Reattach")
        let handle = app.handle()
        let sc = chord("ctrl+alt+r")
        #expect(handle.registerShortcut(sc) { _, _ in } == .failure(.notRunning))
        #expect(isNotRunning(app.sharedHandle.shared.shortcuts.fire(sc)))

        let g1 = ShortcutGuard.attach(shared: app.sharedHandle.shared, wake: Waker {}, headless: true)
        let id1 = try! handle.registerShortcut(sc) { _, _ in }.get()
        g1.close()

        #expect(handle.registerShortcut(sc) { _, _ in } == .failure(.notRunning))
        #expect(isNotRunning(handle.unregisterShortcut(id1)))
        #expect(handle.shortcutOwner(sc) == nil)
        #expect(isNotRunning(app.sharedHandle.shared.shortcuts.fire(sc)))

        let g2 = ShortcutGuard.attach(shared: app.sharedHandle.shared, wake: Waker {}, headless: true)
        defer { g2.close() }
        #expect(isUnknownId(handle.unregisterShortcut(id1)))
        #expect(isUnknownId(app.sharedHandle.shared.shortcuts.fire(sc)))
        let id2 = try! handle.registerShortcut(sc) { _, _ in }.get()
        #expect(id2 != id1)
        #expect(handle.shortcutOwner(sc) == "Reattach")
    }

    @Test("Static shortcuts wait for next attach regardless of state (`lifecycle_tests.rs:40`)")
    func staticShortcutsWaitForNextAttach() {
        let scP = chord("ctrl+alt+p")
        let scW = chord("ctrl+alt+w")
        let scQ = chord("ctrl+alt+q")

        let app0 = makeTestApp("Pending")
            .globalShortcut("ctrl+alt+p") { _, _ in }
        let g1 = ShortcutGuard.attach(shared: app0.sharedHandle.shared, wake: Waker {}, headless: true)
        #expect(isSuccess(app0.sharedHandle.shared.shortcuts.fire(scP)))

        let app1 = app0.globalShortcut("ctrl+alt+w") { _, _ in }
        #expect(isUnknownId(app1.sharedHandle.shared.shortcuts.fire(scW)))
        g1.close()

        let app2 = app1
            .globalShortcut("ctrl+alt+q") { _, _ in }
            .globalShortcut("q") { _, _ in }
        let g2 = ShortcutGuard.attach(shared: app2.sharedHandle.shared, wake: Waker {}, headless: true)
        defer { g2.close() }

        #expect(isSuccess(app2.sharedHandle.shared.shortcuts.fire(scW)))
        #expect(isSuccess(app2.sharedHandle.shared.shortcuts.fire(scQ)))
        #expect(isUnknownId(app2.sharedHandle.shared.shortcuts.fire(scP)))
        let errs = app2.handle().takeShortcutErrors()
        #expect(errs.count == 1)
        if case .invalidAccelerator = errs[0] {} else {
            Issue.record("expected invalidAccelerator for unmodified 'q'")
        }
    }

    @Test("Closing releases callers waiting for the owner (`lifecycle_tests.rs:60`)")
    func closingReleasesCallersWaitingForOwner() {
        let app = makeTestApp("Waiting")
        let woke = SignalChannel<Void>()
        let guardObj = ShortcutGuard.attach(
            shared: app.sharedHandle.shared,
            wake: Waker { woke.send(()) },
            headless: true
        )
        let answer = SignalChannel<Result<UInt32, ShortcutError>>()
        let handle = app.handle()
        let sc = chord("ctrl+alt+c")
        Thread {
            answer.send(handle.registerShortcut(sc) { _, _ in })
        }.start()

        #expect(woke.receive() != nil)
        guardObj.close()
        #expect(answer.receive() == .failure(.notRunning))
    }

    @Test("Second host keeps waiting callers and either close ends service (`lifecycle_tests.rs:74`)")
    func secondHostKeepsWaitingCallersAndEitherCloseEnds() {
        let app = makeTestApp("Second")
        let firstWoke = SignalChannel<Void>()
        let first = ShortcutGuard.attach(
            shared: app.sharedHandle.shared,
            wake: Waker { firstWoke.send(()) },
            headless: true
        )
        let answer = SignalChannel<Result<UInt32, ShortcutError>>()
        let handle = app.handle()
        let sc = chord("ctrl+alt+s")
        Thread {
            answer.send(handle.registerShortcut(sc) { _, _ in })
        }.start()
        #expect(firstWoke.receive() != nil)

        let second = ShortcutGuard.attach(shared: app.sharedHandle.shared, wake: Waker {}, headless: true)
        second.drain()
        #expect((try? answer.receive()?.get()) != nil)
        #expect(handle.shortcutOwner(sc) == "Second")

        first.close()
        #expect(handle.registerShortcut(sc) { _, _ in } == .failure(.notRunning))
        second.drain()
        second.close()
        #expect(handle.shortcutOwner(sc) == nil)
    }

    @Test("Global handler does not deadlock calling registerShortcut on its own host (`host_handler_tests.rs:7`)")
    func globalHandlerDoesNotWaitForOwnHost() {
        let app = makeTestApp("SelfCall")
        let handle = app.handle()
        let rt = app.makeRuntime()
        let guardObj = ShortcutGuard.attach(shared: app.sharedHandle.shared, wake: Waker {}, headless: true)
        defer { guardObj.close() }

        let outer = chord("ctrl+alt+o")
        let inner = chord("ctrl+alt+i")
        _ = try! handle.registerShortcut(outer) { s, _ in
            _ = try! handle.registerShortcut(inner) { innerS, _ in innerS += 5 }.get()
            s += 1
        }.get()

        #expect(isSuccess(app.sharedHandle.shared.shortcuts.fire(outer)))
        guardObj.withReceiving {
            _ = app.sharedHandle.shared.applyStateUpdates(to: rt, at: 0.0)
        }
        #expect(isSuccess(app.sharedHandle.shared.shortcuts.fire(inner)))
        guardObj.withReceiving {
            _ = app.sharedHandle.shared.applyStateUpdates(to: rt, at: 0.016)
        }
        #expect(rt.state == 6)
    }

    @Test("Global handler runs only through its own guard receiving scope (`host_handler_tests.rs:42`)")
    func globalHandlerRunsOnlyThroughOwnGuard() {
        let app = makeTestApp("Guarded")
        let rt = app.makeRuntime()
        let woke = AtomicIntBox()
        let g = ShortcutGuard.attach(
            shared: app.sharedHandle.shared,
            wake: Waker { woke.add(1) },
            headless: true
        )
        defer { g.close() }

        let sc = chord("ctrl+alt+g")
        _ = try! app.handle().registerShortcut(sc) { s, _ in s += 1 }.get()
        #expect(isSuccess(app.sharedHandle.shared.shortcuts.fire(sc)))
        let wakesAfterFire = woke.get()

        // Draining without withReceiving re-queues rather than executing.
        _ = app.sharedHandle.shared.applyStateUpdates(to: rt, at: 0.0)
        #expect(rt.state == 0)
        #expect(woke.get() > wakesAfterFire)

        g.withReceiving {
            _ = app.sharedHandle.shared.applyStateUpdates(to: rt, at: 0.016)
        }
        #expect(rt.state == 1)
    }

    @Test("Closed wake stops firing after close and close does not wait on stuck wake (`closed_wake_tests.rs`)")
    func closedWakeTests() {
        let hits = AtomicIntBox()
        let (wrapped, closer) = ShortcutHostWake.make(Waker { hits.add(1) })
        wrapped.wake()
        #expect(hits.get() == 1)
        closer.close()
        wrapped.wake()
        #expect(hits.get() == 1)

        let app = makeTestApp("ClosedWake")
        let enteredWake = SignalChannel<Void>()
        let releaseWake = SignalChannel<Void>()
        let guardObj = ShortcutGuard.attach(
            shared: app.sharedHandle.shared,
            wake: Waker {
                enteredWake.send(())
                _ = releaseWake.receive()
            },
            headless: true
        )
        let handle = app.handle()
        let sc = chord("ctrl+alt+k")
        let answer = SignalChannel<Result<UInt32, ShortcutError>>()
        Thread {
            answer.send(handle.registerShortcut(sc) { _, _ in })
        }.start()

        #expect(enteredWake.receive() != nil)
        guardObj.close()
        releaseWake.send(())
        #expect(answer.receive() == .failure(.notRunning))
    }

    @Test("Generation interleavings protect newer host engine, presses, calls, and pause order (`generation_tests.rs`)")
    func generationInterleavingConcurrency() {
        let app = makeTestApp("PausedDrain")
        let control = app.sharedHandle.shared.shortcuts.control
        let aWoke = SignalChannel<Void>()
        let bWoke = SignalChannel<Void>()
        let paused = SignalChannel<Void>()
        let resume = SignalChannel<Void>()
        let drainDone = SignalChannel<Void>()
        let handle = app.handle()
        let sc = chord("ctrl+alt+f9")

        final class GuardHolder: @unchecked Sendable { var guardObj: ShortcutGuard? }
        let aHolder = GuardHolder()
        let pausedShared = app.sharedHandle.shared
        let aReady = SignalChannel<Void>()
        let runDrainOnA = SignalChannel<Void>()
        let finishA = SignalChannel<Void>()

        Thread {
            aHolder.guardObj = ShortcutGuard.attach(
                shared: pausedShared,
                wake: Waker { aWoke.send(()) },
                headless: true
            )
            aReady.send(())
            _ = runDrainOnA.receive()
            ShortcutTestHooks.setBeforeDequeue {
                paused.send(())
                _ = resume.receive()
            }
            aHolder.guardObj?.drain()
            drainDone.send(())
            _ = finishA.receive()
            aHolder.guardObj?.close()
        }.start()

        #expect(aReady.receive() != nil)
        let callRes = SignalChannel<Result<UInt32, ShortcutError>>()
        Thread {
            callRes.send(handle.registerShortcut(sc) { _, _ in })
        }.start()
        #expect(aWoke.receive() != nil)

        runDrainOnA.send(())
        #expect(paused.receive() != nil)

        let b = ShortcutGuard.attach(
            shared: app.sharedHandle.shared,
            wake: Waker { bWoke.send(()) },
            headless: true
        )
        resume.send(())
        #expect(drainDone.receive() != nil)
        #expect(bWoke.receive() != nil)

        b.drain()
        #expect((try? callRes.receive()?.get()) != nil)
        #expect(control.currentGeneration == b.generation)

        let orderBox = SignalChannel<Int>()
        let pressApp = makeTestApp("PressOrder")
        let shared = pressApp.sharedHandle.shared
        let gOld = ShortcutGuard.attach(shared: shared, wake: Waker {}, headless: true)
        let gNew = ShortcutGuard.attach(shared: shared, wake: Waker {}, headless: true)

        let x = chord("ctrl+alt+f10")
        let y = chord("ctrl+alt+f11")
        _ = try! pressApp.handle().registerShortcut(x) { s, _ in
            orderBox.send(1)
            s = 1
        }.get()
        _ = try! pressApp.handle().registerShortcut(y) { s, _ in
            orderBox.send(2)
            s = s * 10 + 2
        }.get()

        #expect(isSuccess(shared.shortcuts.fire(x)))
        #expect(isSuccess(shared.shortcuts.fire(y)))

        let rtOld = pressApp.makeRuntime()
        gOld.withReceiving {
            _ = shared.applyStateUpdates(to: rtOld, at: 0.0)
        }
        #expect(rtOld.state == 0)

        let rtNew = pressApp.makeRuntime()
        gNew.withReceiving {
            _ = shared.applyStateUpdates(to: rtNew, at: 0.016)
        }
        #expect(rtNew.state == 12)
        #expect(orderBox.receive() == 1)
        #expect(orderBox.receive() == 2)

        gOld.close()
        gNew.close()
        b.close()
        finishA.send(())
    }

    @Test("Shortcut pressed before launch runs before updates queued after it (`window/tests.rs:520`)")
    func shortcutPressedBeforeLaunchRunsBeforeLaterUpdates() {
        let app = makeTestApp("PreLaunchOrder")
        let shared = app.sharedHandle.shared
        let rt = app.makeRuntime()
        let guardObj = ShortcutGuard.attach(shared: shared, wake: Waker {}, headless: true)
        defer { guardObj.close() }

        let sc = chord("ctrl+alt+f12")
        _ = try! app.handle().registerShortcut(sc) { s, _ in
            s = s * 10 + 1
        }.get()
        #expect(isSuccess(shared.shortcuts.fire(sc)))
        app.handle().update { s, _ in
            s = s * 10 + 2
        }

        guardObj.drain()
        guardObj.withReceiving {
            _ = shared.applyStateUpdates(to: rt, at: 0.0)
        }
        #expect(rt.state == 12)
    }

    @Test("Call that finishes after its host closed wakes nothing (`closed_wake_tests.rs:21`)")
    func callThatFinishesAfterHostClosedWakesNothing() {
        let app = makeTestApp("ClosedBeforeWake")
        let wakes = AtomicIntBox()
        let guardObj = ShortcutGuard.attach(
            shared: app.sharedHandle.shared,
            wake: Waker { wakes.add(1) },
            headless: true
        )
        let paused = SignalChannel<Void>()
        let resumed = SignalChannel<Void>()
        let answer = SignalChannel<String?>()
        let handle = app.handle()
        let sc = chord("ctrl+alt+f19")

        Thread {
            ShortcutTestHooks.setBeforeWake {
                paused.send(())
                _ = resumed.receive()
            }
            answer.send(handle.shortcutOwner(sc))
        }.start()

        #expect(paused.receive() != nil)
        guardObj.close()
        let atClose = wakes.get()
        resumed.send(())
        let ownerResult = answer.receive()
        #expect(ownerResult == .some(nil))
        #expect(wakes.get() == atClose)
    }

    @Test("Press wakes its own host and never a closed window (`closed_wake_tests.rs:115`)")
    func pressWakesItsOwnHostAndNeverClosedWindow() {
        final class SinkBox: @unchecked Sendable {
            var sink: ShortcutSink?
        }
        let sinkBox = SinkBox()
        let capture: ShortcutConnectFn = { _, sink in
            sinkBox.sink = sink
            return .success(MockBackendDriver())
        }

        let app = makeTestApp("Pressed")
        let shared = app.sharedHandle.shared
        let firstWakes = AtomicIntBox()
        let firstWake = Waker { firstWakes.add(1) }
        shared.setWaker(firstWake)
        let first = ShortcutGuard.attachWith(shared: shared, wake: firstWake, headless: false, connect: capture)
        _ = try! app.handle().registerShortcut(chord("ctrl+alt+f13")) { _, _ in }.get()
        let press = sinkBox.sink
        #expect(press != nil)

        let secondWakes = AtomicIntBox()
        let secondWake = Waker { secondWakes.add(1) }
        shared.setWaker(secondWake)
        let second = ShortcutGuard.attachWith(shared: shared, wake: secondWake, headless: false, connect: capture)
        second.close()

        let firstBefore = firstWakes.get()
        let secondBefore = secondWakes.get()
        press?(1, nil)
        #expect(secondWakes.get() == secondBefore)
        #expect(firstWakes.get() == firstBefore + 1)
        #expect(shared.drain().orderedUpdates.count == 1)

        first.close()
        press?(1, nil)
        #expect(firstWakes.get() == firstBefore + 1)
        #expect(shared.drain().orderedUpdates.isEmpty)
    }

    @Test("Replaced engine presses are discarded not kept (`generation_tests.rs:337`)")
    func replacedEnginesPressesAreDiscardedNotKept() {
        final class AwayState: @unchecked Sendable {
            var guardObj: ShortcutGuard?
            var rt: Runtime<Int>?
        }
        final class AwayRunner: @unchecked Sendable {
            private let lock = NSLock()
            private let cond = NSCondition()
            private var queue: [@Sendable (AwayState) -> Void] = []
            private var closed = false
            private let doneSem = DispatchSemaphore(value: 0)

            init() {
                Thread {
                    let state = AwayState()
                    while true {
                        self.cond.lock()
                        while self.queue.isEmpty && !self.closed {
                            self.cond.wait()
                        }
                        if self.queue.isEmpty && self.closed {
                            self.cond.unlock()
                            break
                        }
                        let step = self.queue.removeFirst()
                        self.cond.unlock()
                        step(state)
                    }
                    state.guardObj?.close()
                    state.guardObj = nil
                    state.rt = nil
                    self.doneSem.signal()
                }.start()
            }

            func run<T: Sendable>(_ body: @escaping @Sendable (AwayState) -> T) -> T {
                let ch = SignalChannel<T>()
                cond.lock()
                queue.append { state in
                    ch.send(body(state))
                }
                cond.signal()
                cond.unlock()
                return ch.receive()!
            }

            func finish() {
                cond.lock()
                closed = true
                cond.signal()
                cond.unlock()
                _ = doneSem.wait(timeout: .now() + 10.0)
            }
        }

        let app = makeTestApp("Replaced")
        let shared = app.sharedHandle.shared
        let a = AwayRunner()
        let (genA, liveA) = a.run { st -> (UInt64, ShortcutLiveToken?) in
            let g = ShortcutGuard.attach(shared: shared, wake: Waker {}, headless: true)
            st.guardObj = g
            st.rt = App<Int>(title: "Replaced", size: Vec2(40, 40), state: 0) { _, _ in el() }.makeRuntime()
            return (g.generation, g.liveToken)
        }
        #expect(liveA != nil)
        let delivery = ShortcutDelivery<Int>(shared: shared, generation: genA, wake: Waker {}, live: liveA!)
        let press = makeShortcutSink(delivery: delivery)

        let b = ShortcutGuard.attach(shared: shared, wake: Waker {}, headless: true)
        let rtB = app.makeRuntime()
        for n in 0..<50 {
            press(UInt32.max - 3, nil)
            if n % 2 == 0 {
                b.withReceiving {
                    _ = shared.applyStateUpdates(to: rtB, at: Double(n) * 0.016)
                }
            } else {
                a.run { st in
                    if let g = st.guardObj, let rtA = st.rt {
                        g.withReceiving {
                            _ = shared.applyStateUpdates(to: rtA, at: Double(n) * 0.016)
                        }
                    }
                }
            }
            #expect(delivery.pressedCount == 0)
            #expect(shared.drain().orderedUpdates.isEmpty)
        }
        let aState = a.run { $0.rt?.state ?? -1 }
        #expect(aState == 0)
        #expect(rtB.state == 0)
        b.close()
        a.finish()
    }

    @Test("Outgoing close leaves newer host engine and handlers alone (`generation_tests.rs:197`)")
    func outgoingCloseLeavesNewerHostEngineAndHandlersAlone() {
        enum CloseStep: CaseIterable {
            case aClosesRouting, aReleasesEngine, aEnds
            case bInstalls, bRoutes, bRegisters
        }
        func interleavings(_ left: [CloseStep], _ right: [CloseStep]) -> [[CloseStep]] {
            if left.isEmpty { return [right] }
            if right.isEmpty { return [left] }
            var out: [[CloseStep]] = []
            for tail in interleavings(Array(left.dropFirst()), right) {
                out.append([left[0]] + tail)
            }
            for tail in interleavings(left, Array(right.dropFirst())) {
                out.append([right[0]] + tail)
            }
            return out
        }

        final class HostSlot: @unchecked Sendable {
            var guardObj: ShortcutGuard?
            var attaching: ShortcutAttaching?
            var closing: ShortcutClosing?
        }
        final class PlaceRunner: @unchecked Sendable {
            private let away: Bool
            private let local = HostSlot()
            private let cond = NSCondition()
            private var queue: [@Sendable (HostSlot) -> Void] = []
            private var stopped = false
            private let doneSem = DispatchSemaphore(value: 0)

            init(away: Bool) {
                self.away = away
                if away {
                    Thread {
                        let slot = HostSlot()
                        while true {
                            self.cond.lock()
                            while self.queue.isEmpty && !self.stopped {
                                self.cond.wait()
                            }
                            if self.queue.isEmpty && self.stopped {
                                self.cond.unlock()
                                break
                            }
                            let step = self.queue.removeFirst()
                            self.cond.unlock()
                            step(slot)
                        }
                        slot.attaching = nil
                        slot.closing = nil
                        slot.guardObj?.close()
                        slot.guardObj = nil
                        self.doneSem.signal()
                    }.start()
                }
            }

            @discardableResult
            func run<T: Sendable>(_ body: @escaping @Sendable (HostSlot) -> T) -> T {
                if !away {
                    return body(local)
                }
                let ch = SignalChannel<T>()
                cond.lock()
                queue.append { ch.send(body($0)) }
                cond.signal()
                cond.unlock()
                return ch.receive()!
            }

            func finish() {
                if !away {
                    local.attaching = nil
                    local.closing = nil
                    local.guardObj?.close()
                    local.guardObj = nil
                    return
                }
                cond.lock()
                stopped = true
                cond.signal()
                cond.unlock()
                _ = doneSem.wait(timeout: .now() + 10.0)
            }
        }

        let live0 = AtomicIntBox()
        let live1 = AtomicIntBox()
        let connect0: ShortcutConnectFn = { _, _ in
            live0.add(1)
            return .success(MockBackendDriver(onDrop: { live0.add(-1) }))
        }
        let connect1: ShortcutConnectFn = { _, _ in
            live1.add(1)
            return .success(MockBackendDriver(onDrop: { live1.add(-1) }))
        }

        let aChord = chord("ctrl+alt+f14")
        let bChord = chord("ctrl+alt+f15")
        let dChord = chord("ctrl+alt+f16")
        let walks = interleavings([.aClosesRouting, .aReleasesEngine, .aEnds], [.bInstalls, .bRoutes, .bRegisters])

        var sawStale = false
        var sawCurrent = false
        for away in [false, true] {
            let replaces = !away
            for order in walks {
                #expect(live0.get() == 0 && live1.get() == 0)
                let app = makeTestApp("Successor")
                let handle = app.handle()
                let shared = app.sharedHandle.shared
                let place = PlaceRunner(away: away)

                let aID = place.run { slot -> UInt32 in
                    slot.guardObj = ShortcutGuard.attachWith(shared: shared, wake: Waker {}, headless: false, connect: connect0)
                    return try! handle.registerShortcut(aChord) { s, _ in s += 1 }.get()
                }
                var routed: Character? = "A"
                var aCurrent: Bool? = nil
                var aReleased = false
                var aEnded = false
                var bInstalled = false
                var bRouted = false
                var bRegistered = false
                var bID: UInt32? = nil
                var attachingB: ShortcutAttaching? = nil
                var guardB: ShortcutGuard? = nil

                func checkStep() {
                    let aAlive = !(bInstalled && replaces) && !aReleased
                    #expect(live0.get() == (aAlive ? 1 : 0))
                    #expect(live1.get() == (bRegistered ? 1 : 0))
                    let aCleared = aEnded && aCurrent == true
                    var want: [UInt32] = []
                    if !aCleared { want.append(aID) }
                    if let bID { want.append(bID) }
                    want.sort()
                    #expect(shared.shortcuts.handlers.sortedKeys == want)
                }

                checkStep()
                for step in order {
                    switch step {
                    case .aClosesRouting:
                        place.run { slot in
                            slot.closing = slot.guardObj?.closeRouting()
                        }
                        routed = nil
                        aCurrent = !bRouted
                    case .aReleasesEngine:
                        place.run { slot in
                            if var c = slot.closing {
                                slot.guardObj?.releaseEngine(&c)
                                slot.closing = c
                            }
                        }
                        aReleased = true
                    case .aEnds:
                        place.run { slot in
                            if let c = slot.closing {
                                slot.guardObj?.end(c)
                            }
                            slot.guardObj = nil
                        }
                        aEnded = true
                    case .bInstalls:
                        attachingB = ShortcutGuard.install(shared: shared, wake: Waker {}, headless: false, connect: connect1)
                        bInstalled = true
                    case .bRoutes:
                        guardB = attachingB?.route(shared: shared)
                        attachingB = nil
                        routed = "B"
                        bRouted = true
                    case .bRegisters:
                        let ans = handle.registerShortcut(bChord) { s, _ in s += 10 }
                        bRegistered = (routed == "B")
                        #expect(((try? ans.get()) != nil) == bRegistered)
                        bID = try? ans.get()
                    }
                    checkStep()
                }

                let fresh = handle.registerShortcut(dChord) { _, _ in }
                #expect(((try? fresh.get()) != nil) == (routed == "B"))
                if case .success = fresh {
                    #expect(handle.shortcutOwner(dChord) == "Successor")
                }
                if aCurrent == false { sawStale = true }
                if aCurrent == true { sawCurrent = true }
                guardB?.close()
                guardB = nil
                place.finish()
                #expect(shared.shortcuts.handlers.isEmpty)
                #expect(live0.get() == 0 && live1.get() == 0)
            }
        }
        #expect(sawStale && sawCurrent)
    }

    @Test("Host installed first but routed last runs its calls and activations (`generation_tests.rs:408`)")
    func hostInstalledFirstButRoutedLastRunsCallsAndActivations() {
        final class HostBox: @unchecked Sendable {
            var attaching: ShortcutAttaching?
            var guardObj: ShortcutGuard?
            var rt: Runtime<Int>?
        }
        final class ThreadHost: @unchecked Sendable {
            private let cond = NSCondition()
            private var queue: [@Sendable (HostBox) -> Void] = []
            private var stopped = false
            private let doneSem = DispatchSemaphore(value: 0)

            init() {
                Thread {
                    let box = HostBox()
                    while true {
                        self.cond.lock()
                        while self.queue.isEmpty && !self.stopped {
                            self.cond.wait()
                        }
                        if self.queue.isEmpty && self.stopped {
                            self.cond.unlock()
                            break
                        }
                        let work = self.queue.removeFirst()
                        self.cond.unlock()
                        work(box)
                    }
                    box.attaching = nil
                    box.guardObj?.close()
                    box.guardObj = nil
                    box.rt = nil
                    self.doneSem.signal()
                }.start()
            }

            func post(_ body: @escaping @Sendable (HostBox) -> Void) {
                cond.lock()
                queue.append(body)
                cond.signal()
                cond.unlock()
            }

            func run<T: Sendable>(_ body: @escaping @Sendable (HostBox) -> T) -> T {
                let ch = SignalChannel<T>()
                post { ch.send(body($0)) }
                return ch.receive()!
            }

            func finish() {
                cond.lock()
                stopped = true
                cond.signal()
                cond.unlock()
                _ = doneSem.wait(timeout: .now() + 10.0)
            }
        }

        let liveA = AtomicIntBox()
        let liveB = AtomicIntBox()
        final class SinkSlot: @unchecked Sendable {
            var sinkA: ShortcutSink?
        }
        let sinkSlot = SinkSlot()
        let connectA: ShortcutConnectFn = { _, sink in
            liveA.add(1)
            sinkSlot.sinkA = sink
            return .success(MockBackendDriver(onDrop: { liveA.add(-1) }))
        }
        let connectB: ShortcutConnectFn = { _, _ in
            liveB.add(1)
            return .success(MockBackendDriver(onDrop: { liveB.add(-1) }))
        }

        let app = makeTestApp("Reversed")
        let shared = app.sharedHandle.shared
        let handle = app.handle()
        let key = shared.shortcuts.control.key
        let hostA = ThreadHost()
        let hostB = ThreadHost()

        hostA.run { box in
            box.rt = App<Int>(title: "Reversed", size: Vec2(40, 40), state: 0) { _, _ in el() }.makeRuntime()
            let wake = Waker {
                hostA.post { $0.guardObj?.drain() }
            }
            box.attaching = ShortcutGuard.install(shared: shared, wake: wake, headless: false, connect: connectA)
        }
        hostB.run { box in
            box.rt = App<Int>(title: "Reversed", size: Vec2(40, 40), state: 0) { _, _ in el() }.makeRuntime()
            let wake = Waker {
                hostB.post { $0.guardObj?.drain() }
            }
            box.attaching = ShortcutGuard.install(shared: shared, wake: wake, headless: false, connect: connectB)
        }

        // B routes first, then A routes last — routing must belong to A.
        hostB.run { box in
            box.guardObj = box.attaching?.route(shared: shared)
            box.attaching = nil
        }
        hostA.run { box in
            box.guardObj = box.attaching?.route(shared: shared)
            box.attaching = nil
        }

        let sc = chord("ctrl+alt+f17")
        let answer = SignalChannel<Result<UInt32, ShortcutError>>()
        Thread {
            answer.send(handle.registerShortcut(sc) { s, _ in s += 1 })
        }.start()

        let id = try! answer.receive()!.get()
        let heldOnA = hostA.run { _ in ThreadLocalEngines.holds(key: key, shortcut: sc) }
        let heldOnB = hostB.run { _ in ThreadLocalEngines.holds(key: key, shortcut: sc) }
        #expect(heldOnA)
        #expect(!heldOnB)

        sinkSlot.sinkA?(id, nil)
        let deliveredState = hostA.run { box -> Int in
            guard let g = box.guardObj, let rt = box.rt else { return -1 }
            g.withReceiving {
                _ = shared.applyStateUpdates(to: rt, at: 0.0)
            }
            return rt.state
        }
        #expect(deliveredState == 1)

        sinkSlot.sinkA = nil
        hostA.finish()
        hostB.finish()
        #expect(liveA.get() == 0 && liveB.get() == 0)
    }

    @Test("ShortcutHub.hasAppShortcuts stays true after ShortcutGuard.attach drains pending entries")
    func hasAppShortcutsStaysTrueAfterAttach() {
        let app = makeTestApp("WindowSpecShortcuts")
            .globalShortcut("ctrl+alt+w") { s, _ in s += 1 }
        let shared = app.sharedHandle.shared
        #expect(shared.shortcuts.hasPendingEntries)
        #expect(shared.shortcuts.hasAppShortcuts)

        let g1 = ShortcutGuard.attach(shared: shared, wake: Waker {}, headless: true)
        #expect(!shared.shortcuts.hasPendingEntries)
        #expect(shared.shortcuts.hasAppShortcuts)
        g1.close()
        #expect(shared.shortcuts.hasAppShortcuts)
    }
}
