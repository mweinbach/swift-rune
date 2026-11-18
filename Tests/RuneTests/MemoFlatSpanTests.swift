import Testing
@testable import Rune
import RuneMotion

@Suite("Flattened memo subtrees")
struct MemoFlatSpanTests {
    private struct Model {
        var tick = 0
        var prefix = false
        var inert = false
        var version = 0
        var taps = 0
    }

    private func make(_ reuse: Bool) -> Runtime<Model> {
        Runtime(state: Model(), viewport: Vec2(200, 90), pixelScale: 1, systemDark: true) { state, _ in
            func content() -> El<Model> {
                var stack: El<Model> = col().key("panel").clip(true)
                for i in 0..<10 {
                    let amount = state.version + 1
                    stack = stack.child(row().key("row-\(i)").size(120, 18).clip(true)
                        .child(text("row \(i)").key("label").size(36, 16))
                        .child(el().key("button").size(30, 16).onClick { $0.taps += amount }))
                }
                return stack
            }
            let panel = reuse ? memo("panel", deps: state.version) { content() } : content()
            var scrolled: El<Model> = col().key("list").scrollY().size(130, 65)
            if state.prefix { scrolled = scrolled.child(el().key("prefix").h(13)) }
            scrolled = scrolled.child(panel.inert(state.inert))
            return col().child(scrolled).child(el().key("banner").size(10, 9).bg(state.tick.isMultiple(of: 2) ? .white : .black))
        }
    }

    @Test("A retained subtree keeps current clip bounds, indices, handler values and pressed targets")
    func comparesToFreshDuringScrollAndUpdates() {
        let retained = make(true), fresh = make(false)
        var replayed = 0
        for step in 0..<12 {
            let t = Double(step + 1) / 60
            for rt in [retained, fresh] {
                rt.update(at: t) { s, tx in
                    s.tick += 1
                    if step == 4 { s.prefix = true }
                    if step == 5 { tx.scrollTo("list", offset: Vec2(0, 35), animated: false) }
                    if step == 7 { s.version += 1 }
                    if step == 9 { s.inert = true }
                }
                _ = rt.frame(at: t)
            }
            #expect(retained.elements() == fresh.elements())
            replayed = max(replayed, retained.replayedFlatMemoNodes)
            if step == 6 || step == 8 || step == 10 {
                for rt in [retained, fresh] {
                    rt.pointerDown(at: Vec2(46, 26), at: t)
                    rt.pointerUp(at: Vec2(46, 26), at: t)
                }
                #expect(retained.state.taps == fresh.state.taps)
            }
        }
        #expect(replayed == 30)
        #expect(retained.state.taps == 3)
    }

    @Test("A full rebuild replays only immutable virtual row roots and follows reordered keys")
    func immutableVirtualRootsDuringFullBuild() {
        final class Owner {}
        func make(_ reuse: Bool) -> Runtime<Int> {
            let owners = (0..<48).map { _ in Owner() }
            return Runtime(state: 0, viewport: Vec2(160, 100), pixelScale: 1) { _, _ in
                let rows: El<Int> = col().key("rows").wFull().virtualRows(
                    count: owners.count, estimatedRowHeight: 20,
                    key: { tick, i in "r\(tick >= 5 ? owners.count - 1 - i : i)" },
                    buildContent: { tick, i in
                        let id = tick >= 5 ? owners.count - 1 - i : i
                        let row: El<Int> = memo("item-\(id)", deps: 0) {
                            col().wFull().h(20).child(text("Row \(id)").key("text").size(90, 15))
                        }
                        // A new root modifier can share the original memo's child storage.
                        if id.isMultiple(of: 3) { return VirtualRowContent(row.h(tick.isMultiple(of: 2) ? 20 : 26)) }
                        return reuse ? VirtualRowContent(memoized: row, owner: owners[id]) : VirtualRowContent(row)
                    })
                return col().sizeFull().scrollY().child(rows)
            }
        }
        let retained = make(true), fresh = make(false)
        var replayed = 0
        for step in 0..<10 {
            let now = Double(step) / 60
            for rt in [retained, fresh] {
                rt.update(at: now) { tick, _ in tick = step }
                _ = rt.renderFrame(at: now)
            }
            #expect(retained.elements() == fresh.elements())
            #expect(retained.lastCommittedSpecs == fresh.lastCommittedSpecs)
            #expect(retained.accessibilitySnapshot() == fresh.accessibilitySnapshot())
            #expect(fresh.replayedVirtualFlatRoots == 0)
            replayed = max(replayed, retained.replayedVirtualFlatRoots)
        }
        #expect(replayed > 0)
    }

    @Test("Layout-equivalent row variants refresh selection, accessibility and handlers across a full build")
    func virtualRowLayoutVariants() throws {
        struct State { var active = false; var height: Float = 22; var reported: Bool? }
        final class Context {}
        func build(_ share: Bool) -> Runtime<State> {
            Runtime(state: State(), viewport: Vec2(180, 112), pixelScale: 1) { _, _ in
                let rows: El<State> = col().key("rows").wFull().virtualRows(
                    count: 30, estimatedRowHeight: 22, key: { _, i in "r-\(i)" }, buildContent: { state, i in
                        let active = state.active, height = state.height
                        return memoizedVirtualRow("r-\(i)", deps: height, variant: active, variantsShareLayout: share,
                                                 makeContext: { Context() }, updateContext: { _ in }) { _ in
                            var label: El<State> = text("line \(i)").key("label-\(i)").size(90, height)
                            if active { label = label.selectable() }
                            return row().wFull().h(height).label(active ? "active" : "inactive")
                                .child(label)
                                .child(el().key("tap-\(i)").size(50, height).onClick { $0.reported = active })
                        }
                    })
                return col().size(180, 112).scrollY().child(rows)
            }
        }
        let shared = build(true), independent = build(false)
        for step in 0..<4 {
            let active = step % 2 != 0, height: Float = step == 3 ? 28 : 22
            let time = Double(step) / 30
            for rt in [shared, independent] {
                rt.update(at: time) { state, _ in state.active = active; state.height = height }
                _ = rt.renderFrame(at: time)
            }
            #expect(shared.elements() == independent.elements())
            #expect(shared.accessibilitySnapshot() == independent.accessibilitySnapshot())
            if step == 1 || step == 2 { #expect(shared.retainedLayout.reusedVirtualRowRootCount > 0) }
            let leaf = try #require(shared.flatNodes.first { $0.key == "label-0" })
            #expect(leaf.el.isSelectable == active)
            #expect(leaf.targetRect.height == height)
            let rect = try #require(shared.element(byKey: "tap-0")).rect
            let point = Vec2(rect[0] + 5, rect[1] + 5)
            for rt in [shared, independent] {
                rt.pointerMove(to: point, at: time)
                rt.pointerDown(at: point, at: time)
                rt.pointerUp(at: point, at: time + 0.001)
                #expect(rt.state.reported == active)
            }
        }
    }

    @Test("Duplicate virtual row memos retain fresh root modifiers on either copy variant")
    func duplicateLayoutVariants() throws {
        final class Context {}
        let view = Runtime(state: 0, viewport: Vec2(100, 100), pixelScale: 1) { _, _ in
            let rows: El<Int> = col().key("rows").wFull().virtualRows(
                count: 1, estimatedRowHeight: 20, key: { _, _ in "r" }, buildContent: { tick, _ in
                    let base: El<Int> = memo("shell", deps: 0) { col().wFull().child(text("same child").h(12)) }
                    func variant(height: Float) -> VirtualRowContent<Int> {
                        memoizedVirtualRow("duplicate", deps: 0, variant: (tick / 2) % 2 != 0, variantsShareLayout: true,
                                           makeContext: { Context() }, updateContext: { _ in }) { _ in base.h(height) }
                    }
                    _ = variant(height: 14)
                    return variant(height: Float(20 + tick))
                })
            return col().size(100, 100).scrollY().child(rows)
        }
        for tick in 0..<7 {
            let time = Double(tick) / 30
            view.update(at: time) { state, tx in state = tick; tx.instant() }
            _ = view.renderFrame(at: time)
            let rect = try #require(view.element(byKey: "r")).rect
            #expect(rect[3] == Float(20 + tick))
        }
    }

    @Test("Row layout variants preserve measured geometry and author transform calls")
    func layoutVariantReads() {
        final class Context {}
        final class Reads { var byVariant = [0, 0] }
        struct Model { var active = false; var reference: Float = 12 }
        func make(_ share: Bool, _ reads: Reads) -> Runtime<Model> {
            Runtime(state: Model(), viewport: Vec2(100, 100), pixelScale: 1) { model, cx in
                let context = cx
                let rows: El<Model> = col().key("rows").wFull().virtualRows(
                    count: 1, estimatedRowHeight: 20, key: { _, _ in "row" }, buildContent: { model, _ in
                        memoizedVirtualRow("row", deps: 0, variant: model.active, variantsShareLayout: share,
                                           makeContext: { Context() }, updateContext: { _ in }) { _ in
                            let height: Float = context.layoutWith("reference") { rect in
                                reads.byVariant[model.active ? 1 : 0] += 1
                                return rect[2]
                            } ?? 12
                            return col().wFull().child(el().key("sized").size(10, height))
                        }
                    })
                return col().size(100, 100).scrollY().child(el().key("reference").size(model.reference, 1)).child(rows)
            }
        }
        let sharedReads = Reads(), ordinaryReads = Reads()
        let shared = make(true, sharedReads), ordinary = make(false, ordinaryReads)
        let widths: [Float] = [12, 12, 12, 12, 24, 15]
        for (i, width) in widths.enumerated() {
            let time = Double(i) / 30
            for view in [shared, ordinary] {
                view.update(at: time) { model, tx in
                    model.active = !i.isMultiple(of: 2)
                    model.reference = width
                    tx.instant()
                }
                _ = view.renderFrame(at: time)
                #expect(view.element(byKey: "sized")?.rect[3] == width)
            }
            if i < 4 { #expect(sharedReads.byVariant == ordinaryReads.byVariant) }
        }
    }

    @Test("Reordered memo descendants retain observer identities and honor the current modal")
    func observerRolesFollowMovedRows() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(160, 80), pixelScale: 1) { tick, _ in
            let left = memo("left-panel", deps: 0) { () -> El<Int> in
                row().child(el().key("watch-layout").size(12, 9).onLayout { _, _ in })
            }
            let replaced = tick >= 7
            let right = memo("right-panel", deps: replaced) { () -> El<Int> in
                let child: El<Int> = el().key("watch-selection").size(12, 9)
                return row().child(replaced
                    ? child.onLayout { _, _ in }
                    : child.onVisible { _, _, _ in }.onSelectionChange { _, _, _ in })
            }
            var body: El<Int> = col()
            if tick < 4 { body = body.child(left).child(right) }
            else { body = body.child(right).child(left) }
            if tick == 5 { body = body.child(el().key("modal").size(12, 9).modal()) }
            return body
        }
        for tick in 0..<9 {
            let time = Double(tick + 1) / 60
            rt.update(at: time) { state, _ in state = tick }
            _ = rt.frame(at: time)
            func keys(_ indices: [Int]) -> [String] { indices.compactMap { rt.flatNodes[$0].key } }
            let visible = tick < 7 ? ["watch-selection"] : []
            let layout = tick < 7 ? ["watch-layout"] : ["watch-selection", "watch-layout"]
            #expect(keys(rt.layoutObservers.laidOut) == layout)
            #expect(keys(rt.layoutObservers.visible) == visible)
            #expect(keys(rt.layoutObservers.selectionChanges) == (tick == 5 ? [] : visible))
            if (4...6).contains(tick) { #expect(rt.replayedFlatMemoNodes == 2) }
        }
    }

    @Test("Surviving indexed row roots preserve clipped geometry, root motion and inherited RTL",
          arguments: [false, true], [(TxCommit.instant, false), (.animate, false), (.unprompted, false),
                                      (.instant, true), (.animate, true), (.unprompted, true)])
    func retainedIndexedRoots(rtl: Bool, mode: (TxCommit, Bool)) {
        let (commit, growth) = mode
        func make() -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(200, 120), pixelScale: 1) { version, _ in
                let list: El<Int> = col().key("items").wFull().virtualRows(count: 1_000, estimatedRowHeight: 20,
                    key: { _, i in "r-\(i)" }, build: { _, i in
                        let inner: El<Int> = row().key("inner").size(110, 16).clip(true)
                            .child(el().key("left").size(19, 13)).child(el().key("right").size(31, 13))
                        let root = col().size(version == 0 ? 120 : 94, 20).clip(true)
                            .child(inner).enterDelay(0.12)
                        let observed = version == 1 ? root.onLayout { _, _ in }.onVisible { _, _, _ in } : root
                        return i.isMultiple(of: 4) ? observed.press(.white) : observed
                    })
                let panel = col().key("clip").size(150, 94).clip(true).child(
                    col().key("scroll").size(150, 120).scrollY().child(growth ? list.growth(.default) : list))
                return rtl ? panel.dir(.rtl) : panel
            }
        }
        let retained = make(), fresh = make()
        func rows() -> Set<String> {
            Set(retained.flatNodes.compactMap { $0.key?.hasPrefix("r-") == true ? $0.key : nil })
        }
        _ = retained.renderFrame(at: 0)
        _ = fresh.renderFrame(at: 0)
        for step in 1...9 {
            let previous = rows()
            let t = Double(step) / 30
            for runtime in [retained, fresh] {
                runtime.wheel(WheelEvent(dx: 0, dy: -160), at: Vec2(65, 70), now: t)
                if step == 5 || step == 6 { runtime.update(at: t) { state, _ in state += 1 } }
                if runtime === fresh { runtime.invalidate(at: t) }
                runtime.pendingCommitKind = commit
                _ = runtime.renderFrame(at: t)
            }
            #expect(retained.elements() == fresh.elements())
            #expect(retained.lastCommittedSpecs == fresh.lastCommittedSpecs)
            #expect(retained.layoutObservers.laidOut == fresh.layoutObservers.laidOut)
            #expect(retained.layoutObservers.visible == fresh.layoutObservers.visible)
            #expect(retained.flatNodes.map(\.clipRect) == fresh.flatNodes.map(\.clipRect))
            #expect(retained.flatNodes.map(\.staticBounds) == fresh.flatNodes.map(\.staticBounds))
            if step == 5 { #expect(!retained.layoutObservers.laidOut.isEmpty) }
            if step == 3 || step == 4 || step == 9 {
                let ordinary = previous.intersection(rows()).filter {
                    Int($0.dropFirst(2)).map { !$0.isMultiple(of: 4) } == true
                }
                #expect(!ordinary.isEmpty)
                #expect(retained.replayedVirtualFlatRoots == ordinary.count)
            }
        }
    }

    @Test("Moving growth rows keep their natural and clamped geometry during a wheel remount")
    func activeGrowthRemount() {
        func make() -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(200, 120), pixelScale: 1) { state, _ in
                col().sizeFull().scrollY().child(col().key("rows").wFull().growth(.default).virtualRows(
                    count: 1_000, estimatedRowHeight: 20, key: { _, i in "r-\(i)" }, build: { _, i in
                        col().wFull().h(state > 0 && i.isMultiple(of: 3) ? 45 : 20).child(el().size(12, 12))
                    }))
            }
        }
        let retained = make(), fresh = make()
        _ = retained.renderFrame(at: 0)
        _ = fresh.renderFrame(at: 0)
        var movingRemounts = 0
        for step in 1...16 {
            let t = Double(step) / 60
            for runtime in [retained, fresh] {
                if step == 9 {
                    runtime.update(at: t) { state, _ in state += 1 }
                } else {
                    runtime.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(60, 70), now: t)
                }
                if runtime === fresh { runtime.invalidate(at: t) }
                runtime.pendingCommitKind = .animate
                _ = runtime.renderFrame(at: t)
            }
            #expect(retained.elements() == fresh.elements())
            #expect(retained.lastCommittedSpecs == fresh.lastCommittedSpecs)
            if step == 8 { #expect(retained.replayedVirtualFlatRoots > 0) }
            if step > 9, retained.growthRows.values.contains(where: { $0.track.moving }) {
                movingRemounts += 1
                #expect(retained.replayedVirtualFlatRoots == 0)
            }
        }
        #expect(movingRemounts > 0)
    }

    @Test("Changing a memo root to screen travel reparents its descendants in the motion scene")
    func changedRootSceneIdentity() {
        func runtime(_ cached: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(160, 80), pixelScale: 1, systemDark: true) { tick, _ in
                func body() -> El<Int> { row().key("panel").child(el().key("child").size(12, 9)) }
                var panel = cached ? memo("panel", deps: 0) { body() } : body()
                if tick >= 4 { panel = panel.animateLayout(LayoutAnim(spring: MotionTokens.DEFAULT, travel: .screen)) }
                return row().child(el().w(19)).child(panel)
            }
        }
        let retained = runtime(true), fresh = runtime(false)
        for step in 0..<7 {
            let t = Double(step + 1) / 60
            for rt in [retained, fresh] {
                rt.update(at: t) { s, _ in s = step }
                _ = rt.frame(at: t)
            }
            #expect(retained.elements() == fresh.elements())
            if step == 3 { #expect(retained.replayedFlatMemoNodes == 1) }
            if step == 4 { #expect(retained.replayedFlatMemoNodes == 0) }
        }
    }

    @Test("A replayed sticky gutter places overlays against its child after scrolling")
    func stickyDescendantAnchor() throws {
        func runtime(retained: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1, systemDark: true) { _, _ in
                func content() -> El<Int> {
                    row().key("content").size(800, 40).shrink(0)
                        .child(row().key("gutter").size(90, 40).stickyLeft(8)
                            .child(el().key("trigger").size(30, 18)))
                }
                let contentRow = retained ? memo("content", deps: 0) { content() } : content()
                return col().size(240, 120)
                    .child(col().key("scroll").size(240, 60).scrollX().child(contentRow))
                    .child(el().key("popup").size(40, 20).anchored("trigger", side: .bottom, align: .start, gap: 2))
            }
        }
        let retained = runtime(retained: true), fresh = runtime(retained: false)
        for (step, offset) in [0, 0, 80, 80, 210, 210].enumerated() {
            let now = Double(step + 1) / 30
            for rt in [retained, fresh] {
                rt.update(at: now) { state, tx in
                    state += 1
                    tx.scrollToInstant("scroll", x: Float(offset), y: 0)
                }
                _ = rt.renderFrame(at: now)
            }
            #expect(retained.elements() == fresh.elements())
            if step == 3 || step == 5 {
                #expect(retained.replayedFlatMemoNodes == 2)
                let gutter = try #require(retained.element(byKey: "gutter"))
                let popup = try #require(retained.element(byKey: "popup")?.committedLayoutTarget)
                #expect(gutter.stuck == Float(offset) + 8)
                #expect(popup.x == 8)
            }
        }
    }
}
