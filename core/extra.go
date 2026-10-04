package main

import (
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

const maxFileSize = 100 << 20

// sendFile sends a video (kind "video") or any other file as a document.
func (a *App) sendFile(q *Req) (*MsgJSON, error) {
	cli, err := a.online()
	if err != nil {
		return nil, err
	}
	jid, err := types.ParseJID(q.Chat)
	if err != nil {
		return nil, err
	}
	if st, err := os.Stat(q.Path); err != nil {
		return nil, err
	} else if st.Size() > maxFileSize {
		return nil, errors.New("The file is larger than 100 MB")
	}
	data, err := os.ReadFile(q.Path)
	if err != nil {
		return nil, err
	}
	typ, mediaType := "document", whatsmeow.MediaDocument
	if q.Kind == "video" {
		typ, mediaType = "video", whatsmeow.MediaVideo
	}
	thumb, _ := base64.StdEncoding.DecodeString(q.Thumb)

	r := a.newRow(cli, jid, typ, q.Text)
	r.Thumb, r.W, r.H, r.FileName = thumb, q.W, q.H, q.FileName
	r.MediaPath = filepath.Join(a.dir, "media", safeName(r.ID)+filepath.Ext(q.FileName))
	if err := os.WriteFile(r.MediaPath, data, 0o600); err != nil {
		r.MediaPath = ""
	}
	ctx := a.replyContext(r, q.ReplyTo)
	var caption *string
	if q.Text != "" {
		caption = proto.String(q.Text)
	}

	return a.deliver(cli, jid, r, func() (*waE2E.Message, error) {
		up, err := cli.Upload(bg, data, mediaType)
		if err != nil {
			return nil, err
		}
		if typ == "video" {
			return &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
				URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
				Mimetype: proto.String(q.Mime), FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
				FileLength: proto.Uint64(up.FileLength), Seconds: proto.Uint32(uint32(q.Seconds)),
				Width: proto.Uint32(uint32(q.W)), Height: proto.Uint32(uint32(q.H)),
				JPEGThumbnail: thumb, Caption: caption, ContextInfo: ctx,
			}}, nil
		}
		return &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			Mimetype: proto.String(q.Mime), FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), FileName: proto.String(q.FileName), Title: proto.String(q.FileName),
			JPEGThumbnail: thumb, Caption: caption, ContextInfo: ctx,
		}}, nil
	})
}

// ownMessage checks that the message exists and was sent by us.
func (a *App) ownMessage(chat, id string) error {
	var fromMe bool
	if err := a.db.QueryRow(`SELECT from_me FROM messages WHERE chat=? AND id=?`, chat, id).Scan(&fromMe); err != nil {
		return err
	}
	if !fromMe {
		return errors.New("Only your own messages can be changed")
	}
	return nil
}

// revoke deletes one of our messages for everyone.
func (a *App) revoke(chat, id string) error {
	cli, err := a.online()
	if err != nil {
		return err
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		return err
	}
	if err := a.ownMessage(chat, id); err != nil {
		return err
	}
	if _, err := cli.SendMessage(bg, jid, cli.BuildRevoke(jid, types.EmptyJID, id)); err != nil {
		return err
	}
	a.db.Exec(`UPDATE messages SET deleted=1, text='', thumb=NULL, raw=NULL, media_path='' WHERE chat=? AND id=?`, chat, id)
	a.changed(chat)
	return nil
}

// edit replaces the text of one of our messages (WhatsApp allows ~15 minutes).
func (a *App) edit(chat, id, text string) error {
	cli, err := a.online()
	if err != nil {
		return err
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		return err
	}
	if strings.TrimSpace(text) == "" {
		return errors.New("Empty message")
	}
	if err := a.ownMessage(chat, id); err != nil {
		return err
	}
	edited := cli.BuildEdit(jid, id, &waE2E.Message{Conversation: proto.String(text)})
	if _, err := cli.SendMessage(bg, jid, edited); err != nil {
		return err
	}
	a.db.Exec(`UPDATE messages SET text=?, edited=1 WHERE chat=? AND id=?`, text, chat, id)
	a.changed(chat)
	return nil
}

func (a *App) changed(chat string) {
	a.emit(map[string]any{"type": "messages", "chat": chat})
	a.emit(map[string]any{"type": "chats"})
}

type ContactJSON struct {
	JID  string `json:"jid"`
	Name string `json:"name"`
}

// contacts lists the address-book contacts, for starting a new chat.
func (a *App) contacts() ([]ContactJSON, error) {
	cli := a.client()
	if cli == nil {
		return nil, errors.New("Not connected to WhatsApp")
	}
	all, err := cli.Store.Contacts.GetAllContacts(bg)
	if err != nil {
		return nil, err
	}
	out := []ContactJSON{}
	for jid, c := range all {
		if jid.Server == types.DefaultUserServer && c.FullName != "" {
			out = append(out, ContactJSON{JID: jid.ToNonAD().String(), Name: c.FullName})
		}
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out, nil
}

// startChat makes sure a chat exists for a contact (by JID) or a phone number
// and returns its JID, so the UI can open an empty conversation.
func (a *App) startChat(jidStr, phone string) (string, error) {
	var jid types.JID
	if jidStr != "" {
		j, err := types.ParseJID(jidStr)
		if err != nil {
			return "", err
		}
		jid = j
	} else {
		cli, err := a.online()
		if err != nil {
			return "", err
		}
		digits := strings.Map(func(r rune) rune {
			if r >= '0' && r <= '9' {
				return r
			}
			return -1
		}, phone)
		if len(digits) < 7 {
			return "", errors.New("Invalid phone number")
		}
		res, err := cli.IsOnWhatsApp(bg, []string{"+" + digits})
		if err != nil {
			return "", err
		}
		if len(res) == 0 || !res[0].IsIn {
			return "", errors.New("This number is not on WhatsApp")
		}
		jid = res[0].JID.ToNonAD()
	}
	touchChat(a.db, jid.String(), time.Now().Unix())
	a.emit(map[string]any{"type": "chats"})
	return jid.String(), nil
}
