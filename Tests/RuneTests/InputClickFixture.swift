import Foundation
import Testing
@testable import Rune

/// The shared fixture of `crates/rune/src/runtime/input_click_tests.rs:1-130` (`Form`, `view`,
/// `runtime`, `rect_of`, `point_in_cluster`, `point_at_byte`, `click`), mirrored field for field so
/// every `input_click_tests.rs` port reuses it unchanged.
enum InputClickFixture {
    struct Form {
        var single: TextEdit
        var multi: TextEdit
        var other: TextEdit
        var secret: TextEdit
        var secretMulti: TextEdit
        var pills: TextEdit
        var showSingle: Bool
        var presses: Int
        var drags: [DragPhase]
    }

    /// `style()`: 14 pt regular on a 20 pt line.
    static func style() -> TextStyle {
        TextStyle(size: 14, weight: 400).lh(20)
    }

    /// `view(s, cx)`.
    static func view(_ s: Form, _: inout Cx<Form>) -> El<Form> {
        let st = style()
        var root: El<Form> = col().wFull().hFull().p(8).gap(8)
        if s.showSingle {
            root = root.child(
                textInput(key: "single", \Form.single)
                    .font(st)
                    .singleLine(true)
                    .size(280, 24)
                    .onClick { $0.presses += 1 }
                    .onDrag { s, d, _ in s.drags.append(d.phase) }
                    .onInputKey { s, ev, _ in
                        if ev.key == .f(2) {
                            s.single.insert("!")
                            return true
                        }
                        return false
                    }
            )
        }
        return root
            .child(textInput(key: "multi", \Form.multi).font(st).size(280, 80))
            .child(textInput(key: "other", \Form.other).font(st).singleLine(true).size(280, 24))
            .child(textInput(key: "secret", \Form.secret).font(st).singleLine(true).secure(true).size(280, 24))
            .child(textInput(key: "secret-multi", \Form.secretMulti).font(st).secure(true).size(280, 48))
            .child(textInput(key: "pills", \Form.pills).font(st).singleLine(true).size(280, 24))
    }

    /// `runtime()`: the form at 320 × 300, scale 1, after its first frame.
    static func runtime() -> Runtime<Form> {
        var pills = TextEdit("", multiline: false).rich()
        pills.insertPill(id: "u:1", label: "@maya")
        pills.insert(" hello")
        pills.setCursor(utf8Offset: 0)
        let state = Form(
            single: TextEdit("make the title smaller", multiline: false),
            multi: TextEdit("first line here\nsecond line there\nthird line end", multiline: true),
            other: TextEdit("other words", multiline: false),
            secret: TextEdit("correct horse battery", multiline: false),
            secretMulti: TextEdit("line one secret\nline two secret", multiline: true),
            pills: pills,
            showSingle: true,
            presses: 0,
            drags: []
        )
        let rt = Runtime(state: state, viewport: Vec2(320, 300), pixelScale: 1.0, view: view)
        _ = rt.frame(at: 0)
        return rt
    }

    /// `rect_of(rt, key)`: the element's `[x, y, w, h]`.
    static func rectOf(_ rt: Runtime<Form>, _ key: String) throws -> [Float] {
        try #require(rt.element(byKey: key)?.rect)
    }

    /// `point_in_cluster(rt, key, byte, frac)`: the window point `frac` (`0..<1`) across the glyph
    /// cluster at `byte` in field `key`, vertically centred on its caret.
    static func pointInCluster(_ rt: Runtime<Form>, _ key: String, _ byte: Int, _ frac: Float) throws -> Vec2 {
        let node = try #require(rt.flatNodes.first { $0.key == key })
        let lens = try #require(node.el.handlers.editLens)
        let edit = lens.get(rt.state)
        let rect = rt.presentedRectByPath[node.path] ?? node.targetRect
        let pad = node.el.layout.padding
        let resolved = ElDisplayResolver.resolveInput(el: node.el, edit: edit, innerWidth: max(0, rect.width - pad.left - pad.right))
        let shaped = rt.textSystem.shape(
            text: resolved.renderedString,
            spans: resolved.spans,
            pills: resolved.pills,
            style: resolved.style,
            maxWidth: resolved.maxWidthForShape,
            pixelScale: rt.pixelScale,
            emitGlyphs: false
        )
        let c0 = rt.textSystem.caretRect(in: shaped, utf8Offset: byte, pixelScale: rt.pixelScale)
        let c1 = rt.textSystem.caretRect(in: shaped, utf8Offset: byte + 1, pixelScale: rt.pixelScale)
        let hScroll = edit.multiline ? 0 : (rt.inputMachines.inputScroll[node.path] ?? 0)
        return Vec2(
            rect.x + pad.left + c0.x + (c1.x - c0.x) * frac - hScroll,
            rect.y + pad.top + c0.y + c0.w * 0.5
        )
    }

    /// `point_at_byte(rt, key, byte)`: a quarter of the way across the cluster.
    static func pointAtByte(_ rt: Runtime<Form>, _ key: String, _ byte: Int) throws -> Vec2 {
        try pointInCluster(rt, key, byte, 0.25)
    }
}
