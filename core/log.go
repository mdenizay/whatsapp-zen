package main

import (
	"fmt"
	"os"
	"sync"
	"time"

	waLog "go.mau.fi/whatsmeow/util/log"
)

// fileLog writes the protocol library's log to core.log in the data folder,
// which is the only place connection and pairing failures are explained.
type fileLog struct {
	out    *os.File
	mu     *sync.Mutex
	module string
}

func newFileLog(path string) waLog.Logger {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return waLog.Noop
	}
	return &fileLog{out: f, mu: &sync.Mutex{}, module: "core"}
}

func (l *fileLog) write(level, msg string, args []any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	fmt.Fprintf(l.out, "%s [%s %s] %s\n", time.Now().Format("15:04:05.000"), l.module, level, fmt.Sprintf(msg, args...))
}

func (l *fileLog) Warnf(msg string, args ...any)  { l.write("WARN", msg, args) }
func (l *fileLog) Errorf(msg string, args ...any) { l.write("ERROR", msg, args) }
func (l *fileLog) Infof(msg string, args ...any)  { l.write("INFO", msg, args) }
func (l *fileLog) Debugf(string, ...any)          {}
func (l *fileLog) Sub(module string) waLog.Logger {
	return &fileLog{out: l.out, mu: l.mu, module: l.module + "/" + module}
}
