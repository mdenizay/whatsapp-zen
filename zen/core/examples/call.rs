//! A development tool: starts the core on a data folder, opens an account,
//! waits until it is connected, runs JSON commands and prints what comes back.
//!
//!   cargo run -p zen-core --example call -- <data dir> <seconds to stay> '<json command>'...
//!
//! Commands are sent to account "main" unless they name another.

use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use zen_core::ffi::{WACall, WAFree, WAStart};

static CONNECTED: AtomicBool = AtomicBool::new(false);

extern "C" fn on_event(json: *const c_char) {
    let text = unsafe { CStr::from_ptr(json) }.to_string_lossy();
    if text.contains("\"state\":\"connected\"") {
        CONNECTED.store(true, Ordering::SeqCst);
    }
    // Events can carry message text; show their shape, not their content.
    let shown: String = text.chars().take(160).collect();
    println!("event  {shown}");
}

fn call(request: &str) -> String {
    let request = CString::new(request).expect("request");
    unsafe {
        let reply = WACall(request.as_ptr());
        let text = CStr::from_ptr(reply).to_string_lossy().into_owned();
        WAFree(reply);
        text
    }
}

/// With ZEN_LOG set, the protocol library's log lines go to stderr.
struct Stderr;

impl log::Log for Stderr {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Debug
    }

    fn log(&self, record: &log::Record) {
        let filter = std::env::var("ZEN_LOG").unwrap_or_default();
        if filter == "1" || record.target().contains(&filter) || record.args().to_string().to_lowercase().contains(&filter) {
            eprintln!("log    {:<5} {} - {}", record.level(), record.target(), record.args());
        }
    }

    fn flush(&self) {}
}

fn main() {
    if std::env::var_os("ZEN_LOG").is_some() {
        let _ = log::set_logger(&Stderr);
        log::set_max_level(log::LevelFilter::Debug);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (dir, stay) = (args.first().expect("data dir"), args.get(1).and_then(|s| s.parse::<u64>().ok()).unwrap_or(5));
    let dir_c = CString::new(dir.as_str()).expect("dir");
    unsafe { WAStart(dir_c.as_ptr(), on_event) };
    println!("reply  {}", call(r#"{"cmd":"open_account","account":"main"}"#));

    let started = Instant::now();
    while !CONNECTED.load(Ordering::SeqCst) && started.elapsed() < Duration::from_secs(30) {
        std::thread::sleep(Duration::from_millis(100));
    }
    println!("connected: {} after {:.1}s", CONNECTED.load(Ordering::SeqCst), started.elapsed().as_secs_f32());

    for command in args.iter().skip(2) {
        let command = if command.contains("\"account\"") { command.clone() } else { command.replacen('{', "{\"account\":\"main\",", 1) };
        let reply = call(&command);
        let shown: String = reply.chars().take(400).collect();
        println!("reply  {shown}");
        std::thread::sleep(Duration::from_millis(300));
    }
    std::thread::sleep(Duration::from_secs(stay));
}
