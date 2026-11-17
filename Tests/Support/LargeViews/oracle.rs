fn capture_scroll<S: 'static>(rt: &Runtime<S>, case: &str, frame: usize, width: u32, height: u32) {
    use rune::render::cpu_boot::{paint, Scene, Target};

    let Some(output) = std::env::var_os("RUNE_SCROLL_CAPTURE") else { return };
    if ![0, 1, 24, 60, 300, 600].contains(&frame) { return; }
    let role = if case == "table" { "row" } else { "treeitem" };
    let rows: Vec<_> = rt.elements().into_iter().filter(|e| !e.exiting && e.role == role)
        .map(|e| serde_json::json!({
            "key": e.key, "label": e.label, "rect": e.rect, "visible": e.visible,
        })).collect();
    let base = std::path::PathBuf::from(output).join(format!("{case}-{frame}"));
    let summary = serde_json::json!({"scene": [width, height], "count": rows.len(), "rows": rows,
                                     "nativeInstances": rt.instances.len()});
    std::fs::write(base.with_extension("json"), serde_json::to_vec(&summary).unwrap()).unwrap();
    if frame == 0 || frame == 60 {
        let scene = Scene::new(&rt.instances, &rt.text.atlas, &rt.images, (width, height), rt.clear_color())
            .srgb_blend(rt.srgb_blend()).font_smoothing(rt.font_smoothing());
        let mut bgra = vec![0; width as usize * height as usize * 4];
        paint(&scene, &mut Target::new(&mut bgra, width, height), 1).unwrap();
        for p in bgra.chunks_exact_mut(4) { p.swap(0, 2); }
        std::fs::write(base.with_extension("rgba"), bgra).unwrap();
    }
}
