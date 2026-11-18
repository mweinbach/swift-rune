import Testing
@testable import Rune
import RuneMotion

@Suite("First frames of authored virtual rows")
struct AuthoredVirtualMountTests {
    @Test("Entering rows publish their mount and reuse their next mounted frame", arguments: [TxCommit.instant, .animate, .unprompted])
    func firstMountedFrame(kind: TxCommit) {
        final class Owner {}
        func make(_ owned: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(180, 120), pixelScale: 1) { _, _ in
                let list: El<Int> = col().key("rows").wFull().virtualRows(
                    count: 1_000, estimatedRowHeight: 20, key: { _, i in "r-\(i)" }, buildContent: { _, i in
                        func content() -> El<Int> {
                            let child: El<Int> = el().key("child-\(i)").size(40, 12).enterDelay(0.15)
                                .transition(Transition(insertion: .opacity(0), removal: .identity))
                            return col().wFull().h(20).clip().child(child)
                        }
                        guard owned else { return VirtualRowContent(content()) }
                        return memoizedVirtualRow("r-\(i)", deps: 0, makeContext: { Owner() },
                                                  updateContext: { _ in }, build: { _ in content() })
                    })
                return col().key("scroll").sizeFull().scrollY().child(list)
            }
        }
        let owned = make(true), rebuilt = make(false)
        func rows() -> Set<String> {
            Set(owned.flatNodes.compactMap { $0.key?.hasPrefix("r-") == true ? $0.key : nil })
        }
        for runtime in [owned, rebuilt] { _ = runtime.renderFrame(at: 0) }
        for i in 1...6 {
            let t = Double(i) / 30, previous = rows()
            for runtime in [owned, rebuilt] {
                runtime.wheel(WheelEvent(dx: 0, dy: -160), at: Vec2(80, 80), now: t)
                runtime.invalidate(at: t)
                runtime.pendingCommitKind = kind
            }
            let a = owned.renderFrame(at: t), b = rebuilt.renderFrame(at: t)
            #expect(a.instances.map(\.rect) == b.instances.map(\.rect))
            #expect(a.instances.map(\.fill) == b.instances.map(\.fill))
            #expect(owned.lastCommittedSpecs == rebuilt.lastCommittedSpecs)
            #expect(owned.elements() == rebuilt.elements())
            #expect(owned.accessibilitySnapshot() == rebuilt.accessibilitySnapshot())
            if i >= 3 {
                let current = rows(), survivors = current.intersection(previous)
                #expect(!survivors.isEmpty)
                #expect(!current.subtracting(previous).isEmpty)
                #expect(owned.replayedVirtualFlatRoots == survivors.count)
                #expect(owned.replayedFlatMemoNodes == survivors.count)
                #expect(rebuilt.replayedVirtualFlatRoots == 0)
            }
        }
    }

    @Test("A new list path or a replacement for a nonvirtual parent establishes its own mount",
          arguments: [true, false])
    func newListParent(movingList: Bool) {
        final class Owner {}
        let runtime = Runtime(state: 0, viewport: Vec2(180, 120), pixelScale: 1) { tick, _ in
            let list: El<Int> = col().key("list").wFull().virtualRows(
                count: 24, estimatedRowHeight: 20, key: { _, i in "row-\(i)" }, buildContent: { _, i in
                    memoizedVirtualRow("row-\(i)", deps: 0, makeContext: { Owner() },
                                       updateContext: { _ in }) { _ in
                        col().wFull().h(20).child(el().size(8, 8).enterDelay(0.15))
                    }
                })
            let content: El<Int>
            if movingList {
                content = list.animateLayout(LayoutAnim(spring: MotionTokens.DEFAULT, travel: .screen))
            } else {
                content = tick < 2 ? col().key("list").wFull().h(24) : list
            }
            let shell: El<Int> = col().key(movingList && tick >= 2 ? "second" : "first").wFull().child(content)
            return col().key("scroll").sizeFull().scrollY().child(shell)
        }
        for tick in 0...4 {
            let time = Double(tick) / 30
            runtime.update(at: time) { state, _ in state = tick }
            runtime.pendingCommitKind = .animate
            _ = runtime.renderFrame(at: time)
            if tick == 3 { #expect(runtime.replayedVirtualFlatRoots == 0) }
            if tick == 4 { #expect(runtime.replayedVirtualFlatRoots > 0) }
        }
    }
}
