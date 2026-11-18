import Testing
@testable import Rune
import RuneMotion

@Suite("Retained memo layout")
struct MemoLayoutSpanTests {
    private struct State {
        var tick = 0
        var move = false
        var edit = TextEdit("old")
    }

    /// A recursive card tree with text at every leaf. Its parent may move or resize it.
    private func card(_ depth: Int, _ id: Int) -> El<State> {
        if depth == 0 { return text("Label \(id)").key("label").font(TextStyle(size: 12)) }
        var branch: El<State> = col().wFull()
        for index in 0..<3 { branch = branch.child(card(depth - 1, id * 3 + index).key("item-\(index)")) }
        return branch
    }

    private func sameGeometry(_ a: LayoutEngine.ResultNode, _ b: LayoutEngine.ResultNode) -> Bool {
        a.layout.localRect == b.layout.localRect && a.layout.contentSize == b.layout.contentSize &&
            a.children.count == b.children.count && zip(a.children, b.children).allSatisfy(sameGeometry)
    }

    @Test("Screen travel changes only its own identity under a keyed root")
    func descendantsKeepAuthoredPathHashes() {
        let layout = RetainedLayoutCoordinator()
        let texts = RetainedLayoutCoordinator.TextLayoutCollector()
        let panel: El<State> = col().key("panel")
            .animateLayout(LayoutAnim(spring: MotionTokens.DEFAULT, travel: .screen))
            .child(text("first").key("same/key")).child(text("second").key("same/key"))
            .child(text("index"))
        let root: El<State> = col().key("café/root").child(panel)
        _ = layout.compute(root: root, state: State(), viewport: Vec2(180, 90),
                           pixelScale: 1, textSystem: TextSystem(), textLayouts: texts)
        let prefix = "/@café/root/@panel"
        let labels = Set(["@same/key", "@same/key#dup1", "2"].map { NodeId.hash("\(prefix)/\($0)") })
        #expect(Set(texts.map.keys) == labels)
        #expect(texts.liveIds == labels.union([NodeId.hash("/@café/root"), NodeId.hash("screen:@panel")]))
    }

    @Test("A memo moved between byte-distinct Unicode paths transfers its current text identities")
    func canonicallyEquivalentPathsRekeyRetainedText() {
        let layout = RetainedLayoutCoordinator()
        let textSystem = TextSystem()
        let cache = MemoCache()
        let panel = cache.getOrBuild(id: "panel", deps: 0) { () -> El<State> in
            let inner = cache.getOrBuild(id: "inner", deps: 0) { () -> El<State> in
                col().child(text("label").key("label"))
            }.element
            return col().child(inner)
        }.element
        for (root, wrapper) in [("é", "á"), ("e\u{301}", "á"), ("e\u{301}", "a\u{301}"), ("é", "á")] {
            let tree: El<State> = col().key(root).child(col().key(wrapper).child(panel))
            let texts = RetainedLayoutCoordinator.TextLayoutCollector()
            _ = layout.compute(root: tree, state: State(), viewport: Vec2(180, 90),
                               pixelScale: 1, textSystem: textSystem, textLayouts: texts)
            let label = NodeId.hash("/@\(root)/@\(wrapper)/@panel/@inner/@label")
            #expect(Set(texts.map.keys) == [label])
            #expect(texts.liveIds.contains(label))
        }
    }

    @Test("Runtime elements report the current bytes after a memo changes ancestors")
    func movedMemoReportsCurrentElementPath() throws {
        let cache = MemoCache()
        let panel = cache.getOrBuild(id: "panel", deps: 0) { () -> El<Int> in
            col().child(text("label").key("label"))
        }.element
        let roots = ["é", "e\u{301}", "é"]
        let rt = Runtime<Int>(state: 0, viewport: Vec2(180, 90), pixelScale: 1) { step, _ in
            col().key(roots[step]).child(panel)
        }
        for step in roots.indices {
            let t = Double(step) / 30
            rt.update(at: t) { state, _ in state = step }
            _ = rt.frame(at: t)
            let label = try #require(rt.elements().first { !$0.exiting && $0.key == "label" })
            let path = "/@\(roots[step])/@panel/@label"
            #expect(label.path.utf8.elementsEqual(path.utf8))
        }
    }

    @Test("Unchanged descendants transfer their slots across resize and reparent, and keep current text layouts")
    func transferAcrossLayoutPasses() {
        let cache = MemoCache()
        let layout = RetainedLayoutCoordinator()
        let oracle = RetainedLayoutCoordinator()
        let textSystem = TextSystem()
        let state = State()
        let size = Vec2(540, 480)
        var expectedChildren = 0
        func tree(_ step: Int, memoized: Bool) -> El<State> {
            var cards: El<State> = col().key("cards").w(step >= 2 ? 90 : 150)
            for id in 0..<9 {
                let key = "card-\(id)"
                let body = memoized ? cache.getOrBuild(id: key, deps: id) { card(4, id) }.element : card(4, id).key(key)
                cards = cards.child(body)
            }
            let lead: El<State> = el().key("lead").h(Float(10 + step))
            if step == 3 {
                return col().key("new-root").child(lead).child(col().key("parent").child(cards))
            }
            return col().key("root").child(lead).child(cards)
        }
        for step in 0...3 {
            let texts = RetainedLayoutCoordinator.TextLayoutCollector()
            let expectedTexts = RetainedLayoutCoordinator.TextLayoutCollector()
            let result = layout.compute(root: tree(step, memoized: true), state: state, viewport: size,
                                        pixelScale: 1, textSystem: textSystem, textLayouts: texts)
            let expected = oracle.compute(root: tree(step, memoized: false), state: state, viewport: size,
                                          pixelScale: 1, textSystem: textSystem, textLayouts: expectedTexts)
            #expect(sameGeometry(result, expected))
            #expect(texts.liveIds == expectedTexts.liveIds)
            #expect(Set(texts.map.keys) == Set(expectedTexts.map.keys))
            #expect(texts.map.count == 729)
            if step == 0 { expectedChildren = texts.liveIds.count - 3 - 9 }
            else { #expect(layout.reusedMemoNodeCount == expectedChildren) }
        }
    }

    @Test("A rebuilt parent memo retains nested spans through ancestor moves")
    func changedOuterMemoReusesInnerDescendants() {
        let cache = MemoCache()
        let layout = RetainedLayoutCoordinator()
        let textSystem = TextSystem()
        for step in 0..<5 {
            let version = [0, 0, 1, 1, 2][step]
            let outer = cache.getOrBuild(id: "outer", deps: version) { () -> El<State> in
                let inner = cache.getOrBuild(id: "inner", deps: 0) { card(3, 1) }.element
                return col().child(inner).child(text("counter \(version)"))
            }.element
            let root: El<State> = step >= 3 ? col().child(text("moved")).child(row().child(outer)) : col().child(outer)
            _ = layout.compute(root: root, state: State(), viewport: Vec2(180, 180), pixelScale: 1, textSystem: textSystem)
            if step == 2 || step == 4 { #expect(layout.reusedMemoNodeCount == 39) }
            if step == 1 || step == 3 { #expect(layout.reusedMemoNodeCount == 41) }
        }
    }

    @Test("Nested memo geometry and text survive sibling shifts and compaction")
    func shiftedNestedSpansKeepRelativeGeometry() {
        let cache = MemoCache()
        let layout = RetainedLayoutCoordinator()
        let textSystem = TextSystem()

        func tree(prefix: Int, version: Int, reparent: Bool, useMemo: Bool) -> El<State> {
            func panel(_ id: Int) -> El<State> {
                let key = "panel-\(id)"
                func content() -> El<State> {
                    col().w(id == 1 ? 55 : 89)
                        .child(text("its own wrapping label \(id) remains attached").key("label"))
                        .child(row().key("row").child(el().size(Float(5 + id), 7)))
                }
                return useMemo ? cache.getOrBuild(id: key, deps: 0, build: content).element : content().key(key)
            }
            func body() -> El<State> {
                let first = panel(version.isMultiple(of: 2) ? 1 : 2)
                let second = panel(version.isMultiple(of: 2) ? 2 : 1)
                return col().child(first).child(text("version \(version)").key("version")).child(second)
            }
            let outer = useMemo ? cache.getOrBuild(id: "outer", deps: version, build: body).element : body().key("outer")
            var tree: El<State> = col().key(reparent ? "new-root" : "root")
            for index in 0..<prefix { tree = tree.child(el().key("prefix-\(index)").h(Float(index % 3))) }
            return tree.child(reparent ? col().key("wrapper").child(outer) : outer)
        }

        for (prefix, version, reparent) in [
            (0, 0, false), (3, 0, false), (1, 0, false), (2, 1, false), (4, 1, true),
            (128, 2, true), (0, 2, true), (2, 2, true), (1, 3, true)
        ] {
            let retained = RetainedLayoutCoordinator.TextLayoutCollector()
            let fresh = RetainedLayoutCoordinator.TextLayoutCollector()
            let viewport = Vec2(reparent ? 120 : 100, 400)
            let actual = layout.compute(root: tree(prefix: prefix, version: version, reparent: reparent, useMemo: true),
                                        state: State(), viewport: viewport, pixelScale: 1, textSystem: textSystem, textLayouts: retained)
            let expected = RetainedLayoutCoordinator().compute(
                root: tree(prefix: prefix, version: version, reparent: reparent, useMemo: false),
                state: State(), viewport: viewport, pixelScale: 1, textSystem: textSystem, textLayouts: fresh
            )
            #expect(sameGeometry(actual, expected))
            #expect(retained.liveIds == fresh.liveIds)
            #expect(retained.map.mapValues { $0.box.shaped.size } == fresh.map.mapValues { $0.box.shaped.size })
            if version == 1 && !reparent { #expect(layout.reusedMemoNodeCount > 0) }
        }
    }

    @Test("Only geometrically unchanged memo passes reuse the solved tree")
    func unrelatedCommitSkipsExtraction() {
        let cache = MemoCache()
        let layout = RetainedLayoutCoordinator()
        let textSystem = TextSystem()
        let body = cache.getOrBuild(id: "panel", deps: 1) { () -> El<State> in
            row().child(el().key("left").size(30, 10)).child(el().key("right").size(20, 10))
        }.element
        func solve(_ el: El<State>, width: Float = 92) -> LayoutEngine.ResultNode {
            layout.compute(root: el, state: State(), viewport: Vec2(width, 60), pixelScale: 1, textSystem: textSystem)
        }
        let first = solve(body)
        let repainted = solve(body.bg(.white))
        #expect(layout.reusedMemoGeometry)
        #expect(sameGeometry(repainted, first))
        let resized = solve(body, width: 130)
        #expect(!layout.reusedMemoGeometry)
        #expect(resized.layout.localRect.width == 130)
        let mirrored = solve(body.dir(.rtl), width: 130)
        #expect(!layout.reusedMemoGeometry)
        #expect(mirrored.children[0].layout.localRect.x > resized.children[0].layout.localRect.x)
        _ = solve(body, width: 130)
        #expect(!layout.reusedMemoGeometry)
    }

    @Test("A retained subtree survives layout slot compaction")
    func retainedGeometrySurvivesCompaction() {
        let cache = MemoCache()
        let coordinator = RetainedLayoutCoordinator()
        let system = TextSystem()
        let row = cache.getOrBuild(id: "last", deps: 0) { () -> El<State> in
            col().key("last").wFull().child(el().wFull().h(11)).child(el().wFull().h(17))
        }.element
        for count in [180, 1, 2, 180] {
            var root: El<State> = col()
            for index in 0..<count { root = root.child(el().key("lead-\(index)").h(1)) }
            root = root.child(row)
            let actual = coordinator.compute(root: root, state: State(), viewport: Vec2(200, 320),
                                             pixelScale: 1, textSystem: system)
            let fresh = RetainedLayoutCoordinator().compute(root: root, state: State(), viewport: Vec2(200, 320),
                                                           pixelScale: 1, textSystem: system)
            #expect(sameGeometry(actual, fresh))
        }
    }

    @Test("A displaced memo row transfers its solved children until their geometry changes")
    func displacedRowRetainsSolvedChildren() {
        let cache = MemoCache()
        let layout = RetainedLayoutCoordinator()
        let textSystem = TextSystem()
        let panel = cache.getOrBuild(id: "panel", deps: 0) { () -> El<State> in
            col().child(el().wFull().h(12)).child(el().wFull().h(6))
        }.element
        func solve(_ top: Float, _ width: Float) -> LayoutEngine.ResultNode {
            let root: El<State> = col().child(el().h(top)).child(panel.w(width))
            return layout.compute(root: root, state: State(), viewport: Vec2(192, 180),
                                  pixelScale: 1, textSystem: textSystem).children[1]
        }
        let first = solve(3, 80)
        let shifted = solve(31, 80)
        #expect(first.layout.localRect.y == 3)
        #expect(shifted.layout.localRect.y == 31)
        let shared = first.children.withUnsafeBufferPointer { lhs in
            shifted.children.withUnsafeBufferPointer { rhs in lhs.baseAddress == rhs.baseAddress }
        }
        #expect(shared)
        let resized = solve(31, 120)
        #expect(resized.children[0].layout.localSize.x == 120)
        #expect(first.children[0].layout.localSize.x == 80)
    }

    @Test("Entering row descendants replay on the next wheel with their mounted motion specs",
          arguments: [TxCommit.instant, .animate, .unprompted])
    func newlyMountedRowsReplay(commit: TxCommit) {
        func make() -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(200, 120), pixelScale: 1) { _, _ in
                col().key("scroll").sizeFull().scrollY().child(
                    col().key("rows").wFull().virtualRows(
                        count: 1_000, estimatedRowHeight: 20, key: { _, i in "r-\(i)" },
                        build: { _, _ in
                            col().wFull().h(20).child(el().key("child").size(12, 12).enterDelay(0.15)
                                .transition(Transition(insertion: .opacity(0), removal: .identity)))
                        }
                    )
                )
            }
        }
        let kept = make(), rebuilt = make()
        func rows() -> Set<String> {
            Set(kept.elements().compactMap { !$0.exiting && $0.key?.hasPrefix("r-") == true ? $0.key : nil })
        }
        _ = kept.frame(at: 0)
        _ = rebuilt.frame(at: 0)
        for i in 1...5 {
            let before = rows()
            let t = Double(i) / 30
            for runtime in [kept, rebuilt] {
                runtime.wheel(WheelEvent(dx: 0, dy: -160), at: Vec2(80, 80), now: t)
                if runtime === rebuilt { runtime.invalidate(at: t) }
                runtime.pendingCommitKind = commit
                _ = runtime.frame(at: t)
            }
            #expect(kept.elements() == rebuilt.elements())
            if i >= 3 {
                let overlap = before.intersection(rows())
                #expect(!overlap.isEmpty)
                #expect(kept.replayedFlatMemoNodes == overlap.count)
            }
        }
    }

    @Test("Confirmed virtual rows retain their root slots and honor rebuilt root modifiers",
          arguments: [false, true])
    func retainedVirtualRowRoots(screenTravel: Bool) {
        let cache = MemoCache()
        let view = Runtime<Int>(state: 82, viewport: Vec2(160, 140), pixelScale: 1) { _, _ in
            col().key("panel").sizeFull().scrollY().child(
                col().key("items").wFull().virtualRows(count: 1_000, estimatedRowHeight: 20,
                    key: { _, i in "r-\(i)" }, build: { width, i in
                        let body = cache.getOrBuild(id: "body-\(i)", deps: 0) { () -> El<Int> in
                            col().child(el().key("label-\(i)").wFull().h(12))
                        }.element
                        let sized = body.w(Float(width)).h(20)
                        return screenTravel ? sized.animateLayout(LayoutAnim(spring: MotionTokens.DEFAULT, travel: .screen)) : sized
                    })
            )
        }
        func rows() -> Set<String> {
            Set(view.elements().compactMap { $0.key?.hasPrefix("r-") == true && !$0.exiting ? $0.key : nil })
        }
        _ = view.frame(at: 0)
        for step in 1...4 {
            let previous = rows()
            let t = Double(step) / 60
            view.wheel(WheelEvent(dx: 0, dy: -160), at: Vec2(50, 90), now: t)
            _ = view.frame(at: t)
            let surviving = previous.intersection(rows())
            #expect(!surviving.isEmpty)
            #expect(view.retainedLayout.reusedVirtualRowRootCount == (screenTravel ? 0 : surviving.count))
        }
        view.update(at: 0.2) { width, _ in width = 104 }
        _ = view.frame(at: 0.2)
        #expect(view.retainedLayout.reusedVirtualRowRootCount == 0)
        let resized = view.flatNodes.filter { $0.key?.hasPrefix("label-") == true }
        #expect(!resized.isEmpty)
        #expect(resized.allSatisfy { $0.localSize.x == 104 })
    }

    @Test("Mutable children and state-backed inputs invalidate a memo layout span")
    func changedChildrenAndInputFallback() {
        let cache = MemoCache()
        let layout = RetainedLayoutCoordinator()
        let textSystem = TextSystem()
        func body() -> El<State> {
            cache.getOrBuild(id: "panel", deps: 0) { () -> El<State> in
                col().child(text("one")).child(text("two"))
            }.element
        }
        func solve(_ el: El<State>, _ state: State) -> LayoutEngine.ResultNode {
            layout.compute(root: el, state: state, viewport: Vec2(150, 150), pixelScale: 1, textSystem: textSystem)
        }
        let state = State()
        _ = solve(body(), state)
        _ = solve(body(), state)
        #expect(layout.reusedMemoNodeCount == 2)
        var changed = body()
        changed.children[0] = el().size(42, 20)
        let result = solve(changed, state)
        #expect(result.children[0].layout.localRect.width == 42)
        #expect(layout.reusedMemoNodeCount == 0)

        let withEdit = cache.getOrBuild(id: "mutable", deps: 0) { () -> El<State> in
            col().child(textInput(key: "editor", \State.edit)).child(text("fixed"))
        }.element
        _ = solve(withEdit, state)
        var updated = state
        updated.edit = TextEdit("changed")
        _ = solve(withEdit, updated)
        #expect(layout.reusedMemoNodeCount == 0)
    }
}
