//! The core's log: what the protocol library reports at "info" and above,
//! in one file that starts afresh with each launch. It is what gets asked
//! for when something does not connect.

use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

struct FileLog(Mutex<File>);

impl log::Log for FileLog {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) % 86400;
        let mut file = self.0.lock().unwrap();
        // Times are UTC: the core has no business knowing the time zone.
        let _ = writeln!(
            file,
            "{:02}:{:02}:{:02} [{} {}] {}",
            seconds / 3600,
            seconds % 3600 / 60,
            seconds % 60,
            record.target(),
            record.level(),
            record.args()
        );
    }

    fn flush(&self) {
        let _ = self.0.lock().unwrap().flush();
    }
}

/// Starts logging to `core.log` in `dir`. Does nothing if a logger is
/// already installed (a tool that prints the log itself, say).
pub fn start(dir: &Path) {
    let Ok(file) = File::create(dir.join("core.log")) else { return };
    // Leaked on purpose: the logger lives as long as the process.
    let logger: &'static FileLog = Box::leak(Box::new(FileLog(Mutex::new(file))));
    if log::set_logger(logger).is_ok() {
        log::set_max_level(log::LevelFilter::Info);
    }
}
