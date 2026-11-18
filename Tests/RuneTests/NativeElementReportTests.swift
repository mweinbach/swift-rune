import Testing
@testable import Rune
import RuneMotion

@Suite("Native element inspection")
struct NativeElementReportTests {
    @Test("A single query reads only its matching report, and each paint owns its geometry and content")
    func lazyInspectionAcrossCommit() throws {
        let rt = Runtime(state: false, viewport: Vec2(200, 100)) { changed, _ -> El<Bool> in
            col().child(text(changed ? "Second" : "First").key("label").size(changed ? 80 : 40, 20))
        }
        _ = rt.renderFrame(at: 0)
        #expect(rt.nativeElementReports != nil)
        #expect(rt.presented("label")?.rect == [0, 0, 40, 20])
        let first = try #require(rt.element(byKey: "label"))
        #expect(first.text == "First")
        #expect(rt.nativeElementReports != nil)

        rt.update(at: 0.1) { changed, tx in
            changed = true
            tx.instant()
        }
        #expect(rt.element(byKey: "label")?.text == "First")
        _ = rt.renderFrame(at: 0.2)
        #expect(rt.nativeElementReports != nil)
        let current = try #require(rt.elements().first { $0.key == "label" })
        #expect(rt.nativeElementReports == nil)
        #expect(current.text == "Second")
        #expect(current.rect == [0, 0, 80, 20])
        #expect(first.text == "First")
        #expect(first.rect == [0, 0, 40, 20])
    }

    @Test("Synthetic text links retain their painted contents and tree position")
    func linksDoNotMaterializeUnrelatedElements() throws {
        let rt = Runtime(state: false, viewport: Vec2(300, 100)) { changed, _ -> El<Bool> in
            col().children([
                el().key("other").size(15, 12),
                text(changed ? "Open link now" : "Open docs now").key("owner")
                    .link(TextLink(5..<9, id: "docs", label: "Documentation"))
            ])
        }
        _ = rt.renderFrame(at: 0)
        #expect(rt.nativeElementReports != nil)
        let link = try #require(rt.element(byKey: "docs"))
        #expect(rt.nativeElementReports != nil)
        #expect(link.text == "docs")
        #expect(link.label == "Documentation")
        let infos = rt.elements()
        let owner = try #require(link.parentIndex)
        #expect(infos[owner].key == "owner")
        #expect(!infos[owner].focusable)
        #expect(link.focusable)

        rt.update { changed, tx in
            changed = true
            tx.instant()
        }
        _ = rt.renderFrame(at: 0.2)
        #expect(rt.element(byKey: "docs")?.text == "link")
        #expect(infos.first(where: { $0.key == "docs" })?.text == "docs")
    }

    @Test("Raised siblings reopen the clip, opacity and rotation of their own paint branch")
    func raisedBranchesKeepOwnScope() throws {
        let rt = Runtime(state: (), viewport: Vec2(220, 130)) { _, _ -> El<Void> in
            row().size(180, 100).children([
                col().key("left").size(60, 48).clipRounded(0).opacity(0.5).rotate(0.12).child(
                    el().raise().key("a").size(100, 88).child(el().key("inner-a").size(72, 65))
                ),
                col().key("right").size(70, 60).clipRounded(0).opacity(0.25).child(
                    col().child(el().raise().key("b").size(104, 80).child(el().key("inner-b").size(79, 61)))
                )
            ])
        }
        _ = rt.renderFrame(at: 0)
        let native = rt.elements()
        _ = rt.frame(at: 0)
        let reference = rt.elements()
        for key in ["a", "inner-a", "b", "inner-b"] {
            let actual = try #require(native.first { $0.key == key })
            let expected = try #require(reference.first { $0.key == key })
            #expect(actual.opacity == expected.opacity)
            // Rust reports each turned clip in window coordinates, including its negative edges.
            let viewport = key.hasSuffix("a") ? "left" : "right"
            let clip = try #require(native.first { $0.key == viewport })
            #expect(actual.visible == clip.rect)
            #expect(expected.visible == clip.rect)
            #expect(actual.rect == expected.rect)
            #expect(actual.parentIndex == expected.parentIndex)
        }
    }

    @Test("A transparent group's only child retains its inherited paint opacity and clip")
    func singleChildInheritsTransparentGroupHitScope() throws {
        let rt = Runtime(state: (), viewport: Vec2(64, 32)) { _, _ -> El<Void> in
            el().size(64, 32).hoverGroup().child(
                el().key("action").size(24, 24).clip().groupOpacity(0, 1).child(
                    el().key("glyph").absolute(x: 18, y: 0).size(12, 12).bg(.white).hit()
                )
            )
        }

        _ = rt.renderFrame(at: 0)
        let action = try #require(rt.element(byKey: "action"))
        let glyph = try #require(rt.element(byKey: "glyph"))
        let hit = try #require(rt.hitGeometryByPath[glyph.path])
        let node = try #require(rt.flatNodes.first { $0.key == "glyph" })
        let presence = try #require(rt.kitHooks.unseenPresence.frameById[node.nodeId])

        #expect(action.opacity == 0)
        #expect(glyph.opacity == 0)
        #expect(hit.opacity == 0)
        #expect(glyph.visible == [18, 0, 6, 12])
        #expect(rt.containsWith("glyph", x: 20, y: 5, pick: Pick(transparent: true)))
        #expect(!rt.containsWith("glyph", x: 28, y: 5, pick: Pick(transparent: true)))
        #expect(presence.geometricallyInView)
        #expect(!presence.inView)
        #expect(presence.inheritedOpacity == 0)
    }

    @Test("Unclipped turned bounds cross window edges while clicks remain inside the window", arguments: [true, false])
    func turnedBoundsCrossViewport(native: Bool) throws {
        let rt = Runtime(state: 0, viewport: Vec2(104, 80)) { _, _ -> El<Int> in
            el().size(104, 80).children([
                el().key("left").absolute(x: 0, y: 0).size(60, 48).rotate(0.12)
                    .role(.button).label("Left button").onClick { $0 += 1 }
                    .child(el().key("inner").absolute(x: -5, y: -3).size(12, 12)),
                el().key("right").absolute(x: 93, y: 69).size(22, 18).rotate(-0.3),
                el().key("clip").absolute(x: 62, y: 12).size(16, 16).clipRounded(0).child(
                    el().key("clipped").absolute(x: -4, y: -5).size(28, 25).rotate(0.15)
                )
            ])
        }
        if native { _ = rt.renderFrame(at: 0) } else { _ = rt.frame(at: 0) }

        let left = try #require(rt.element(byKey: "left"))
        let inner = try #require(rt.element(byKey: "inner"))
        let right = try #require(rt.element(byKey: "right"))
        #expect(left.rect[0] < 0 && left.rect[1] < 0)
        #expect(right.rect[0] + right.rect[2] > 104 && right.rect[1] + right.rect[3] > 80)
        for item in [left, inner, right] {
            #expect(item.visible == item.rect)
        }
        #expect(rt.element(byKey: "clipped")?.visible == [62, 12, 16, 16])
        #expect(rt.elementAt(-1, 32) == nil && rt.elementAt(110, 76) == nil)
        #expect(rt.elementAt(5, 32)?.key == "left")
        let button = try #require(rt.accessibilitySnapshot().children.first { $0.id == "left" })
        #expect(button.frame == MotionRect.fromXYWH(0, 0, 60, 48))
        #expect(button.label == "Left button" && button.actions.contains(.press))
        rt.pointerDown(at: Vec2(-1, 32), at: 0.01)
        rt.pointerUp(at: Vec2(-1, 32), at: 0.02)
        #expect(rt.state == 0)
        rt.pointerDown(at: Vec2(5, 32), at: 0.03)
        rt.pointerUp(at: Vec2(5, 32), at: 0.04)
        #expect(rt.state == 1)
    }
}
