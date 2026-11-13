/// Pure Swift 6 Luau interpreter, runtime, and Rune declarative UI bridge.
public enum RuneLuauModule {
    public static let version = "0.1.0"

    /// Every built-in `ui.*` prop name recognized by the runtime (`crates/rune-luau/src/ui/props.rs::prop_names`).
    public static let propNames: [String] = [
        "key",
        "w", "h", "minW", "minH", "maxW", "maxH", "grow", "shrink",
        "pad", "px", "py", "pt", "pr", "pb", "pl",
        "m", "mx", "my", "mt", "mr", "mb", "ml",
        "opacity", "role", "label", "help",
        "gap", "align", "justify", "center", "wrap",
        "fill", "hover", "press", "border", "borderWidth", "radius", "clip",
        "scrollY", "scrollX", "stickBottom", "onPress",
        "color", "size", "weight", "lineHeight", "tracking", "mono",
        "tabular", "noWrap", "truncate", "selectable", "textAlign",
        "count", "estimatedRowHeight", "version", "renderRow", "rowKey", "rowVersions", "onVisibleRows",
        "onHover", "hoverTransition", "hoverGroup", "hoverGroupColor", "revealOnHover",
        "corners", "pin", "shadow", "selected", "focusable", "disabled",
        "helpSide", "fadeOut", "dir",
    ]
}

/// Every built-in `ui.*` prop name recognized by the runtime (`crates/rune-luau/src/ui/props.rs::prop_names`).
public func propNames() -> [String] {
    RuneLuauModule.propNames
}
