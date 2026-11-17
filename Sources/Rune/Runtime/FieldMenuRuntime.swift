import Foundation

extension Runtime {
    private func resolveNearestOnSpellcheck(
        from startIdx: Int
    ) -> (enabled: Bool, handler: (inout State, Bool, inout Tx) -> Void)? {
        var cur: Int? = startIdx
        while let i = cur, flatNodes.indices.contains(i) {
            let h = flatNodes[i].el.handlers
            if let enabled = h.onSpellcheckEnabled, let fn = h.onSpellcheck {
                return (enabled, fn)
            }
            cur = flatNodes[i].parentIndex
        }
        return nil
    }

    private func resolveNearestOnSpellcheckLanguages(
        from startIdx: Int
    ) -> ((inout State, [String], inout Tx) -> Void)? {
        var cur: Int? = startIdx
        while let i = cur, flatNodes.indices.contains(i) {
            if let fn = flatNodes[i].el.handlers.onSpellcheckLanguages {
                return fn
            }
            cur = flatNodes[i].parentIndex
        }
        return nil
    }

    /// Opens a text field's standard context menu at `windowPos` (`runtime/input/field_menu.rs`).
    @discardableResult
    internal func openFieldMenu(
        node: FlatNode,
        at windowPos: Vec2,
        fromPointer: Bool,
        at now: Double
    ) -> Bool {
        guard let editLens = node.el.handlers.editLens else { return false }
        var edit = editLens.get(state)
        let isSecure = node.el.isSecure || edit.isSecure
        if isSecure {
            edit.isSecure = true
            if node.el.isRevealed { edit.isRevealed = true }
        }

        let spellEnabled = (node.el.spellcheck || node.el.isSpellcheck) && !isSecure

        if fromPointer {
            let hit = textCaretHit(node: node, windowPos: windowPos, edit: edit)
            let offset = hit.utf8Offset
            let sel = edit.selectedUTF8Range
            if !edit.hasSelection || offset < sel.lowerBound || offset > sel.upperBound {
                var hitWordRange: Range<Int>? = nil
                if spellEnabled {
                    var spellProbe = edit
                    spellProbe.spellcheckEnabled = true
                    hitWordRange = spellProbe.spellingSuggestions(atUTF8Offset: offset)?.range
                }
                if let range = hitWordRange {
                    edit.setCursor(utf8Offset: range.lowerBound, extendSelection: false)
                    edit.setCursor(utf8Offset: range.upperBound, extendSelection: true)
                } else {
                    edit.setCursor(hit)
                }
                editLens.set(&state, edit)
            }
            if focusedPath != node.path {
                let prevNode = focusedPath.flatMap { nodeByPath[$0] }.map { flatNodes[$0] }
                handleKitFocusTransition(prevNode: prevNode, newPath: node.path, at: now)
                focusedPath = node.path
                focusedKey = node.key
                focusedLinkIndex = nil
                imeReset = true
            }
            focusVisible = false
            hoveredHighlightActive = false
        }

        let spellToggle = resolveNearestOnSpellcheck(from: node.index)
        let languagesHook = resolveNearestOnSpellcheckLanguages(from: node.index)

        var checkEdit = edit
        checkEdit.spellcheckEnabled = spellEnabled
        let spellingHit: (range: Range<Int>, word: String, suggestions: [String])? = spellEnabled
            ? {
                guard let hit = checkEdit.spellingSuggestions(atUTF8Offset: edit.cursor) else { return nil }
                if edit.hasSelection && edit.selectedUTF8Range != hit.range { return nil }
                return hit
            }()
            : nil

        var menu = PopupMenu()
        if let hit = spellingHit {
            if hit.suggestions.isEmpty {
                menu = menu.item("no-guesses", RuneLabels.shared.label(for: .noGuesses), enabled: false)
            } else {
                for (i, guess) in hit.suggestions.enumerated() {
                    menu = menu.item("suggestion-\(i)", guess)
                }
            }
            menu = menu
                .separator()
                .item("learn-spelling", RuneLabels.shared.label(for: .learnSpelling))
                .separator()
        }

        let canCopyCut = edit.hasSelection && !isSecure
        let pasteContent = boundClipboard?.readRich(sanitizeUntrustedHTML: true).content ?? clipboard
        let canPaste = !pasteContent.text.isEmpty
            || !(pasteContent.html ?? "").isEmpty
            || !(pasteContent.rtf ?? "").isEmpty
            || pasteContent.image != nil
        menu = menu
            .item("cut", RuneLabels.shared.label(for: .cut), enabled: canCopyCut, keyEquivalent: "mod+x")
            .item("copy", RuneLabels.shared.label(for: .copy), enabled: canCopyCut, keyEquivalent: "mod+c")
            .item("paste", RuneLabels.shared.label(for: .paste), enabled: canPaste, keyEquivalent: "mod+v")
        #if !os(macOS)
        menu = menu.item("select-all", RuneLabels.shared.label(for: .selectAll), enabled: !edit.text.isEmpty, keyEquivalent: "mod+a")
        #endif

        var capturedLanguages: [String] = []
        if let toggle = spellToggle {
            menu = menu
                .separator()
                .item("spellcheck", RuneLabels.shared.label(for: .spellcheck), checked: toggle.enabled)
        }
        let availableLanguages = SpellChecker.shared.availableLanguages()
        if languagesHook != nil && !availableLanguages.isEmpty {
            if spellToggle == nil {
                menu = menu.separator()
            }
            let current = SpellChecker.shared.languages()
            capturedLanguages = current
            let localeId = RuneLabels.shared.locale
            let named = availableLanguages.map { tag -> (tag: String, title: String) in
                let labelTitle = RuneLabels.shared.label(for: .language(tag))
                let custom = (labelTitle != tag) ? labelTitle : nil
                let localized = localeId.flatMap { Locale(identifier: $0).localizedString(forIdentifier: tag) }
                return (tag, custom ?? localized ?? SpellChecker.shared.languageName(for: tag))
            }.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            var sub = PopupMenu()
            for entry in named {
                let isChecked = current.contains { $0.caseInsensitiveCompare(entry.tag) == .orderedSame }
                let onlyChecked = isChecked && current.count == 1
                sub = sub.item(
                    "language-\(entry.tag)",
                    entry.title,
                    enabled: !onlyChecked,
                    checked: isChecked
                )
            }
            menu = menu.submenu(
                RuneLabels.shared.label(for: .spellcheckLanguages),
                sub,
                enabled: spellToggle?.enabled ?? true
            )
        }

        let targetPath = node.path
        let targetWordRange = spellingHit?.range
        let targetWord = spellingHit?.word
        let targetSuggestions = spellingHit?.suggestions ?? []

        enqueuePopupRequest(ErasedPopupRequest(
            menu: menu,
            anchor: .point(windowPos.x, windowPos.y),
            onPick: { [weak self] _, pickedId, tx in
                guard let self, let pickedId else { return }
                self.handleFieldMenuPick(
                    targetPath: targetPath,
                    pickedId: pickedId,
                    wordRange: targetWordRange,
                    word: targetWord,
                    suggestions: targetSuggestions,
                    spellToggle: spellToggle,
                    capturedLanguages: capturedLanguages,
                    languagesHook: languagesHook,
                    tx: &tx
                )
            },
            isFieldMenu: true
        ))
        popupNeedsLayout = true
        dirtyCommit(at: now, why: CommitWhy.input)
        return true
    }

    private func handleFieldMenuPick(
        targetPath: String,
        pickedId: String,
        wordRange: Range<Int>?,
        word: String?,
        suggestions: [String],
        spellToggle: (enabled: Bool, handler: (inout State, Bool, inout Tx) -> Void)?,
        capturedLanguages: [String],
        languagesHook: ((inout State, [String], inout Tx) -> Void)?,
        tx: inout Tx
    ) {
        let now = currentTime
        let node = nodeByPath[targetPath].map { flatNodes[$0] }
        #if os(macOS)
        let mods = Mods(cmd: true)
        #else
        let mods = Mods(ctrl: true)
        #endif

        switch pickedId {
        case "cut":
            if let node { _ = applyFocusedTextEditKey(KeyEvent(key: .command("x"), mods: mods), el: node.el, layout: nil, at: now) }
        case "copy":
            if let node { _ = applyFocusedTextEditKey(KeyEvent(key: .command("c"), mods: mods), el: node.el, layout: nil, at: now) }
        case "paste":
            if let node, focusedPath == node.path || nodeByPath[targetPath] != nil {
                if focusedPath != targetPath {
                    focusedPath = targetPath
                    focusedKey = node.key
                }
                _ = pasteClipboardNow(at: now)
            }
        case "select-all":
            if let node { _ = applyFocusedTextEditKey(KeyEvent(key: .command("a"), mods: mods), el: node.el, layout: nil, at: now) }
        case "learn-spelling":
            if let word, !word.isEmpty {
                SpellChecker.shared.learnWord(word)
                dirtyCommit(at: now, why: CommitWhy.input)
            }
        case "spellcheck":
            if let spellToggle {
                spellToggle.handler(&state, !spellToggle.enabled, &tx)
            }
        default:
            if pickedId.hasPrefix("language-"), let hook = languagesHook {
                let tag = String(pickedId.dropFirst("language-".count))
                var updated = capturedLanguages
                if let idx = updated.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    if updated.count > 1 { updated.remove(at: idx) }
                } else {
                    updated.append(tag)
                }
                SpellChecker.shared.setLanguages(updated)
                hook(&state, updated, &tx)
            } else if pickedId.hasPrefix("suggestion-"),
                      let n = Int(pickedId.dropFirst("suggestion-".count)),
                      n >= 0, n < suggestions.count,
                      let wordRange,
                      let node,
                      let editLens = node.el.handlers.editLens {
                let prevEdit = editLens.get(state)
                var nextEdit = prevEdit
                nextEdit.replaceUTF8Range(wordRange, with: suggestions[n])
                deliverInputEdit(el: node.el, previousEdit: prevEdit, newEdit: nextEdit, editLens: editLens, at: now)
            }
        }
    }
}
