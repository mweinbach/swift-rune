import Rune
import Foundation

struct Fields {
    var modalOpen = false
    var editor = TextEdit("A\u{1F680}e\u{0301}Z")
    var password = TextEdit("fixture-only-secret")
    var revision = TextEdit("a\nbefore target after", multiline: true)
    var document = TextEdit("🚀e\u{0301}\n" + String(repeating: String(repeating: "0123456789abcdef", count: 64) + "\n", count: 64) + "End",
                            multiline: true)

    init() {
        editor.moveLeft(extend: true)
        document.setCursor(utf8Offset: 0)
        document.setCursor(utf8Offset: 4, extendSelection: true)
    }
}

func view(_ fields: Fields, _: inout Cx<Fields>) -> El<Fields> {
    if fields.modalOpen {
        return col().key("modal-root").child(
            col().key("modal-dialog").role(.dialog).modal().label("Confirm choices")
        )
    }
    let editor: El<Fields> = textInput(key: "editor", \.editor)
        .label("Editor").wFull().h(48).shrink(0).p(8)
    let password: El<Fields> = textInput(key: "password", \.password)
        .secure().label("Password").wFull().h(48).shrink(0).p(8)
    let document: El<Fields> = textInput(key: "document", \.document)
        .label("Long document").wFull().h(64).shrink(0).p(8)
    let section: El<Fields> = col().key("section").role(.region).label("Document section").h(1000).shrink(0)
        .child(text("Document").key("heading").headingLevel(3))
        .child(textInput(key: "revision", \.revision).label("Revisions").wFull().h(64).shrink(0).p(4))
        .child(col().key("modeless-dialog").role(.dialog).label("Preferences"))
        .child(col().key("alert-dialog").role(.alertDialog).label("Review warning"))
        .child(col().key("scroll-pane").h(20).scrollY().child(text("Scrollable details").h(40)))
        .child(el().key("open-modal").role(.button).label("Confirm").focusable().onClick { $0.modalOpen = true })
    return col().key("scroll").role(.main).sizeFull().scrollY().p(8).gap(8)
        .child(editor).child(password).child(section).child(document)
}

struct Choices {
    var secondTab = false
    var options: Set<String> = []
    var listItem = true
    var treeItem = true
    var cell = true
    var secondRadio = false
    var menuRadio = true
    var switchOn = true
    var farOption = false
    var batchSelected = false
}

func choice(_ key: String, _ role: ElementRole) -> El<Choices> {
    el().key(key).role(role).label(key).h(18).wFull().shrink(0)
}

func selectionView(_ state: Choices, _: inout Cx<Choices>) -> El<Choices> {
    let tabs: El<Choices> = col().key("tabs").role(.tabList).focusGroup()
        .child(choice("tab-one", .tab).itemSelected(!state.secondTab).onClick { $0.secondTab = false })
        .child(choice("tab-two", .tab).itemSelected(state.secondTab).onClick { $0.secondTab = true })

    var options: El<Choices> = col().key("options").role(.listbox).focusGroup()
    for id in ["option-one", "option-two", "option-three"] {
        options = options.child(choice(id, .option).itemSelected(state.options.contains(id)).onClick { state in
            if !state.options.insert(id).inserted { state.options.remove(id) }
        })
    }
    options = options
        .child(choice("disabled-option", .option).itemSelected(false).disabled())
        .child(choice("read-only-option", .option).itemSelected(false))

    let list: El<Choices> = col().key("list").role(.list).focusGroup()
        .child(choice("list-item", .listItem).itemSelected(state.listItem).onClick { $0.listItem.toggle() })
    let tree: El<Choices> = col().key("tree").role(.tree).focusGroup()
        .child(choice("tree-item", .treeItem).itemSelected(state.treeItem).onClick { $0.treeItem.toggle() })
    let grid: El<Choices> = col().key("grid").role(.grid).focusGroup()
        .child(col().key("grid-row").role(.row)
            .child(choice("grid-cell", .gridCell).itemSelected(state.cell).onClick { $0.cell.toggle() }))
    let treeGrid: El<Choices> = col().key("tree-grid").role(.treeGrid).focusGroup()
        .child(col().key("tree-grid-row").role(.row)
            .child(choice("tree-grid-item", .treeItem).itemSelected(true))
            .child(choice("tree-grid-cell", .gridCell).itemSelected(true)))
    let radios: El<Choices> = col().key("radios").role(.radiogroup).focusGroup()
        .child(choice("radio-on", .radio).checked(!state.secondRadio).onClick { $0.secondRadio = false })
        .child(choice("radio-off", .radio).checked(state.secondRadio).onClick { $0.secondRadio = true })
    let menu: El<Choices> = col().key("menu").role(.menu)
        .child(choice("menu-radio", .menuItemRadio).checked(state.menuRadio).onClick { $0.menuRadio.toggle() })
        .child(choice("mixed-radio", .menuItemRadio).checkedMixed())
        .child(choice("unspecified-radio", .menuItemRadio))
        .child(choice("menu-check", .menuItemCheckbox).checked(true))
        .child(choice("unspecified-check", .menuItemCheckbox))

    let scroller: El<Choices> = col().key("choice-scroll").role(.listbox).focusGroup().h(54).shrink(0).scrollY()
        .child(el().h(300).shrink(0))
        .child(choice("far-option", .option).itemSelected(state.farOption).onClick { $0.farOption.toggle() })

    let batch: El<Choices> = col().key("batch-options").role(.listbox).focusGroup()
        .children((0..<21).map { choice("batch-\($0)", .option).itemSelected(state.batchSelected).h(2) })
    return col().key("selection-root").role(.main).sizeFull().p(4)
        .child(scroller).child(choice("outside", .button))
        .child(tabs).child(options).child(list).child(tree).child(grid).child(treeGrid).child(radios).child(menu)
        .child(choice("selected-button", .button).itemSelected(true))
        .child(choice("unmarked-option", .option)).child(choice("unmarked-cell", .gridCell))
        .child(choice("checked-switch", .switchControl).checked(state.switchOn).onClick { $0.switchOn.toggle() })
        .child(choice("alert", .alert)).child(choice("quotation", .blockquote))
        .child(choice("splitter", .splitter).onClick { $0.switchOn = true })
        .child(col().key("empty-options").role(.listbox).h(8))
        .child(choice("select-batch", .button).onClick { $0.batchSelected = true }).child(batch)
}

if ProcessInfo.processInfo.environment["RUNE_SELECTION_FIXTURE"] == "1" {
    try RuneApp.run(AppSpec(title: "Rune UI Automation selection fixture", size: Vec2(480, 600),
                            state: Choices(), view: selectionView))
} else {
    try RuneApp.run(AppSpec(title: "Rune UI Automation text fixture", size: Vec2(400, 160),
                            state: Fields(), view: view))
}
