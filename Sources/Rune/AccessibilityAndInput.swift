import Foundation
import RuneMotion
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Accessibility Tree Projection (`rune::a11y`)

/// Semantic action supported by an accessibility element.
public enum AccessibilityAction: String, Sendable, Hashable, Codable {
    case press
    case focus
    case increment
    case decrement
}

/// Live-region announcement politeness (`rune::LiveRegion`).
public enum LiveRegionPoliteness: String, Sendable, Hashable, Codable {
    case polite
    case assertive
}

/// Window-level accessibility announcement state (`rune::a11y::Announcement`).
public struct AccessibilityAnnouncement: Sendable, Equatable {
    public var text: String
    public var politeness: LiveRegionPoliteness
    public private(set) var count: UInt32 = 0

    public init(text: String = "", politeness: LiveRegionPoliteness = .polite) {
        self.text = text
        self.politeness = politeness
    }

    public mutating func say(_ text: String, politeness: LiveRegionPoliteness = .polite) {
        self.text = text
        self.politeness = politeness
        self.count &+= 1
    }

    /// Alternating zero-width space suffix ensures screen readers speak repeated identical messages.
    public var spokenText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (count % 2 == 0) ? "\(text)\u{200B}" : text
    }
}

/// Platform-independent semantic accessibility node projected from a laid-out `El<State>`.
public struct AccessibilityNode: Sendable, Equatable {
    public var id: String
    public var role: ElementRole
    public var label: String?
    public var value: String?
    public var help: String?
    public var frame: MotionRect
    public var isFocused: Bool
    public var isFocusable: Bool
    public var isSelected: Bool
    public var isExpanded: Bool?
    public var level: Int?
    public var isModal: Bool
    public var isSecure: Bool
    public var actions: [AccessibilityAction]
    public var children: [AccessibilityNode]

    public init(
        id: String,
        role: ElementRole,
        label: String? = nil,
        value: String? = nil,
        help: String? = nil,
        frame: MotionRect = .zero,
        isFocused: Bool = false,
        isFocusable: Bool = false,
        isSelected: Bool = false,
        isExpanded: Bool? = nil,
        level: Int? = nil,
        isModal: Bool = false,
        isSecure: Bool = false,
        actions: [AccessibilityAction] = [],
        children: [AccessibilityNode] = []
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.help = help
        self.frame = frame
        self.isFocused = isFocused
        self.isFocusable = isFocusable
        self.isSelected = isSelected
        self.isExpanded = isExpanded
        self.level = level
        self.isModal = isModal
        self.isSecure = isSecure
        self.actions = actions
        self.children = children
    }
}

/// Projects a laid-out `El<State>` tree into a semantic `AccessibilityNode` tree.
public enum AccessibilityTreeBuilder {
    public static func project<State>(
        element: El<State>,
        layout: LayoutEngine.ResultNode,
        state: State? = nil,
        origin: Vec2 = .zero,
        focusedKey: String? = nil,
        path: String = "root"
    ) -> AccessibilityNode? {
        if element.isInert || element.isA11yHidden {
            return nil
        }

        let nodeId = element.keyId ?? path
        let absRect = MotionRect.fromXYWH(
            origin.x + layout.layout.localRect.x,
            origin.y + layout.layout.localRect.y,
            layout.layout.localRect.width,
            layout.layout.localRect.height
        )

        var actions: [AccessibilityAction] = []
        if element.handlers.onClick != nil || element.handlers.onClickPress != nil {
            actions.append(.press)
        }
        if element.focusable {
            actions.append(.focus)
        }
        if element.role == .slider {
            actions.append(.increment)
            actions.append(.decrement)
        }

        var value: String? = element.a11ySelected
        var isSecure = false
        if let state, let editLens = element.handlers.editLens {
            let edit = editLens.get(state)
            isSecure = edit.isSecure
            value = edit.isSecure ? nil : edit.text
        }

        let label = isSecure ? (element.a11yLabel ?? "Password") : (element.a11yLabel ?? element.plainText)
        let isFocused = (focusedKey != nil && element.keyId == focusedKey)

        var projectedChildren: [AccessibilityNode] = []
        let childOrigin = Vec2(absRect.x, absRect.y)
        let count = min(element.children.count, layout.children.count)
        for i in 0..<count {
            let childPath = "\(nodeId)/#\(i)"
            if let childNode = project(
                element: element.children[i],
                layout: layout.children[i],
                state: state,
                origin: childOrigin,
                focusedKey: focusedKey,
                path: childPath
            ) {
                projectedChildren.append(childNode)
            }
        }

        return AccessibilityNode(
            id: nodeId,
            role: element.role,
            label: label,
            value: value,
            help: element.a11yHelp,
            frame: absRect,
            isFocused: isFocused,
            isFocusable: element.focusable,
            isSelected: element.itemSelected,
            isExpanded: element.a11yExpanded,
            level: element.a11yLevel,
            isModal: element.isModal,
            isSecure: isSecure,
            actions: actions,
            children: projectedChildren
        )
    }
}

#if os(macOS)
/// Builds an AppKit `NSAccessibilityElement` hierarchy from a projected `AccessibilityNode`.
public enum AppKitAccessibilityMapper {
    public static func nsRole(for role: ElementRole) -> NSAccessibility.Role {
        switch role {
        case .group: return .group
        case .text: return .staticText
        case .button: return .button
        case .checkbox: return .checkBox
        case .switchControl: return .checkBox
        case .radio: return .radioButton
        case .tab: return .radioButton
        case .textInput: return .textField
        case .slider: return .slider
        case .progress: return .progressIndicator
        case .listItem: return .row
        case .heading: return .staticText
        case .dialog: return .sheet
        case .menu: return .menu
        case .menuItem: return .menuItem
        case .image, .icon: return .image
        case .separator: return .splitter
        case .combobox: return .comboBox
        case .listbox: return .list
        case .option: return .menuItem
        case .tree: return .outline
        case .treeItem: return .row
        case .grid: return .table
        case .row: return .row
        case .gridCell: return .cell
        case .columnHeader: return .column
        case .radiogroup: return .radioGroup
        case .tabList: return .tabGroup
        case .tooltip: return .helpTag
        case .alert, .region, .main: return .group
        case .link: return .link
        }
    }

    @MainActor
    public static func buildElement(
        from node: AccessibilityNode,
        parent: AnyObject? = nil,
        onAction: (@Sendable (String, AccessibilityAction) -> Void)? = nil
    ) -> RuneNSAccessibilityElement {
        let el = RuneNSAccessibilityElement(node: node, parent: parent, onAction: onAction)
        let childEls = node.children.map {
            buildElement(from: $0, parent: el, onAction: onAction)
        }
        el.setAccessibilityChildren(childEls)
        return el
    }
}

/// Concrete `NSAccessibilityElement` backing a projected `AccessibilityNode` on macOS.
public final class RuneNSAccessibilityElement: NSAccessibilityElement {
    public let nodeId: String
    public let supportedActions: [AccessibilityAction]
    private let actionHandler: (@Sendable (String, AccessibilityAction) -> Void)?

    public init(
        node: AccessibilityNode,
        parent: AnyObject?,
        onAction: (@Sendable (String, AccessibilityAction) -> Void)?
    ) {
        self.nodeId = node.id
        self.supportedActions = node.actions
        self.actionHandler = onAction
        super.init()

        setAccessibilityRole(AppKitAccessibilityMapper.nsRole(for: node.role))
        if node.isSecure {
            setAccessibilitySubrole(.secureTextField)
        }
        if let parent {
            setAccessibilityParent(parent)
        }
        setAccessibilityIdentifier(node.id)
        if let label = node.label {
            setAccessibilityLabel(label)
        }
        if !node.isSecure, let value = node.value {
            setAccessibilityValue(value)
        }
        if let help = node.help {
            setAccessibilityHelp(help)
        }
        setAccessibilityFrame(CGRect(
            x: CGFloat(node.frame.x),
            y: CGFloat(node.frame.y),
            width: CGFloat(node.frame.width),
            height: CGFloat(node.frame.height)
        ))
        setAccessibilityFocused(node.isFocused)
        setAccessibilitySelected(node.isSelected)
        if let expanded = node.isExpanded {
            setAccessibilityExpanded(expanded)
        }
    }

    public override func accessibilityPerformPress() -> Bool {
        guard supportedActions.contains(.press) else { return false }
        actionHandler?(nodeId, .press)
        return true
    }

    public override func accessibilityPerformIncrement() -> Bool {
        guard supportedActions.contains(.increment) else { return false }
        actionHandler?(nodeId, .increment)
        return true
    }

    public override func accessibilityPerformDecrement() -> Bool {
        guard supportedActions.contains(.decrement) else { return false }
        actionHandler?(nodeId, .decrement)
        return true
    }
}
#elseif canImport(UIKit) && !os(watchOS)
/// Builds a UIKit `UIAccessibilityElement` hierarchy from a projected `AccessibilityNode`.
public enum UIKitAccessibilityMapper {
    public static func traits(for role: ElementRole) -> UIAccessibilityTraits {
        switch role {
        case .button, .menuItem: return .button
        case .text, .listItem, .group, .dialog, .menu, .separator: return .staticText
        case .heading: return .header
        case .image, .icon: return .image
        case .slider: return .adjustable
        case .checkbox, .switchControl, .radio, .tab: return .button
        case .textInput: return .none
        case .progress: return .updatesFrequently
        case .combobox, .option, .link: return .button
        case .listbox, .tree, .treeItem, .grid, .row, .gridCell, .columnHeader, .radiogroup, .tabList, .tooltip, .alert, .region, .main:
            return .staticText
        }
    }

    @MainActor
    public static func buildElements(
        from node: AccessibilityNode,
        container: Any,
        onAction: (@Sendable (String, AccessibilityAction) -> Void)? = nil
    ) -> [RuneUIAccessibilityElement] {
        var result: [RuneUIAccessibilityElement] = []
        let el = RuneUIAccessibilityElement(node: node, container: container, onAction: onAction)
        if node.role != .group {
            result.append(el)
        }
        for child in node.children {
            result.append(contentsOf: buildElements(from: child, container: container, onAction: onAction))
        }
        return result
    }
}

/// Concrete `UIAccessibilityElement` backing a projected `AccessibilityNode` on iOS/iPadOS/visionOS.
@MainActor
public final class RuneUIAccessibilityElement: UIAccessibilityElement {
    public let nodeId: String
    public let supportedActions: [AccessibilityAction]
    private let actionHandler: (@Sendable (String, AccessibilityAction) -> Void)?

    public init(
        node: AccessibilityNode,
        container: Any,
        onAction: (@Sendable (String, AccessibilityAction) -> Void)?
    ) {
        self.nodeId = node.id
        self.supportedActions = node.actions
        self.actionHandler = onAction
        super.init(accessibilityContainer: container)
        self.isAccessibilityElement = node.role != .group
        self.accessibilityIdentifier = node.id
        self.accessibilityLabel = node.label
        self.accessibilityValue = node.value
        self.accessibilityHint = node.help
        var traits = UIKitAccessibilityMapper.traits(for: node.role)
        if node.isSelected { traits.insert(.selected) }
        self.accessibilityTraits = traits
        self.accessibilityFrameInContainerSpace = CGRect(
            x: CGFloat(node.frame.x),
            y: CGFloat(node.frame.y),
            width: CGFloat(node.frame.width),
            height: CGFloat(node.frame.height)
        )
    }

    public override func accessibilityActivate() -> Bool {
        guard supportedActions.contains(.press) else { return false }
        actionHandler?(nodeId, .press)
        return true
    }

    public override func accessibilityIncrement() {
        guard supportedActions.contains(.increment) else { return }
        actionHandler?(nodeId, .increment)
    }

    public override func accessibilityDecrement() {
        guard supportedActions.contains(.decrement) else { return }
        actionHandler?(nodeId, .decrement)
    }
}
#endif

// MARK: - Spellcheck (`rune::spell`)

/// Spellcheck backend interface (`rune::spell::platform`).
public protocol SpellCheckBackend: Sendable {
    func misspelledUTF8Ranges(in text: String) -> [Range<Int>]
    func suggestions(for word: String) -> [String]
    func learnWord(_ word: String)
    func ignoreWord(_ word: String)
}

/// Deterministic in-memory spellcheck backend for headless tests and cross-platform fallback.
public final class CustomDictionarySpellChecker: SpellCheckBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var dictionary: Set<String>
    private var ignored: Set<String> = []

    public static let defaultWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "code", "color",
        "do", "does", "edit", "editor", "element", "file", "for", "from", "good", "grid",
        "hello", "help", "in", "input", "is", "it", "key", "layout", "line", "list",
        "macos", "menu", "message", "more", "new", "no", "not", "of", "on", "or", "quick",
        "read", "red", "right", "row", "rune", "run", "save", "search", "select", "set",
        "shortcut", "spell", "spellcheck", "swift", "test", "text", "the", "this", "to",
        "tree", "type", "ui", "undo", "user", "view", "virtual", "window", "with", "word",
        "world", "write", "yes", "you"
    ]

    public init(words: Set<String> = CustomDictionarySpellChecker.defaultWords) {
        self.dictionary = Set(words.map { $0.lowercased() })
    }

    public func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        lock.lock()
        let dict = dictionary
        let ign = ignored
        lock.unlock()

        var ranges: [Range<Int>] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].isLetter {
                let start = idx
                while idx < text.endIndex && (text[idx].isLetter || text[idx] == "'") {
                    idx = text.index(after: idx)
                }
                let word = String(text[start..<idx]).lowercased()
                if !word.isEmpty && !dict.contains(word) && !ign.contains(word) {
                    let lo = text.utf8.distance(from: text.utf8.startIndex, to: start.samePosition(in: text.utf8)!)
                    let hi = text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
                    ranges.append(lo..<hi)
                }
            } else {
                idx = text.index(after: idx)
            }
        }
        return ranges
    }

    public func suggestions(for word: String) -> [String] {
        lock.lock()
        let dict = dictionary
        lock.unlock()

        let target = word.lowercased()
        if dict.contains(target) { return [] }
        let scored = dict.compactMap { candidate -> (String, Int)? in
            let d = Self.levenshtein(target, candidate)
            return d <= 2 ? (candidate, d) : nil
        }
        return scored
            .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0 < b.0 }
            .prefix(5)
            .map(\.0)
    }

    public func learnWord(_ word: String) {
        lock.lock()
        defer { lock.unlock() }
        dictionary.insert(word.lowercased())
    }

    public func ignoreWord(_ word: String) {
        lock.lock()
        defer { lock.unlock() }
        ignored.insert(word.lowercased())
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        for i in 1...aChars.count {
            var curr = Array(repeating: 0, count: bChars.count + 1)
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[bChars.count]
    }
}

#if os(macOS)
/// AppKit `NSSpellChecker` backend on macOS (`rune::spell::macos`).
public final class MacOSSpellChecker: SpellCheckBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var ignored: Set<String> = []
    private let documentTag: Int

    public init() {
        self.documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    public func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        let nsString = text as NSString
        let length = nsString.length
        var found: [Range<Int>] = []
        var start = 0

        lock.lock()
        let ign = ignored
        lock.unlock()

        let checker = NSSpellChecker.shared
        while start < length {
            let range = checker.checkSpelling(of: text, startingAt: start)
            if range.location == NSNotFound || range.length == 0 || range.location < start {
                break
            }
            let word = nsString.substring(with: range)
            if !ign.contains(word.lowercased()), let swiftRange = Range(range, in: text) {
                let lo = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.lowerBound.samePosition(in: text.utf8)!)
                let hi = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.upperBound.samePosition(in: text.utf8)!)
                found.append(lo..<hi)
            }
            start = range.location + range.length
        }
        return found
    }

    public func suggestions(for word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: range,
            in: word,
            language: nil,
            inSpellDocumentWithTag: documentTag
        ) ?? []
        return Array(guesses.prefix(5))
    }

    public func learnWord(_ word: String) {
        NSSpellChecker.shared.learnWord(word)
    }

    public func ignoreWord(_ word: String) {
        lock.lock()
        ignored.insert(word.lowercased())
        lock.unlock()
        NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: documentTag)
    }
}
#elseif canImport(UIKit) && !os(watchOS)
/// UIKit `UITextChecker` backend on iOS/iPadOS/visionOS (`rune::spell::ios`).
public final class UIKitSpellChecker: SpellCheckBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var ignored: Set<String> = []
    private var learned: Set<String> = []

    public init() {}

    private static var defaultLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en_US"
    }

    private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }

    public func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        let lang = Self.defaultLanguage

        lock.lock()
        let ign = ignored
        let lrn = learned
        lock.unlock()

        return Self.onMain {
            let nsString = text as NSString
            let length = nsString.length
            var found: [Range<Int>] = []
            var start = 0
            let checker = UITextChecker()
            while start < length {
                let range = checker.rangeOfMisspelledWord(
                    in: text,
                    range: NSRange(location: 0, length: length),
                    startingAt: start,
                    wrap: false,
                    language: lang
                )
                if range.location == NSNotFound || range.length == 0 || range.location < start {
                    break
                }
                let word = nsString.substring(with: range).lowercased()
                if !ign.contains(word), !lrn.contains(word), let swiftRange = Range(range, in: text) {
                    let lo = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.lowerBound.samePosition(in: text.utf8)!)
                    let hi = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.upperBound.samePosition(in: text.utf8)!)
                    found.append(lo..<hi)
                }
                start = range.location + range.length
            }
            return found
        }
    }

    public func suggestions(for word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        let lang = Self.defaultLanguage
        return Self.onMain {
            let range = NSRange(location: 0, length: (word as NSString).length)
            let guesses = UITextChecker().guesses(
                forWordRange: range,
                in: word,
                language: lang
            ) ?? []
            return Array(guesses.prefix(5))
        }
    }

    public func learnWord(_ word: String) {
        lock.lock()
        learned.insert(word.lowercased())
        lock.unlock()
        Self.onMain {
            UITextChecker.learnWord(word)
        }
    }

    public func ignoreWord(_ word: String) {
        lock.lock()
        ignored.insert(word.lowercased())
        lock.unlock()
    }
}
#endif

/// Facade for spellchecking, language selection, and word learning (`rune::spell`).
public final class SpellChecker: @unchecked Sendable {
    #if os(macOS)
    public static let shared = SpellChecker(backend: MacOSSpellChecker())
    #elseif canImport(UIKit) && !os(watchOS)
    public static let shared = SpellChecker(backend: UIKitSpellChecker())
    #else
    public static let shared = SpellChecker(backend: CustomDictionarySpellChecker())
    #endif

    private static let dialects: [String: String] = [
        "ar-001": "Modern Standard Arabic",
        "de-AT": "Austrian German",
        "de-CH": "Swiss High German",
        "en-AU": "Australian English",
        "en-CA": "Canadian English",
        "en-GB": "British English",
        "en-US": "American English",
        "es-419": "Latin American Spanish",
        "es-ES": "European Spanish",
        "es-MX": "Mexican Spanish",
        "fa-AF": "Dari",
        "fr-CA": "Canadian French",
        "fr-CH": "Swiss French",
        "nl-BE": "Flemish",
        "pt-BR": "Brazilian Portuguese",
        "pt-PT": "European Portuguese",
        "ro-MD": "Moldovan Romanian",
        "sw-CD": "Congo Swahili",
        "zh-Hans": "Simplified Chinese",
        "zh-Hant": "Traditional Chinese"
    ]

    private let lock = NSLock()
    private var backend: any SpellCheckBackend
    private var chosenLanguages: [String] = []
    private var availableList: [String] = ["en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "ja-JP", "zh-Hans"]
    private var wordCache: [String: Bool] = [:]
    private var generation: UInt64 = 0

    public static let maxSuggestions = 5

    public init(backend: any SpellCheckBackend) {
        self.backend = backend
    }

    public func setBackend(_ backend: any SpellCheckBackend) {
        lock.lock()
        defer { lock.unlock() }
        self.backend = backend
        self.wordCache.removeAll(keepingCapacity: true)
        self.generation &+= 1
    }

    public func setLanguages(_ tags: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if chosenLanguages != tags {
            chosenLanguages = tags
            wordCache.removeAll(keepingCapacity: true)
            generation &+= 1
        }
    }

    public func setAvailableLanguages(_ tags: [String]) {
        lock.lock()
        defer { lock.unlock() }
        availableList = tags
        wordCache.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    /// Available system spellcheck language tags (`rune::spell::available_languages`).
    public func availableLanguages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return availableList
    }

    /// Active spellcheck languages (`chosen ∩ available`, else locale defaults + `en-US`) (`rune::spell::languages`).
    public func languages() -> [String] {
        lock.lock()
        let chosen = chosenLanguages
        let available = availableList
        lock.unlock()
        if !chosen.isEmpty {
            let intersection = chosen.filter { c in
                available.contains { $0.caseInsensitiveCompare(c) == .orderedSame }
            }
            if !intersection.isEmpty {
                return intersection
            }
        }
        var defaults: [String] = []
        for pref in Locale.preferredLanguages {
            if let match = available.first(where: { $0.caseInsensitiveCompare(pref) == .orderedSame })
                ?? available.first(where: { $0.lowercased().split(separator: "-").first == pref.lowercased().split(separator: "-").first }) {
                if !defaults.contains(match) {
                    defaults.append(match)
                }
            }
        }
        if !defaults.contains(where: { $0.lowercased().hasPrefix("en") }) {
            defaults.append("en-US")
        }
        return defaults
    }

    public func languageName(for tag: String) -> String {
        for (k, v) in Self.dialects where k.caseInsensitiveCompare(tag) == .orderedSame {
            return v
        }
        return tag
    }

    public func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        lock.lock()
        let b = backend
        lock.unlock()
        return b.misspelledUTF8Ranges(in: text)
    }

    public func suggestions(for word: String) -> [String] {
        lock.lock()
        let b = backend
        lock.unlock()
        return b.suggestions(for: word)
    }

    public func learnWord(_ word: String) {
        lock.lock()
        let b = backend
        lock.unlock()
        b.learnWord(word)
    }

    public func ignoreWord(_ word: String) {
        lock.lock()
        let b = backend
        lock.unlock()
        b.ignoreWord(word)
    }
}

// MARK: - Shortcuts, Chords & Global/Scoped Registry (`rune::shortcuts`)

/// Scope in which a shortcut registration is active.
public enum ShortcutScope: Sendable, Hashable {
    case global
    case window(String)
    case context(String)
}

/// A sequence of one or more `Chord`s (e.g. `Cmd+K` then `Cmd+S`).
public struct ShortcutSequence: Sendable, Hashable {
    public var chords: [Chord]

    public init(_ chords: [Chord]) {
        self.chords = chords
    }

    public init?(parsing spec: String) {
        let parts = spec
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var parsed: [Chord] = []
        for part in parts {
            guard let chord = Chord(parsing: part) else { return nil }
            parsed.append(chord)
        }
        self.chords = parsed
    }

    /// Formats a chord in compact macOS symbol style (`⌘⇧P`) or cross-platform style (`Ctrl+Shift+P`).
    public static func formatDisplay(_ chord: Chord, macOSSymbols: Bool = true) -> String {
        if macOSSymbols {
            var prefix = ""
            if chord.mods.ctrl { prefix += "⌃" }
            if chord.mods.alt { prefix += "⌥" }
            if chord.mods.shift { prefix += "⇧" }
            if chord.mods.cmd || chord.mods.logo { prefix += "⌘" }
            return prefix + keyDisplay(chord.key, macOSSymbols: true)
        }
        return chord.description
    }

    public static func formatDisplay(_ sequence: ShortcutSequence, macOSSymbols: Bool = true) -> String {
        sequence.chords
            .map { formatDisplay($0, macOSSymbols: macOSSymbols) }
            .joined(separator: " ")
    }

    private static func keyDisplay(_ key: Key, macOSSymbols: Bool) -> String {
        switch key {
        case .command(let ch): return String(ch).uppercased()
        case .text(let s): return s.uppercased()
        case .enter: return macOSSymbols ? "↩" : "Enter"
        case .tab: return macOSSymbols ? "⇥" : "Tab"
        case .escape: return macOSSymbols ? "⎋" : "Esc"
        case .backspace: return macOSSymbols ? "⌫" : "Backspace"
        case .delete: return macOSSymbols ? "⌦" : "Delete"
        case .insert: return "Insert"
        case .space: return macOSSymbols ? "Space" : "Space"
        case .arrowLeft: return macOSSymbols ? "←" : "Left"
        case .arrowRight: return macOSSymbols ? "→" : "Right"
        case .arrowUp: return macOSSymbols ? "↑" : "Up"
        case .arrowDown: return macOSSymbols ? "↓" : "Down"
        case .home: return macOSSymbols ? "↖" : "Home"
        case .end: return macOSSymbols ? "↘" : "End"
        case .pageUp: return macOSSymbols ? "⇞" : "PageUp"
        case .pageDown: return macOSSymbols ? "⇟" : "PageDown"
        case .f(let n): return "F\(n)"
        case .contextMenu: return "Menu"
        case .printScreen: return "Print Screen"
        case .scrollLock: return "Scroll Lock"
        case .pause: return "Pause"
        case .modifier: return ""
        }
    }
}

/// Shortcut registration errors (`rune::shortcuts::ShortcutError`).
public enum ShortcutError: Error, Sendable, Equatable {
    case conflict(existingId: String)
    case invalidAccelerator(String)
    case unknownId(String)
    case unmodifiedDisallowed
    case alreadyInUse(owner: String?)
    case rejectedByOS(String)
}

/// Outcome of dispatching a `KeyEvent` through `ShortcutRegistry`.
public enum ShortcutDispatchResult: Sendable, Equatable {
    case handled(id: String)
    case pendingChord
    case unhandled
}

/// Global and scoped shortcut registry with chord-sequence support, conflict detection, and display formatting.
public final class ShortcutRegistry: @unchecked Sendable {
    public struct Entry: Sendable {
        public let id: String
        public let sequence: ShortcutSequence
        public let scope: ShortcutScope
        public let label: String
        public let handler: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var pendingEvents: [KeyEvent] = []
    public var allowUnmodifiedGlobal: Bool = false

    public init() {}

    @discardableResult
    public func register(
        id: String,
        accelerator: String,
        scope: ShortcutScope = .global,
        label: String = "",
        allowUnmodified: Bool = false,
        handler: @escaping @Sendable () -> Void
    ) -> Result<String, ShortcutError> {
        guard let sequence = ShortcutSequence(parsing: accelerator) else {
            return .failure(.invalidAccelerator(accelerator))
        }

        lock.lock()
        defer { lock.unlock() }

        if scope == .global && !allowUnmodified && !allowUnmodifiedGlobal {
            if let first = sequence.chords.first, !Self.isModifiedOrFunction(first) {
                return .failure(.unmodifiedDisallowed)
            }
        }

        if let conflict = entries.first(where: { $0.scope == scope && $0.sequence == sequence }) {
            return .failure(.conflict(existingId: conflict.id))
        }

        entries.append(Entry(
            id: id,
            sequence: sequence,
            scope: scope,
            label: label.isEmpty ? id : label,
            handler: handler
        ))
        return .success(id)
    }

    @discardableResult
    public func unregister(id: String) -> Result<Void, ShortcutError> {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            return .failure(.unknownId(id))
        }
        entries.remove(at: idx)
        return .success(())
    }

    public func registeredEntries(in scope: ShortcutScope? = nil) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let scope {
            return entries.filter { $0.scope == scope }
        }
        return entries
    }

    public func resetPendingSequence() {
        lock.lock()
        defer { lock.unlock() }
        pendingEvents.removeAll()
    }

    /// Dispatches `event` against active scopes (in priority order), advancing or completing multi-chord sequences.
    public func dispatch(
        _ event: KeyEvent,
        activeScopes: [ShortcutScope] = [.global]
    ) -> ShortcutDispatchResult {
        // Standalone modifier key press/release never advances or cancels a multi-chord sequence.
        if case .modifier = event.key {
            return .unhandled
        }

        lock.lock()
        let candidateEvents = pendingEvents + [event]

        var matchedEntry: Entry? = nil
        var hasPrefixMatch = false

        for scope in activeScopes {
            for entry in entries where entry.scope == scope {
                let target = entry.sequence.chords
                if target.count == candidateEvents.count &&
                    zip(target, candidateEvents).allSatisfy({ $0.matches($1) }) {
                    matchedEntry = entry
                    break
                }
                if target.count > candidateEvents.count &&
                    zip(target.prefix(candidateEvents.count), candidateEvents).allSatisfy({ $0.matches($1) }) {
                    hasPrefixMatch = true
                }
            }
            if matchedEntry != nil { break }
        }

        if let matched = matchedEntry {
            pendingEvents.removeAll()
            lock.unlock()
            matched.handler()
            return .handled(id: matched.id)
        }

        if hasPrefixMatch {
            pendingEvents = candidateEvents
            lock.unlock()
            return .pendingChord
        }

        pendingEvents.removeAll()
        lock.unlock()
        return .unhandled
    }

    private static func isModifiedOrFunction(_ chord: Chord) -> Bool {
        if chord.mods.cmd || chord.mods.ctrl || chord.mods.alt || chord.mods.logo {
            return true
        }
        if case .f = chord.key {
            return true
        }
        return false
    }
}
