import Foundation

internal struct FieldMenuContext {
    var path: String
    var misspelledWord: (range: Range<Int>, word: String)?
    var suggestions: [String]
    var spellcheckToggle: SpellcheckToggleBinding?
    var spellcheckLanguages: (current: [String], binding: SpellcheckLanguagesBinding)?
}

extension Runtime {
    private func focusFieldMenuPath(_ path: String, at now: Double) {
        if focusedPath != path {
            imeReset = true
        }
        focusedPath = path
        focusedKey = nodeByPath[path].flatMap { flatNodes[$0].key }
        focusVisible = false
        focusKeyboard = false
        blurredFocusPath = nil
        focusHandoff = false
        clearTabStartFocusPath()
        dirtyCommit(at: now, why: CommitWhy.input)
    }

    /// Opens a text field's context menu (`cut`, `copy`, `paste`, optional `select-all`, spelling suggestions,
    /// and app-level `onSpellcheck` / `onSpellcheckLanguages`) (`runtime/input/field_menu.rs`).
    @discardableResult
    internal func openFieldMenu(
        path: String,
        at windowPos: Vec2,
        localTextPos: Vec2?,
        at now: Double
    ) -> Bool {
        guard let idx = nodeByPath[path], !flatNodes[idx].effectiveInert else { return false }
        let node = flatNodes[idx]
        guard let editLens = node.el.handlers.editLens else { return false }

        let secure = node.el.isSecure || editLens.get(state).isSecure
        let spellEnabled = !secure && (node.el.spellcheck || editLens.get(state).spellcheckEnabled)

        var toggle: SpellcheckToggleBinding? = nil
        var langKeep: SpellcheckLanguagesBinding? = nil
        var walk: Int? = idx
        while let i = walk {
            if toggle == nil, let cb = flatNodes[i].el.handlers.onSpellcheck {
                toggle = SpellcheckToggleBinding(enabled: flatNodes[i].el.isSpellcheck) { anyState, next, tx in
                    guard var typed = anyState as? State else { return }
                    cb(&typed, next, &tx)
                    anyState = typed
                }
            }
            if langKeep == nil, let cb = flatNodes[i].el.handlers.onSpellcheckLanguages {
                langKeep = SpellcheckLanguagesBinding { anyState, tags, tx in
                    guard var typed = anyState as? State else { return }
                    cb(&typed, tags, &tx)
                    anyState = typed
                }
            }
            if toggle != nil && langKeep != nil { break }
            walk = flatNodes[i].parentIndex
        }

        if focusedPath != path {
            focusFieldMenuPath(path, at: now)
        }

        var edit = editLens.get(state)
        edit.isSecure = secure
        edit.spellcheckEnabled = spellEnabled

        if let local = localTextPos, edit.preedit == nil {
            let hitWindow = Vec2(
                (presentedRectByPath[path] ?? node.targetRect).x + local.x,
                (presentedRectByPath[path] ?? node.targetRect).y + local.y
            )
            let caret = textHitOffset(node: node, windowPos: hitWindow, edit: edit)
            let sel = edit.selectedUTF8Range
            if sel.isEmpty || caret < sel.lowerBound || caret > sel.upperBound {
                if spellEnabled,
                   let range = SpellChecker.shared.misspelledUTF8Ranges(in: edit.text)
                    .first(where: { caret >= $0.lowerBound && caret <= $0.upperBound }) {
                    edit.setCursor(utf8Offset: range.lowerBound, extendSelection: false)
                    edit.setCursor(utf8Offset: range.upperBound, extendSelection: true)
                    editLens.set(&state, edit)
                    dirtyCommit(at: now, why: CommitWhy.input)
                } else {
                    edit.setCursor(utf8Offset: caret, extendSelection: false)
                    editLens.set(&state, edit)
                    dirtyCommit(at: now, why: CommitWhy.input)
                }
            }
        }

        let refreshedEdit = editLens.get(state)
        let sel = refreshedEdit.selectedUTF8Range
        var wordInfo: (Range<Int>, String)? = nil
        if spellEnabled && !sel.isEmpty && sel.upperBound <= refreshedEdit.text.utf8.count {
            let misspelled = SpellChecker.shared.misspelledUTF8Ranges(in: refreshedEdit.text)
            if misspelled.contains(sel) {
                let start = refreshedEdit.text.utf8.index(refreshedEdit.text.utf8.startIndex, offsetBy: sel.lowerBound)
                let end = refreshedEdit.text.utf8.index(refreshedEdit.text.utf8.startIndex, offsetBy: sel.upperBound)
                if let lower = start.samePosition(in: refreshedEdit.text),
                   let upper = end.samePosition(in: refreshedEdit.text),
                   lower <= upper {
                    wordInfo = (sel, String(refreshedEdit.text[lower..<upper]))
                }
            }
        }
        let suggestions = wordInfo.map { SpellChecker.shared.suggestions(for: $0.1) } ?? []

        var menu = PopupMenu()
        if wordInfo != nil {
            if suggestions.isEmpty {
                menu = menu.item("no-guesses", RuneLabels.shared.label(for: .noGuesses), enabled: false)
            } else {
                for (n, s) in suggestions.enumerated() {
                    menu = menu.item("suggestion-\(n)", s)
                }
            }
            menu = menu
                .separator()
                .item("learn-spelling", RuneLabels.shared.label(for: .learnSpelling))
                .separator()
        }

        let hasSelection = !sel.isEmpty && !secure
        menu = menu
            .item("cut", RuneLabels.shared.label(for: .cut), enabled: hasSelection)
            .item("copy", RuneLabels.shared.label(for: .copy), enabled: hasSelection)
            .item("paste", RuneLabels.shared.label(for: .paste))
        #if !os(macOS)
        menu = menu.item("select-all", RuneLabels.shared.label(for: .selectAll))
        #endif

        var capturedLanguages: ([String], SpellcheckLanguagesBinding)? = nil
        if let toggle {
            menu = menu
                .separator()
                .item(
                    "spellcheck",
                    RuneLabels.shared.label(for: .spellcheck),
                    checked: toggle.enabled
                )
            let available = SpellChecker.shared.availableLanguages()
            if let langKeep, !available.isEmpty {
                let current = SpellChecker.shared.languages()
                let localeTag = RuneLabels.shared.locale ?? "en"
                func displayName(for tag: String) -> String {
                    let custom = RuneLabels.shared.label(for: .language(tag))
                    if custom != tag { return custom }
                    if let localized = Locale(identifier: localeTag).localizedString(forIdentifier: tag),
                       !localized.isEmpty {
                        return localized
                    }
                    return SpellChecker.shared.languageName(for: tag)
                }
                let sorted = available
                    .map { (name: displayName(for: $0), tag: $0) }
                    .sorted {
                        $0.name.compare($1.name, locale: Locale(identifier: localeTag)) == .orderedAscending
                    }
                var sub = PopupMenu()
                for entry in sorted {
                    let isOnly = current.count == 1 && current.first == entry.tag
                    sub = sub.item(
                        "language-\(entry.tag)",
                        entry.name,
                        enabled: !isOnly,
                        checked: current.contains(entry.tag)
                    )
                }
                menu = menu.submenu(
                    RuneLabels.shared.label(for: .spellcheckLanguages),
                    sub,
                    enabled: toggle.enabled
                )
                capturedLanguages = (current, langKeep)
            }
        }

        pendingCommitKind = pendingCommitKind.instant()
        logInputEvent("field menu \(path)")
        let ctx = FieldMenuContext(
            path: path,
            misspelledWord: wordInfo,
            suggestions: suggestions,
            spellcheckToggle: toggle,
            spellcheckLanguages: capturedLanguages
        )
        let menuId = inputMachines.nextFieldMenuId
        inputMachines.nextFieldMenuId &+= 1
        inputMachines.fieldMenus[menuId] = ctx
        enqueuePopupRequest(ErasedPopupRequest(
            menu: menu,
            anchor: .point(windowPos.x, windowPos.y),
            onPick: { _, _, _ in },
            isFieldMenu: true,
            fieldMenuId: menuId
        ))
        return true
    }

    internal func applyFieldMenuPick(menuId: UInt64, pickedId: String?, at now: Double) {
        guard let menu = inputMachines.fieldMenus.removeValue(forKey: menuId) else { return }
        guard let pickedId else { return }
        if focusedPath != menu.path, nodeByPath[menu.path] != nil {
            focusFieldMenuPath(menu.path, at: now)
        }
        #if os(macOS)
        let cmdMods = Mods(cmd: true)
        #else
        let cmdMods = Mods(ctrl: true)
        #endif

        switch pickedId {
        case "cut":
            _ = keyDown(KeyEvent(key: .command("x"), mods: cmdMods), at: now)
        case "copy":
            _ = keyDown(KeyEvent(key: .command("c"), mods: cmdMods), at: now)
        case "select-all":
            _ = keyDown(KeyEvent(key: .command("a"), mods: cmdMods), at: now)
        case "paste":
            var tx = makeTx(at: now)
            tx.requestPaste()
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: false)
        case "learn-spelling":
            if let word = menu.misspelledWord?.word {
                SpellChecker.shared.learnWord(word)
                dirtyCommit(at: now, why: CommitWhy.input)
            }
        case "spellcheck":
            if let toggle = menu.spellcheckToggle {
                var tx = makeTx(at: now)
                var erased: Any = state
                toggle.call(&erased, !toggle.enabled, &tx)
                if let typed = erased as? State { state = typed }
                applyTx(tx, at: now)
            }
        default:
            if pickedId.hasPrefix("language-"),
               let langs = menu.spellcheckLanguages {
                let tag = String(pickedId.dropFirst("language-".count))
                var next = langs.current
                if let idx = next.firstIndex(of: tag) {
                    next.remove(at: idx)
                } else {
                    next.append(tag)
                }
                SpellChecker.shared.setLanguages(next)
                var tx = makeTx(at: now)
                var erased: Any = state
                langs.binding.call(&erased, next, &tx)
                if let typed = erased as? State { state = typed }
                applyTx(tx, at: now)
                dirtyCommit(at: now, why: CommitWhy.input)
            } else if pickedId.hasPrefix("suggestion-"),
                      let n = Int(pickedId.dropFirst("suggestion-".count)),
                      n >= 0 && n < menu.suggestions.count,
                      let wordRange = menu.misspelledWord?.range,
                      let fPath = focusedPath,
                      let fIdx = nodeByPath[fPath],
                      let editLens = flatNodes[fIdx].el.handlers.editLens {
                let suggestion = menu.suggestions[n]
                var edit = editLens.get(state)
                edit.setCursor(utf8Offset: wordRange.lowerBound, extendSelection: false)
                edit.setCursor(utf8Offset: wordRange.upperBound, extendSelection: true)
                edit.paste(suggestion)
                editLens.set(&state, edit)
                var tx = makeTx(at: now)
                if flatNodes[fIdx].el.layoutAnim == nil { tx.instant() }
                flatNodes[fIdx].el.handlers.onTextChange?(&state, edit.text, &tx)
                _ = flatNodes[fIdx].el.handlers.onInputChange?(&state, edit.text, &tx)
                applyTx(tx, at: now)
                dirtyCommit(at: now, why: CommitWhy.input)
            }
        }
    }
}
