package main

import (
	"database/sql"
	"encoding/base64"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

const schema = `
CREATE TABLE IF NOT EXISTS chats(
	jid TEXT PRIMARY KEY,
	name TEXT NOT NULL DEFAULT '',
	last_ts INTEGER NOT NULL DEFAULT 0,
	unread INTEGER NOT NULL DEFAULT 0,
	archived INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages(
	chat TEXT NOT NULL,
	id TEXT NOT NULL,
	sender TEXT NOT NULL,
	from_me INTEGER NOT NULL,
	ts INTEGER NOT NULL,
	type TEXT NOT NULL,
	text TEXT NOT NULL DEFAULT '',
	thumb BLOB,
	raw BLOB,
	media_path TEXT NOT NULL DEFAULT '',
	file_name TEXT NOT NULL DEFAULT '',
	w INTEGER NOT NULL DEFAULT 0,
	h INTEGER NOT NULL DEFAULT 0,
	quoted_id TEXT NOT NULL DEFAULT '',
	quoted_text TEXT NOT NULL DEFAULT '',
	quoted_sender TEXT NOT NULL DEFAULT '',
	status INTEGER NOT NULL DEFAULT 0,
	unread INTEGER NOT NULL DEFAULT 0,
	edited INTEGER NOT NULL DEFAULT 0,
	deleted INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY(chat, id)
);
CREATE INDEX IF NOT EXISTS messages_chat_ts ON messages(chat, ts);
CREATE TABLE IF NOT EXISTS reactions(
	chat TEXT NOT NULL,
	msg_id TEXT NOT NULL,
	sender TEXT NOT NULL,
	emoji TEXT NOT NULL,
	PRIMARY KEY(chat, msg_id, sender)
);
`

// Message status values shared with the UI.
const (
	statusFailed    = -1
	statusPending   = 0
	statusSent      = 1
	statusDelivered = 2
	statusRead      = 3
)

type execer interface {
	Exec(query string, args ...any) (sql.Result, error)
}

// leanPool keeps a database from holding more connections (each with its own
// page cache) than a mostly idle app needs.
func leanPool(db *sql.DB) {
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(1)
	db.SetConnMaxIdleTime(30 * time.Second)
}

func openDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", "file:"+path+"?_journal_mode=WAL&_busy_timeout=5000&_synchronous=NORMAL&_txlock=immediate&_cache_size=-1024")
	if err != nil {
		return nil, err
	}
	leanPool(db)
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	// Columns added after the first release; "duplicate column" just means
	// this database already has them.
	for _, stmt := range []string{
		`ALTER TABLE messages ADD COLUMN starred INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE chats ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE chats ADD COLUMN muted_until INTEGER NOT NULL DEFAULT 0`, // -1: muted for good
		`ALTER TABLE chats ADD COLUMN ephemeral INTEGER NOT NULL DEFAULT 0`,   // disappearing timer, seconds
		`ALTER TABLE messages ADD COLUMN link_title TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE messages ADD COLUMN link_desc TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE messages ADD COLUMN poll TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE messages ADD COLUMN mentions_me INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE messages ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0`,
		`CREATE TABLE IF NOT EXISTS poll_votes(chat TEXT NOT NULL, msg_id TEXT NOT NULL, voter TEXT NOT NULL,
			options TEXT NOT NULL, PRIMARY KEY(chat, msg_id, voter))`,
	} {
		db.Exec(stmt)
	}
	return db, nil
}

// row is a message as stored locally.
type row struct {
	Chat, ID, Sender        string
	FromMe                  bool
	TS                      int64
	Type, Text              string
	Thumb, Raw              []byte
	MediaPath, FileName     string
	W, H                    int
	QuotedID, QuotedText    string
	QuotedSender            string
	Status                  int
	Unread, Edited, Deleted bool
}

func insertMessage(x execer, r *row) (bool, error) {
	res, err := x.Exec(`INSERT INTO messages
		(chat,id,sender,from_me,ts,type,text,thumb,raw,media_path,file_name,w,h,quoted_id,quoted_text,quoted_sender,status,unread)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(chat,id) DO NOTHING`,
		r.Chat, r.ID, r.Sender, r.FromMe, r.TS, r.Type, r.Text, r.Thumb, r.Raw, r.MediaPath, r.FileName, r.W, r.H,
		r.QuotedID, r.QuotedText, r.QuotedSender, r.Status, r.Unread)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

func touchChat(x execer, jid string, ts int64) error {
	_, err := x.Exec(`INSERT INTO chats(jid,last_ts) VALUES(?,?)
		ON CONFLICT(jid) DO UPDATE SET last_ts=MAX(last_ts, excluded.last_ts)`, jid, ts)
	return err
}

func setReaction(x execer, chat, msgID, sender, emoji string) error {
	if emoji == "" {
		_, err := x.Exec(`DELETE FROM reactions WHERE chat=? AND msg_id=? AND sender=?`, chat, msgID, sender)
		return err
	}
	_, err := x.Exec(`INSERT INTO reactions(chat,msg_id,sender,emoji) VALUES(?,?,?,?)
		ON CONFLICT(chat,msg_id,sender) DO UPDATE SET emoji=excluded.emoji`, chat, msgID, sender, emoji)
	return err
}

// MsgJSON is a message as handed to the UI.
type MsgJSON struct {
	ID           string    `json:"id"`
	Chat         string    `json:"chat"`
	Sender       string    `json:"sender"`
	SenderName   string    `json:"sender_name"`
	FromMe       bool      `json:"from_me"`
	TS           int64     `json:"ts"`
	Type         string    `json:"type"`
	Text         string    `json:"text"`
	Thumb        string    `json:"thumb,omitempty"`
	MediaPath    string    `json:"media_path,omitempty"`
	FileName     string    `json:"file_name,omitempty"`
	W            int       `json:"w"`
	H            int       `json:"h"`
	QuotedID     string    `json:"quoted_id,omitempty"`
	QuotedText   string    `json:"quoted_text,omitempty"`
	QuotedSender string    `json:"quoted_sender,omitempty"`
	Status       int       `json:"status"`
	Edited       bool      `json:"edited"`
	Deleted      bool      `json:"deleted"`
	Starred      bool      `json:"starred"`
	Pinned       bool      `json:"pinned"`
	LinkTitle    string    `json:"link_title,omitempty"`
	LinkDesc     string    `json:"link_desc,omitempty"`
	MentionsMe   bool      `json:"mentions_me"`
	Poll         *PollJSON `json:"poll,omitempty"`
	pollRaw      string
	Reactions    []Reaction `json:"reactions"`
}

type Reaction struct {
	Emoji  string `json:"emoji"`
	Sender string `json:"sender"`
	Name   string `json:"name"`
	FromMe bool   `json:"from_me"`
}

const msgCols = `id,chat,sender,from_me,ts,type,text,thumb,media_path,file_name,w,h,quoted_id,quoted_text,quoted_sender,status,edited,deleted,starred,pinned,link_title,link_desc,mentions_me,poll`

// queryMessages runs a SELECT over msgCols and attaches names and reactions.
func (a *App) queryMessages(where string, args ...any) ([]*MsgJSON, error) {
	rows, err := a.db.Query(`SELECT `+msgCols+` FROM messages WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	out := []*MsgJSON{}
	byID := map[string]*MsgJSON{}
	for rows.Next() {
		m := &MsgJSON{Reactions: []Reaction{}}
		var thumb []byte
		if err := rows.Scan(&m.ID, &m.Chat, &m.Sender, &m.FromMe, &m.TS, &m.Type, &m.Text, &thumb, &m.MediaPath,
			&m.FileName, &m.W, &m.H, &m.QuotedID, &m.QuotedText, &m.QuotedSender, &m.Status, &m.Edited, &m.Deleted, &m.Starred, &m.Pinned,
			&m.LinkTitle, &m.LinkDesc, &m.MentionsMe, &m.pollRaw); err != nil {
			rows.Close()
			return nil, err
		}
		if len(thumb) > 0 {
			m.Thumb = base64.StdEncoding.EncodeToString(thumb)
		}
		out = append(out, m)
		byID[m.ID] = m
	}
	rows.Close()
	if len(out) == 0 {
		return out, nil
	}

	a.attachPolls(out)
	me := a.meString()
	for _, m := range out {
		if !m.FromMe {
			m.SenderName = a.nameOf(m.Sender)
		}
		if m.QuotedSender != "" {
			if m.QuotedSender == me {
				m.QuotedSender = T("You")
			} else {
				m.QuotedSender = a.nameOf(m.QuotedSender)
			}
		}
	}

	ph := strings.TrimSuffix(strings.Repeat("?,", len(out)), ",")
	rargs := make([]any, 0, len(out)+1)
	rargs = append(rargs, out[0].Chat)
	for _, m := range out {
		rargs = append(rargs, m.ID)
	}
	rr, err := a.db.Query(`SELECT msg_id,sender,emoji FROM reactions WHERE chat=? AND msg_id IN (`+ph+`)`, rargs...)
	if err != nil {
		return out, nil
	}
	type rx struct{ id, sender, emoji string }
	var all []rx
	for rr.Next() {
		var r rx
		if rr.Scan(&r.id, &r.sender, &r.emoji) == nil {
			all = append(all, r)
		}
	}
	rr.Close()
	for _, r := range all {
		if m := byID[r.id]; m != nil {
			fromMe := r.sender == me
			name := T("You")
			if !fromMe {
				name = a.nameOf(r.sender)
			}
			m.Reactions = append(m.Reactions, Reaction{Emoji: r.emoji, Sender: r.sender, Name: name, FromMe: fromMe})
		}
	}
	return out, nil
}

// getMessages returns one page in ascending order. With beforeTS == 0 it is
// the newest page; otherwise the page just older than (beforeTS, beforeID).
func (a *App) getMessages(chat string, beforeTS int64, beforeID string, limit int) ([]*MsgJSON, error) {
	// Disappearing messages whose time is up.
	a.db.Exec(`DELETE FROM messages WHERE expires_at > 0 AND expires_at < strftime('%s','now')`)
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var (
		msgs []*MsgJSON
		err  error
	)
	if beforeTS > 0 {
		msgs, err = a.queryMessages(`chat=? AND (ts,id) < (?,?) ORDER BY ts DESC, id DESC LIMIT ?`, chat, beforeTS, beforeID, limit)
	} else {
		msgs, err = a.queryMessages(`chat=? ORDER BY ts DESC, id DESC LIMIT ?`, chat, limit)
	}
	if err != nil {
		return nil, err
	}
	for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
		msgs[i], msgs[j] = msgs[j], msgs[i]
	}
	return msgs, nil
}

func (a *App) getMessage(chat, id string) *MsgJSON {
	msgs, err := a.queryMessages(`chat=? AND id=?`, chat, id)
	if err != nil || len(msgs) == 0 {
		return nil
	}
	return msgs[0]
}

type ChatJSON struct {
	JID        string `json:"jid"`
	Name       string `json:"name"`
	IsGroup    bool   `json:"is_group"`
	LastTS     int64  `json:"last_ts"`
	Unread     int    `json:"unread"`
	LastType   string `json:"last_type"`
	LastText   string `json:"last_text"`
	LastFromMe bool   `json:"last_from_me"`
	LastStatus int    `json:"last_status"`
	LastSender string `json:"last_sender"`
	LastFile   string `json:"last_file"`
	Archived   bool   `json:"archived"`
	Pinned     bool   `json:"pinned"`
	Muted      bool   `json:"muted"`
	Ephemeral  int    `json:"ephemeral"`
}

func (a *App) getChats() ([]*ChatJSON, error) {
	rows, err := a.db.Query(`SELECT c.jid, c.last_ts, c.unread, c.archived, c.pinned,
			(c.muted_until < 0 OR c.muted_until > strftime('%s','now')), c.ephemeral,
			COALESCE(m.type,''), COALESCE(m.text,''), COALESCE(m.from_me,0), COALESCE(m.status,0),
			COALESCE(m.sender,''), COALESCE(m.deleted,0), COALESCE(m.file_name,'')
		FROM chats c LEFT JOIN messages m ON m.chat=c.jid
			AND m.id=(SELECT id FROM messages WHERE chat=c.jid ORDER BY ts DESC, id DESC LIMIT 1)
		WHERE c.last_ts>0 ORDER BY c.last_ts DESC LIMIT 600`)
	if err != nil {
		return nil, err
	}
	out := []*ChatJSON{}
	var senders []string
	for rows.Next() {
		c := &ChatJSON{}
		var sender string
		var deleted bool
		if err := rows.Scan(&c.JID, &c.LastTS, &c.Unread, &c.Archived, &c.Pinned, &c.Muted, &c.Ephemeral, &c.LastType, &c.LastText, &c.LastFromMe, &c.LastStatus,
			&sender, &deleted, &c.LastFile); err != nil {
			rows.Close()
			return nil, err
		}
		if deleted {
			c.LastType, c.LastText = "deleted", ""
		}
		c.IsGroup = strings.HasSuffix(c.JID, "@g.us")
		out = append(out, c)
		senders = append(senders, sender)
	}
	rows.Close()
	for i, c := range out {
		c.Name = a.nameOf(c.JID)
		if c.IsGroup && !c.LastFromMe && senders[i] != "" {
			c.LastSender = a.nameOf(senders[i])
		}
	}
	return out, nil
}
