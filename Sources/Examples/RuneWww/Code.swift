import Foundation
import Rune
import RuneKit

/// Code snippets sliced from Rune's upstream examples & motion tests (`www/app/src/code.rs`).
public enum WwwCode {
    public enum End: Sendable {
        case until(String)
        case to(String)
        case brace
    }

    public struct Cut: Equatable, Sendable {
        public var code: String
        public var start: Int
        public var end: Int
    }

    public struct Snippet: Sendable {
        public var file: String
        public var source: String
        public var from: String
        public var end: End

        public func cut() -> Cut? {
            let trimmedSource = source.hasSuffix("\n") ? String(source.dropLast()) : source
            let lines = trimmedSource.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let first = lines.firstIndex(where: { $0.hasPrefix(from) }) else { return nil }
            var start = first
            while start > 0 && lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#[") {
                start -= 1
            }
            let base = WwwCode.indent(lines[first])
            var end: Int
            switch self.end {
            case .until(let marker):
                guard let rel = lines[(first + 1)...].firstIndex(where: { $0.hasPrefix(marker) }) else {
                    return nil
                }
                end = rel - 1
                while end > first && lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                    end -= 1
                }
            case .to(let marker):
                guard let found = lines[(first + 1)...].firstIndex(where: { $0.hasPrefix(marker) }) else {
                    return nil
                }
                end = found
            case .brace:
                guard let found = lines[(first + 1)...].firstIndex(where: {
                    WwwCode.indent($0) == base && $0.trimmingCharacters(in: .whitespaces) == "}"
                }) else {
                    return nil
                }
                end = found
            }

            let pad = (start...end)
                .filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
                .map { WwwCode.indent(lines[$0]) }
                .min() ?? 0
            var out = (start...end).map { i -> String in
                let l = lines[i]
                if l.count > pad {
                    return String(l.dropFirst(pad))
                }
                return ""
            }
            let joined = out.joined(separator: "\n")
            let openCount = joined.filter { $0 == "{" }.count
            let closeCount = joined.filter { $0 == "}" }.count
            if openCount > closeCount {
                let leadCount = max(0, WwwCode.indent(lines[first]) - pad)
                let lead = String(repeating: " ", count: leadCount)
                out.append("\(lead)    // …")
                out.append("\(lead)}")
            }
            return Cut(code: out.joined(separator: "\n"), start: start + 1, end: end + 1)
        }
    }

    private static func indent(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " || ch == "\t" { count += 1 } else { break }
        }
        return count
    }

    public static let helloSource: String = #"""
//! The smallest Rune app: one piece of state, a view of it, and a switch that flips it on a spring.
//! `cargo run -p hello` opens the window; `-- --snap hello.png --scene on` renders it headless.

use rune::tok::{self, motion, type_};
use rune::{AppSpec, Cx, El, col, el, text};

#[derive(Default)]
struct State {
    on: bool,
}

fn view(s: &State, _: &mut Cx<State>) -> El {
    let t = tok::theme(true);
    let label = text(if s.on { "Lights on" } else { "Lights off" })
        .font(type_::TITLE).color(t.text);
    let knob = el().key("knob").size(18.0, 18.0).radius(9.0).fill(t.knob)
        .absolute(if s.on { 18.0 } else { 2.0 }, 2.0);
    // Screen readers hear "Lights, switch, on": the label names it, `checked` says its state.
    let switch = el().key("switch").role("switch").label("Lights").checked(s.on).focusable(true).size(38.0, 22.0).radius(11.0)
        .fill(if s.on { tok::accent(0, true) } else { t.control_off })
        .motion(motion::SNAPPY)
        .on_press(|s: &mut State| s.on = !s.on)
        .child(knob);
    col().w_full().h_full().center().gap(16.0).fill(t.bg).child(label).child(switch)
}

fn main() {
    rune::run(AppSpec::<State> {
        scenes: &[("on", |s| s.on = true)],
        ..AppSpec::new("Hello", (320.0, 200.0), State::default, view)
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use rune::{Env, Runtime};

    #[test]
    fn a_tap_flips_the_switch_and_the_knob_springs_across() {
        let env = Env { system_dark: true, scale: 2.0 };
        let mut rt = Runtime::new(State::default(), view, (320.0, 200.0), env);
        rt.frame(0.0);
        let knob_x = |rt: &Runtime<State>| rt.presented("knob").unwrap().0[0];
        let off = knob_x(&rt);

        let (x, y) = rt.find("switch").unwrap();
        rt.pointer_down(x, y);
        rt.pointer_up(x, y);
        for _ in 0..6 { rt.frame(1.0 / 60.0); }
        assert!(rt.state.on);
        let mid = knob_x(&rt);
        for _ in 0..60 { rt.frame(1.0 / 60.0); }
        let on = knob_x(&rt);
        assert!(off < mid && mid < on, "the knob travels: {off} → {mid} → {on}");
        assert!((on - off - 16.0).abs() < 0.01, "and lands 16 points over");
    }
}
"""#

    public static let springTestsSource: String = #"""
#[test]
fn animated_value_retargets_keeping_velocity() {
    let mut a = Animated::new(0.0f32);
    a.animate_to(100.0, motion::GLIDE, 0.0);
    let (x1, v1) = (a.sample(0.1), a.velocity(0.1));
    a.animate_to(-50.0, motion::GLIDE, 0.1);
    assert!((a.sample(0.1) - x1).abs() < 1e-4);
    assert!((a.velocity(0.1) - v1).abs() < 1e-2);
    a.retarget(-50.0, 0.2); // unchanged: no-op
    assert!(a.is_settled(5.0));
    assert!((a.sample(5.0) + 50.0).abs() < 1e-3);
}
"""#

    public static let helloView = Snippet(
        file: "examples/hello/src/main.rs",
        source: helloSource,
        from: "fn view(",
        end: .until("fn main()")
    )

    public static let helloTest = Snippet(
        file: "examples/hello/src/main.rs",
        source: helloSource,
        from: "    fn a_tap_flips_the_switch",
        end: .brace
    )

    public static let retarget = Snippet(
        file: "crates/rune-motion/tests/spring.rs",
        source: springTestsSource,
        from: "fn animated_value_retargets_keeping_velocity",
        end: .to("    assert!((a.velocity(0.1) - v1).abs()")
    )

    private static func paint(_ kind: Syntax) -> Color {
        switch kind {
        case .keyword: return WwwTokens.codeKeyword
        case .string, .number: return WwwTokens.codeString
        case .function: return WwwTokens.codeCall
        case .comment: return WwwTokens.fg3
        case .punctuation: return WwwTokens.fg2
        default: return WwwTokens.fg
        }
    }

    public static func colored(_ code: String) -> [RichSpan] {
        SyntaxHighlighter.builtin.highlight(language: "rust", code: code).map { item in
            let color: Color = switch item.paint {
            case .kind(let k): paint(k)
            case .color(let c): c
            }
            return RichSpan(item.range).color(color)
        }
    }

    public static func block(_ key: String, snippet: Snippet) -> El<WwwState> {
        guard let cut = snippet.cut() else {
            return col().key(key)
        }
        let href = "\(WwwConstants.repo)/blob/dev/\(snippet.file)#L\(cut.start)-L\(cut.end)"
        let fileLabel = "\(snippet.file):\(cut.start)–\(cut.end)"
        let linesFrom = snippet.file.utf8.count
        let fileBytes = fileLabel.utf8.count

        let head: El<WwwState> = row()
            .key("head")
            .wFull()
            .justifyBetween()
            .gap(16.0)
            .px(16.0)
            .py(8.0)
            .child(
                row()
                    .key("source")
                    .href(href)
                    .shrink()
                    .hoverGroup()
                    .child(
                        rich(fileLabel, [
                            RichSpan(0..<linesFrom).color(WwwTokens.fg2),
                            RichSpan(linesFrom..<fileBytes).color(WwwTokens.fg3),
                        ])
                        .font(WwwTokens.mono12)
                        .color(WwwTokens.fg2)
                        .wrapAnywhere()
                        .shrink()
                        .groupColor(WwwTokens.fg)
                    )
            )
            .child(text("Rust").font(WwwTokens.mono12).color(WwwTokens.fg3))

        let body: El<WwwState> = col()
            .key("scroll")
            .wFull()
            .scrollX()
            .child(
                rich(cut.code, colored(cut.code))
                    .key("code")
                    .font(WwwTokens.code)
                    .color(WwwTokens.fg)
                    .selectable(true)
                    .p(16.0)
            )

        return col()
            .key(key)
            .htmlRole("figure")
            .wFull()
            .minW(0.0)
            .rounded(WwwTokens.r2)
            .bg(WwwTokens.surface1)
            .border(1.0, WwwTokens.line)
            .clipRounded(WwwTokens.r2)
            .child(head)
            .child(WwwUI.hairline("rule"))
            .child(body)
    }
}
