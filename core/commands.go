package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// Req is a command from the UI. Only the fields a command needs are set.
type Req struct {
	Cmd      string `json:"cmd"`
	Chat     string `json:"chat"`
	ID       string `json:"id"`
	JID      string `json:"jid"`
	Text     string `json:"text"`
	Path     string `json:"path"`
	Thumb    string `json:"thumb"`
	ReplyTo  string `json:"reply_to"`
	Emoji    string `json:"emoji"`
	On       bool   `json:"on"`
	W        int    `json:"w"`
	H        int    `json:"h"`
	Limit    int    `json:"limit"`
	BeforeTS int64  `json:"before_ts"`
	BeforeID string `json:"before_id"`
	Kind     string `json:"kind"`
	Mime     string `json:"mime"`
	FileName string `json:"file_name"`
	Seconds  int    `json:"seconds"`
	Phone    string `json:"phone"`
	Account  string `json:"account"`
	Unlink   bool   `json:"unlink"`
	To       string `json:"to"`
	Action   string `json:"action"`
	TS       int64  `json:"ts"`
}

func (a *App) dispatch(r *Req) (any, error) {
	switch r.Cmd {
	case "state":
		return a.stateJSON(), nil
	case "chats":
		return a.getChats()
	case "messages":
		return a.getMessages(r.Chat, r.BeforeTS, r.BeforeID, r.Limit)
	case "send_text":
		return a.sendText(r.Chat, r.Text, r.ReplyTo)
	case "send_image":
		return a.sendImage(r)
	case "send_file":
		return a.sendFile(r)
	case "revoke":
		return nil, a.revoke(r.Chat, r.ID)
	case "edit":
		return nil, a.edit(r.Chat, r.ID, r.Text)
	case "contacts":
		return a.contacts()
	case "start_chat":
		return a.startChat(r.JID, r.Phone)
	case "archive":
		return nil, a.archive(r.Chat, r.On)
	case "pin_chat":
		return nil, a.pinChat(r.Chat, r.On)
	case "star":
		return nil, a.star(r.Chat, r.ID, r.On)
	case "pin_message":
		return nil, a.pinMessage(r.Chat, r.ID, r.On)
	case "starred":
		return a.queryMessages(`chat=? AND starred=1 AND deleted=0 ORDER BY ts DESC LIMIT 200`, r.Chat)
	case "pinned":
		return a.queryMessages(`chat=? AND pinned=1 AND deleted=0 ORDER BY ts DESC LIMIT 20`, r.Chat)
	case "search":
		return a.search(r.Chat, r.Text)
	case "count_since":
		var n int
		err := a.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE chat=? AND ts>=?`, r.Chat, r.TS).Scan(&n)
		return n, err
	case "forward":
		return a.forward(r.Chat, r.ID, r.To)
	case "send_voice":
		return a.sendVoice(r)
	case "group_info":
		return a.groupInfo(r.Chat)
	case "group_update":
		return nil, a.groupUpdate(r.Chat, r.JID, r.Action)
	case "group_rename":
		return nil, a.groupRename(r.Chat, r.Text)
	case "group_leave":
		return nil, a.groupLeave(r.Chat)
	case "group_link":
		return a.groupLink(r.Chat)
	case "reject_call":
		cli, jid, err := a.target(r.JID)
		if err != nil {
			return nil, err
		}
		return nil, cli.RejectCall(bg, jid, r.ID)
	case "react":
		return nil, a.react(r.Chat, r.ID, r.Emoji)
	case "mark_read":
		return nil, a.markRead(r.Chat)
	case "avatar":
		return a.avatar(r.JID)
	case "download":
		return a.download(r.Chat, r.ID)
	case "presence":
		a.mu.Lock()
		a.available = r.On
		a.mu.Unlock()
		a.sendPresence(a.client(), r.On)
		return nil, nil
	case "subscribe", "subscribe_presence":
		return nil, a.subscribe(r.JID)
	case "typing":
		return nil, a.typing(r.Chat, r.On)
	case "logout":
		if cli := a.client(); cli != nil && cli.IsLoggedIn() {
			cli.Logout(bg)
		}
		go a.reset()
		return nil, nil
	}
	return nil, fmt.Errorf("unknown command %q", r.Cmd)
}

func (a *App) online() (*whatsmeow.Client, error) {
	cli := a.client()
	if cli == nil || !cli.IsLoggedIn() {
		return nil, errors.New("Not connected to WhatsApp")
	}
	return cli, nil
}

// replyContext builds the quote for a reply and fills the local row to match.
func (a *App) replyContext(r *row, replyTo string) *waE2E.ContextInfo {
	if replyTo == "" {
		return nil
	}
	var sender, typ, text, file string
	if a.db.QueryRow(`SELECT sender,type,text,file_name FROM messages WHERE chat=? AND id=?`, r.Chat, replyTo).
		Scan(&sender, &typ, &text, &file) != nil {
		return nil
	}
	preview := previewOf(&extracted{typ: typ, text: text, fileName: file})
	r.QuotedID, r.QuotedText, r.QuotedSender = replyTo, preview, sender
	return &waE2E.ContextInfo{
		StanzaID:      proto.String(replyTo),
		Participant:   proto.String(sender),
		QuotedMessage: &waE2E.Message{Conversation: proto.String(preview)},
	}
}

// deliver stores the outgoing row right away and does the slow part (media
// upload, then the send) in the background, so the UI shows the bubble
// immediately and the tick catches up. build produces the message to send.
func (a *App) deliver(cli *whatsmeow.Client, to types.JID, r *row, build func() (*waE2E.Message, error)) (*MsgJSON, error) {
	if _, err := insertMessage(a.db, r); err != nil {
		return nil, err
	}
	touchChat(a.db, r.Chat, r.TS)
	a.db.Exec(`UPDATE messages SET unread=0 WHERE chat=? AND unread=1`, r.Chat)
	a.db.Exec(`UPDATE chats SET unread=0 WHERE jid=?`, r.Chat)
	go func() {
		st := statusSent
		msg, err := build()
		if err == nil {
			if r.Type != "text" {
				// Kept so the media can be fetched again if the local copy goes.
				raw, _ := proto.Marshal(msg)
				a.db.Exec(`UPDATE messages SET raw=? WHERE chat=? AND id=?`, raw, r.Chat, r.ID)
			}
			_, err = cli.SendMessage(bg, to, msg, whatsmeow.SendRequestExtra{ID: r.ID})
		}
		if err != nil {
			a.log.Errorf("send %s failed: %v", r.ID, err)
			st = statusFailed
		}
		// A delivery receipt can beat this update; never move the status back.
		a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=? AND status=?`, st, r.Chat, r.ID, statusPending)
		a.changed(r.Chat)
	}()
	a.changed(r.Chat)
	return a.getMessage(r.Chat, r.ID), nil
}

func (a *App) newRow(cli *whatsmeow.Client, chat types.JID, typ, text string) *row {
	return &row{
		Chat: chat.String(), ID: cli.GenerateMessageID(), Sender: a.meString(), FromMe: true,
		TS: time.Now().Unix(), Type: typ, Text: text, Status: statusPending,
	}
}

func (a *App) sendText(chat, text, replyTo string) (*MsgJSON, error) {
	cli, err := a.online()
	if err != nil {
		return nil, err
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(text) == "" {
		return nil, errors.New("Empty message")
	}
	r := a.newRow(cli, jid, "text", text)
	msg := &waE2E.Message{}
	if ctx := a.replyContext(r, replyTo); ctx != nil {
		msg.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ctx}
	} else {
		msg.Conversation = proto.String(text)
	}
	return a.deliver(cli, jid, r, func() (*waE2E.Message, error) { return msg, nil })
}

// sendImage uploads a JPEG prepared by the UI (path, thumbnail and size) and
// sends it with an optional caption.
func (a *App) sendImage(q *Req) (*MsgJSON, error) {
	cli, err := a.online()
	if err != nil {
		return nil, err
	}
	jid, err := types.ParseJID(q.Chat)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(q.Path)
	if err != nil {
		return nil, err
	}
	thumb, _ := base64.StdEncoding.DecodeString(q.Thumb)
	r := a.newRow(cli, jid, "image", q.Text)
	r.Thumb, r.W, r.H = thumb, q.W, q.H
	r.MediaPath = filepath.Join(a.dir, "media", safeName(r.ID)+".jpg")
	if err := os.WriteFile(r.MediaPath, data, 0o600); err != nil {
		r.MediaPath = ""
	}
	ctx := a.replyContext(r, q.ReplyTo)
	return a.deliver(cli, jid, r, func() (*waE2E.Message, error) {
		up, err := cli.Upload(bg, data, whatsmeow.MediaImage)
		if err != nil {
			return nil, err
		}
		img := &waE2E.ImageMessage{
			URL:           proto.String(up.URL),
			DirectPath:    proto.String(up.DirectPath),
			MediaKey:      up.MediaKey,
			Mimetype:      proto.String("image/jpeg"),
			FileEncSHA256: up.FileEncSHA256,
			FileSHA256:    up.FileSHA256,
			FileLength:    proto.Uint64(up.FileLength),
			Width:         proto.Uint32(uint32(q.W)),
			Height:        proto.Uint32(uint32(q.H)),
			JPEGThumbnail: thumb,
			ContextInfo:   ctx,
		}
		if q.Text != "" {
			img.Caption = proto.String(q.Text)
		}
		return &waE2E.Message{ImageMessage: img}, nil
	})
}

// react sets our reaction on a message; an empty emoji removes it.
func (a *App) react(chat, id, emoji string) error {
	cli, err := a.online()
	if err != nil {
		return err
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		return err
	}
	var senderStr string
	if err := a.db.QueryRow(`SELECT sender FROM messages WHERE chat=? AND id=?`, chat, id).Scan(&senderStr); err != nil {
		return err
	}
	sender, err := types.ParseJID(senderStr)
	if err != nil {
		return err
	}
	if _, err := cli.SendMessage(bg, jid, cli.BuildReaction(jid, sender, id, emoji)); err != nil {
		return err
	}
	setReaction(a.db, chat, id, a.meString(), emoji)
	a.emit(map[string]any{"type": "messages", "chat": chat})
	return nil
}

// markRead sends read receipts for everything unread in a chat.
func (a *App) markRead(chat string) error {
	jid, err := types.ParseJID(chat)
	if err != nil {
		return err
	}
	rows, err := a.db.Query(`SELECT id,sender FROM messages WHERE chat=? AND unread=1 AND from_me=0`, chat)
	if err != nil {
		return err
	}
	bySender := map[string][]types.MessageID{}
	for rows.Next() {
		var id, sender string
		if rows.Scan(&id, &sender) == nil {
			bySender[sender] = append(bySender[sender], id)
		}
	}
	rows.Close()

	var unread int
	a.db.QueryRow(`SELECT unread FROM chats WHERE jid=?`, chat).Scan(&unread)
	if len(bySender) == 0 && unread == 0 {
		return nil
	}
	if cli, err := a.online(); err == nil {
		for s, ids := range bySender {
			if sender, err := types.ParseJID(s); err == nil {
				cli.MarkRead(bg, ids, time.Now(), jid, sender)
			}
		}
	}
	a.markReadLocal(chat)
	return nil
}

func (a *App) subscribe(jidStr string) error {
	cli, err := a.online()
	if err != nil {
		return err
	}
	jid, err := types.ParseJID(jidStr)
	if err != nil {
		return err
	}
	if jid.Server == types.GroupServer {
		return nil
	}
	return cli.SubscribePresence(bg, jid)
}

func (a *App) typing(chat string, on bool) error {
	cli, err := a.online()
	if err != nil {
		return err
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		return err
	}
	state := types.ChatPresencePaused
	if on {
		state = types.ChatPresenceComposing
	}
	return cli.SendChatPresence(bg, jid, state, types.ChatPresenceMediaText)
}

func safeName(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.' {
			return r
		}
		return '_'
	}, s)
}

func (a *App) avatarPath(jid types.JID) string {
	return filepath.Join(a.dir, "avatars", safeName(jid.User)+".jpg")
}

// avatar returns the path of a cached profile photo, fetching it when missing
// or stale. An empty path means the contact has no visible photo.
func (a *App) avatar(jidStr string) (string, error) {
	jid, err := types.ParseJID(jidStr)
	if err != nil {
		return "", err
	}
	path := a.avatarPath(jid)
	cached := ""
	if st, err := os.Stat(path); err == nil {
		if time.Since(st.ModTime()) < 3*24*time.Hour {
			return path, nil
		}
		cached = path
	}
	none := path + ".none"
	if st, err := os.Stat(none); err == nil && time.Since(st.ModTime()) < 24*time.Hour {
		return cached, nil
	}
	cli, err := a.online()
	if err != nil {
		return cached, nil
	}

	a.avatarSem <- struct{}{}
	defer func() { <-a.avatarSem }()

	info, err := cli.GetProfilePictureInfo(bg, jid, &whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil || info == nil || info.URL == "" {
		if !cli.IsConnected() {
			return cached, nil
		}
		// No photo, or hidden by privacy settings: remember that for a day.
		os.Remove(path)
		os.WriteFile(none, nil, 0o600)
		return "", nil
	}
	resp, err := http.Get(info.URL)
	if err != nil {
		return cached, nil
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil || resp.StatusCode != 200 || len(data) == 0 {
		return cached, nil
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return cached, nil
	}
	os.Remove(none)
	return path, nil
}

// download fetches and decrypts a message's media into the cache and returns
// its path.
func (a *App) download(chat, id string) (string, error) {
	var raw []byte
	var typ, fileName, mediaPath string
	if err := a.db.QueryRow(`SELECT raw,type,file_name,media_path FROM messages WHERE chat=? AND id=?`, chat, id).
		Scan(&raw, &typ, &fileName, &mediaPath); err != nil {
		return "", err
	}
	if mediaPath != "" {
		if _, err := os.Stat(mediaPath); err == nil {
			return mediaPath, nil
		}
	}
	if len(raw) == 0 {
		return "", errors.New("medya yok")
	}
	cli, err := a.online()
	if err != nil {
		return "", err
	}
	var msg waE2E.Message
	if err := proto.Unmarshal(raw, &msg); err != nil {
		return "", err
	}
	data, err := cli.DownloadAny(bg, &msg)
	if err != nil {
		return "", err
	}
	ext := map[string]string{"image": ".jpg", "video": ".mp4", "audio": ".ogg", "sticker": ".webp"}[typ]
	if typ == "document" {
		ext = filepath.Ext(fileName)
	}
	if typ == "image" && strings.Contains(msg.GetImageMessage().GetMimetype(), "png") {
		ext = ".png"
	}
	path := filepath.Join(a.dir, "media", safeName(id)+ext)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	a.db.Exec(`UPDATE messages SET media_path=? WHERE chat=? AND id=?`, path, chat, id)
	return path, nil
}
