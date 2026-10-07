// Package main is the WhatsApp protocol core, built as a C static library
// (-buildmode=c-archive) and linked into the Swift app.
//
// The whole surface is three functions: WAStart sets the data folder and the
// event callback, WACall runs a JSON command and returns a JSON reply, and
// WAFree releases a reply string. Each linked WhatsApp account is an App with
// its own folder; commands and events name theirs in "account".
package main

/*
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
typedef void (*wa_event_cb)(const char*);
typedef void (*wa_video_cb)(const uint8_t*, size_t, int);
static void wa_call_cb(wa_event_cb cb, const char* s) { cb(s); }
*/
import "C"

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"time"
	"unsafe"
)

var (
	baseDir string
	apps    = map[string]*App{}
	appsMu  sync.Mutex
	eventCB C.wa_event_cb
)

// emitRaw sends one JSON event to the host. The host must copy the string
// before returning; it is freed as soon as the callback comes back.
func emitRaw(v any) {
	if eventCB == nil {
		return
	}
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	cs := C.CString(string(b))
	C.wa_call_cb(eventCB, cs)
	C.free(unsafe.Pointer(cs))
}

func accountsDir() string { return filepath.Join(baseDir, "accounts") }

// migrate moves the data of the single-account layout (everything directly in
// the data folder) into accounts/main, so an existing pairing survives.
func migrate() {
	if _, err := os.Stat(filepath.Join(baseDir, "store.db")); err != nil {
		return
	}
	if _, err := os.Stat(accountsDir()); err == nil {
		return
	}
	dir := filepath.Join(accountsDir(), "main")
	if os.MkdirAll(dir, 0o700) != nil {
		return
	}
	for _, name := range []string{"store.db", "store.db-wal", "store.db-shm", "app.db", "app.db-wal", "app.db-shm", "media", "avatars"} {
		os.Rename(filepath.Join(baseDir, name), filepath.Join(dir, name))
	}
	// Messages remember where their media was saved.
	if db, err := openDB(filepath.Join(dir, "app.db")); err == nil {
		db.Exec(`UPDATE messages SET media_path = replace(media_path, ?, ?) WHERE media_path != ''`,
			filepath.Join(baseDir, "media")+"/", filepath.Join(dir, "media")+"/")
		db.Close()
	}
}

func listAccounts() []string {
	entries, _ := os.ReadDir(accountsDir())
	ids := []string{}
	for _, e := range entries {
		if e.IsDir() {
			ids = append(ids, e.Name())
		}
	}
	// "main" first, then in creation order (ids are time-based).
	sort.Slice(ids, func(i, j int) bool {
		if (ids[i] == "main") != (ids[j] == "main") {
			return ids[i] == "main"
		}
		return ids[i] < ids[j]
	})
	return ids
}

// openAccount starts the account's client, creating the account if needed.
func openAccount(id string) error {
	if id == "" || id != safeName(id) || strings.HasPrefix(id, ".") {
		return errors.New("invalid account id")
	}
	appsMu.Lock()
	defer appsMu.Unlock()
	if apps[id] != nil {
		return nil
	}
	a, err := newApp(id, filepath.Join(accountsDir(), id))
	if err != nil {
		return err
	}
	apps[id] = a
	go a.start()
	return nil
}

// removeAccount stops the account and deletes its data; with unlink it also
// removes this device from the phone.
func removeAccount(id string, unlink bool) error {
	appsMu.Lock()
	a := apps[id]
	delete(apps, id)
	appsMu.Unlock()
	if a == nil {
		return errors.New("unknown account")
	}
	a.close(unlink)
	return os.RemoveAll(a.dir)
}

func call(r *Req) (any, error) {
	switch r.Cmd {
	case "set_lang":
		lang = r.Text
		return nil, nil
	case "accounts":
		return listAccounts(), nil
	case "open_account":
		return nil, openAccount(r.Account)
	case "remove_account":
		return nil, removeAccount(r.Account, r.Unlink)
	}
	appsMu.Lock()
	a := apps[r.Account]
	appsMu.Unlock()
	if a == nil {
		return nil, errors.New("unknown account " + r.Account)
	}
	return a.dispatch(r)
}

//export WAStart
func WAStart(dataDir *C.char, cb C.wa_event_cb) {
	// Trade a little CPU for a smaller heap; this process is mostly idle.
	debug.SetGCPercent(25)
	debug.SetMemoryLimit(64 << 20)
	// The Go runtime holds on to freed memory for a while; hand it back so an
	// idle app stays small.
	go func() {
		for range time.Tick(time.Minute) {
			debug.FreeOSMemory()
		}
	}()
	baseDir = C.GoString(dataDir)
	eventCB = cb
	migrate()
	os.MkdirAll(accountsDir(), 0o700)
}

//export WACall
func WACall(req *C.char) *C.char {
	var out any
	var r Req
	if err := json.Unmarshal([]byte(C.GoString(req)), &r); err != nil {
		out = map[string]any{"error": err.Error()}
	} else if data, err := call(&r); err != nil {
		out = map[string]any{"error": err.Error()}
	} else {
		out = map[string]any{"ok": true, "data": data}
	}
	b, _ := json.Marshal(out)
	return C.CString(string(b))
}

//export WAFree
func WAFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

// Calls exist only in the Rust core (zen/core); these keep the app linking
// against this one.

//export WAVideoSetSink
func WAVideoSetSink(cb C.wa_video_cb) {}

//export WAVideoSend
func WAVideoSend(data *C.uint8_t, n C.size_t) {}

func main() {}
