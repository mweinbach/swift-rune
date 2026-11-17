import Foundation
import RuneMotion
import Testing
@testable import Rune

@Suite("Android virtual accessibility nodes")
struct AndroidSemanticTreeTests {
    @Test func secureSurroundingTextPreservesSelection() {
        var edit = TextEdit("a🚀BC🌎z")
        edit.setSelectionRaw(anchor: 7, cursor: 5)
        edit.deleteAndroidSurrounding(before: 1, after: 1, codePoints: true)
        #expect(edit.text == "aBCz")
        #expect(edit.anchor == 3)
        #expect(edit.cursor == 1)
        edit.deleteAndroidSurrounding(before: .max, after: .max, codePoints: false)
        #expect(edit.text == "BC")
    }

    @Test func identityClippingAndPasswordRedaction() throws {
        let bounds = MotionRect.fromXYWH(0, 0, 120, 80)
        var field = AccessibilityNode(id: "secret", role: .passwordInput, label: "Secret", value: "private-value",
                                      frame: .fromXYWH(0, 12, 100, 36), isSecure: true, actions: [.focus])
        field.runtimePath = "/left/secret"
        var toggle = AccessibilityNode(id: "lights", role: .switchControl, label: "Lights", value: "false",
                                      frame: .fromXYWH(20, 0, 38, 22), isFocusable: true, actions: [.press])
        toggle.runtimePath = "/left/lights"
        var root = AccessibilityNode(id: "root", role: .group, frame: .fromXYWH(10, 0, 80, 50),
                                     clipsChildren: true, children: [field, toggle])
        let projection = AndroidSemanticTree()
        let first = projection.project(root, viewport: bounds, scale: 2)
        #expect(first[1].value == nil)
        #expect(first[1].rect == [20, 24, 180, 96])
        #expect(first[2].checked == "false")
        let toggleID = first[2].id
        root.children = [toggle, field]
        let second = projection.project(root, viewport: bounds, scale: 2)
        #expect(second[1].id == toggleID)
        #expect(projection.targets[toggleID] == "/left/lights")
        #expect(!String(decoding: try JSONEncoder().encode(second), as: UTF8.self).contains("private-value"))
    }
}
