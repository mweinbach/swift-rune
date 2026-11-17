// Appended to the pinned upstream fixture by rust-native.py.
use std::{cell::RefCell, ffi::{CString, c_char, c_void}, rc::Rc, time::Instant};

unsafe extern "C" {
    fn rust_observe_presentations(path: *const c_char);
    fn rust_wheel();
    fn rust_wheels_submitted() -> u32;
    fn rust_finish(callback: unsafe extern "C" fn(*mut c_void), context: *mut c_void);
}

unsafe extern "C" fn quit(context: *mut c_void) {
    let handle = unsafe { Box::from_raw(context.cast::<rune::AppHandle<App>>()) };
    handle.quit();
}

fn main() {
    let output = std::path::PathBuf::from(std::env::var_os("RUNE_SCROLL_OUTPUT").unwrap());
    let csv = CString::new(output.with_extension("csv").as_os_str().as_encoded_bytes()).unwrap();
    unsafe { rust_observe_presentations(csv.as_ptr()); }
    let mut spec = rune::AppSpec::new(TITLE, SIZE, initial, authored_view);
    spec.min_size = Some(SIZE);
    let app = rune::App::new(spec);
    let handle = app.handle();
    let reports = Rc::new(RefCell::new(Vec::new()));
    let encoded = reports.clone();
    let start = Instant::now();
    let mut requested = 0;
    let mut finished = false;
    let mut checkpoints = Vec::new();
    app.on_frame_encoded(move |frame| {
        encoded.borrow_mut().push(serde_json::json!({
            "wheel": unsafe { rust_wheels_submitted() }, "outcome": format!("{:?}", frame.outcome()),
            "at": frame.at().duration_since(start).as_secs_f64(),
            "updateMS": frame.update_ms(), "encodeMS": frame.encode_ms(),
        }));
    }).on_frame_drawn(move |rt| {
        let step = unsafe { rust_wheels_submitted() };
        if finished || step < requested { return; }
        if [0, 1, 24, 60, 300, 600].contains(&step) {
            let rows: Vec<_> = rt.elements().into_iter().filter(|e| !e.exiting && e.role == ROW_ROLE).collect();
            let mut visible: Vec<_> = rows.iter().filter(|e| {
                e.key.as_deref() != Some("header") && e.visible[2] > 0. && e.visible[3] > 0.
            }).collect();
            visible.sort_by(|a, b| a.visible[1].total_cmp(&b.visible[1]));
            checkpoints.push(serde_json::json!({
                "wheel": step, "mounted": rows.len(), "nativeInstances": rt.instances.len(),
                "visible": visible.iter().map(|e| serde_json::json!([e.key, e.visible])).collect::<Vec<_>>(),
            }));
        }
        if step == 600 {
            let data = serde_json::json!({"events": step, "checkpoints": checkpoints, "reports": *reports.borrow()});
            std::fs::write(&output, serde_json::to_vec(&data).unwrap()).unwrap();
            finished = true;
            unsafe { rust_finish(quit, Box::into_raw(Box::new(handle.clone())).cast()); }
        } else {
            requested += 1;
            unsafe { rust_wheel(); }
        }
    }).run();
}
