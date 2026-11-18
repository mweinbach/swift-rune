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
}
