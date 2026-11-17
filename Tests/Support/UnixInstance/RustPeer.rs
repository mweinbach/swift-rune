// build-rust-peer.sh places the pinned instance and relaunch modules beside this harness.
use std::io::{self, BufRead, Write};
use std::sync::atomic::{AtomicBool, Ordering};

extern crate self as libc;
unsafe extern "C" {
    pub fn getuid() -> u32;
}

mod open_url {
    pub mod instance;
    pub mod incoming {
        pub fn receive(link: String) { crate::event(&format!("url {link}")); }
    }
}
mod marks { pub fn mark(_: &str) {} }
mod quit {
    pub fn quitting() -> bool { crate::QUITTING.load(crate::Ordering::Acquire) }
}
mod relaunch;

static QUITTING: AtomicBool = AtomicBool::new(false);

fn event(text: &str) {
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{text}").unwrap();
    stdout.flush().unwrap();
}

fn main() {
    let id = std::env::var("RUNE_INSTANCE_TEST_ID").unwrap();
    event("claiming");
    if !open_url::instance::single_instance(&id) {
        event("delivered");
        return;
    }
    open_url::instance::on_relaunch(|| { event("reopen"); true });
    event("owner");
    for command in io::stdin().lock().lines() {
        match command.unwrap().as_str() {
            "listen" => event("listening"),
            "quit" => { QUITTING.store(true, Ordering::Release); event("quitting"); }
            "release" => { open_url::instance::release_instance(); event("released"); }
            "exit" => break,
            _ => panic!("unknown command"),
        }
    }
    open_url::instance::release_instance();
}
