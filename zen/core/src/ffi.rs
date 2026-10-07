//! The C surface the native apps link against: three functions, JSON in and
//! out. It is the same surface the Go core had, so the macOS app needs no
//! change to run on this one.

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::{json, Value};

use crate::account::{Account, Emit, Request};

type Callback = extern "C" fn(*const c_char);

struct Core {
    base: PathBuf,
    rt: tokio::runtime::Runtime,
    emit: Emit,
    accounts: Mutex<HashMap<String, Arc<Account>>>,
}

static CORE: OnceLock<Core> = OnceLock::new();

impl Core {
    /// While the Rust core is being brought up next to the Go one, its
    /// accounts live in their own folder, so neither touches the other's.
    fn accounts_dir(&self) -> PathBuf {
        self.base.join("accounts-rust")
    }

    fn list(&self) -> Vec<String> {
        let mut ids: Vec<String> = std::fs::read_dir(self.accounts_dir())
            .map(|entries| entries.flatten().filter(|e| e.path().is_dir()).filter_map(|e| e.file_name().into_string().ok()).collect())
            .unwrap_or_default();
        // "main" first, then in creation order (ids are time-based).
        ids.sort_by(|a, b| (a != "main", a).cmp(&(b != "main", b)));
        ids
    }

    fn open(&self, id: &str) -> Result<(), String> {
        if id.is_empty() || id.starts_with('.') || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
            return Err("invalid account id".into());
        }
        let mut accounts = self.accounts.lock().unwrap();
        if accounts.contains_key(id) {
            return Ok(());
        }
        let account = Account::start(id, self.accounts_dir().join(id), self.rt.handle().clone(), self.emit.clone())?;
        accounts.insert(id.to_string(), account);
        Ok(())
    }

    fn call(&self, request: &Request) -> Result<Value, String> {
        match request.cmd.as_str() {
            "set_lang" => {
                crate::i18n::set_language(&request.text);
                Ok(Value::Null)
            }
            "accounts" => Ok(json!(self.list())),
            "open_account" => self.open(&request.account).map(|_| Value::Null),
            "remove_account" => {
                let account = self.accounts.lock().unwrap().remove(&request.account).ok_or("unknown account")?;
                if request.unlink {
                    // Also removes this device from the phone's list.
                    let _ = account.dispatch(&Request { cmd: "logout".into(), ..Default::default() });
                    std::thread::sleep(std::time::Duration::from_millis(800));
                }
                std::fs::remove_dir_all(&account.dir).map_err(|e| e.to_string())?;
                Ok(Value::Null)
            }
            _ => {
                let account = self.accounts.lock().unwrap().get(&request.account).cloned();
                account.ok_or_else(|| format!("unknown account {}", request.account))?.dispatch(request)
            }
        }
    }
}

/// Sets the data folder and where events go. Events arrive on arbitrary
/// threads as JSON; the string is only valid during the callback.
///
/// # Safety
/// `data_dir` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn WAStart(data_dir: *const c_char, callback: Callback) {
    let base = PathBuf::from(CStr::from_ptr(data_dir).to_string_lossy().into_owned());
    let emit: Emit = Arc::new(move |event: Value| {
        if let Ok(text) = CString::new(event.to_string()) {
            callback(text.as_ptr());
        }
    });
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("zen-core").enable_all().build().expect("runtime");
    let core = Core { base, rt, emit, accounts: Mutex::new(HashMap::new()) };
    let _ = std::fs::create_dir_all(core.accounts_dir());
    let _ = CORE.set(core);
}

/// Runs one JSON command and returns a JSON reply to release with `WAFree`.
///
/// # Safety
/// `request` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn WACall(request: *const c_char) -> *mut c_char {
    let text = CStr::from_ptr(request).to_string_lossy();
    let reply = match (CORE.get(), serde_json::from_str::<Request>(&text)) {
        (None, _) => json!({"error": "the core has not been started"}),
        (_, Err(error)) => json!({"error": error.to_string()}),
        (Some(core), Ok(request)) => match core.call(&request) {
            Ok(data) => json!({"ok": true, "data": data}),
            Err(error) => json!({"error": error}),
        },
    };
    CString::new(reply.to_string()).unwrap_or_default().into_raw()
}

/// # Safety
/// `p` must come from `WACall` and not have been freed.
#[no_mangle]
pub unsafe extern "C" fn WAFree(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}
