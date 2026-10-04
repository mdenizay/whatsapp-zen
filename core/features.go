package main

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

// target resolves the client and chat JID most commands start with.
func (a *App) target(chat string) (*whatsmeow.Client, types.JID, error) {
	cli, err := a.online()
	if err != nil {
		return nil, types.EmptyJID, err
	}
	jid, err := types.ParseJID(chat)
	return cli, jid, err
}

// archive and pinChat change settings that sync across the user's devices.
func (a *App) archive(chat string, on bool) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	var last int64
	a.db.QueryRow(`SELECT last_ts FROM chats WHERE jid=?`, chat).Scan(&last)
	if err := cli.SendAppState(bg, appstate.BuildArchive(jid, on, time.Unix(last, 0), nil)); err != nil {
		return err
	}
	a.db.Exec(`UPDATE chats SET archived=? WHERE jid=?`, on, chat)
	if on {
		// WhatsApp unpins a chat when it is archived.
		a.db.Exec(`UPDATE chats SET pinned=0 WHERE jid=?`, chat)
	}
	a.emit(map[string]any{"type": "chats"})
	return nil
}

func (a *App) pinChat(chat string, on bool) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	if err := cli.SendAppState(bg, appstate.BuildPin(jid, on)); err != nil {
		return err
	}
	a.db.Exec(`UPDATE chats SET pinned=? WHERE jid=?`, on, chat)
	a.emit(map[string]any{"type": "chats"})
	return nil
}

// messageKey loads what identifies a stored message on the wire.
func (a *App) messageKey(chat types.JID, id string) (sender types.JID, fromMe bool, key *waCommon.MessageKey, err error) {
	var senderStr string
	if err = a.db.QueryRow(`SELECT sender, from_me FROM messages WHERE chat=? AND id=?`, chat.String(), id).
		Scan(&senderStr, &fromMe); err != nil {
		return
	}
	if sender, err = types.ParseJID(senderStr); err != nil {
		return
	}
	key = &waCommon.MessageKey{RemoteJID: proto.String(chat.String()), FromMe: proto.Bool(fromMe), ID: proto.String(id)}
	if chat.Server == types.GroupServer && !fromMe {
		key.Participant = proto.String(sender.String())
	}
	return
}

func (a *App) star(chat, id string, on bool) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	sender, fromMe, _, err := a.messageKey(jid, id)
	if err != nil {
		return err
	}
	if jid.Server != types.GroupServer || fromMe {
		sender = types.EmptyJID
	}
	if err := cli.SendAppState(bg, appstate.BuildStar(jid, sender, id, fromMe, on)); err != nil {
		return err
	}
	a.db.Exec(`UPDATE messages SET starred=? WHERE chat=? AND id=?`, on, chat, id)
	a.emit(map[string]any{"type": "messages", "chat": chat})
	return nil
}

// pinMessage pins a message in its chat for everyone (for 7 days, WhatsApp's
// default) or unpins it.
func (a *App) pinMessage(chat, id string, on bool) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	_, _, key, err := a.messageKey(jid, id)
	if err != nil {
		return err
	}
	typ := waE2E.PinInChatMessage_UNPIN_FOR_ALL
	if on {
		typ = waE2E.PinInChatMessage_PIN_FOR_ALL
	}
	msg := &waE2E.Message{
		PinInChatMessage: &waE2E.PinInChatMessage{Key: key, Type: typ.Enum(), SenderTimestampMS: proto.Int64(time.Now().UnixMilli())},
	}
	if on {
		msg.MessageContextInfo = &waE2E.MessageContextInfo{MessageAddOnDurationInSecs: proto.Uint32(7 * 24 * 3600)}
	}
	if _, err := cli.SendMessage(bg, jid, msg); err != nil {
		return err
	}
	a.db.Exec(`UPDATE messages SET pinned=? WHERE chat=? AND id=?`, on, chat, id)
	a.emit(map[string]any{"type": "messages", "chat": chat})
	return nil
}

func (a *App) search(chat, text string) ([]*MsgJSON, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return []*MsgJSON{}, nil
	}
	esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(text)
	return a.queryMessages(`chat=? AND deleted=0 AND (text LIKE ? ESCAPE '\' OR file_name LIKE ? ESCAPE '\')
		ORDER BY ts DESC LIMIT 100`, chat, "%"+esc+"%", "%"+esc+"%")
}

// forward re-sends a stored message to another chat, marked as forwarded.
// Media is not uploaded again: the original's encrypted file is referenced.
func (a *App) forward(chat, id, to string) (*MsgJSON, error) {
	cli, dest, err := a.target(to)
	if err != nil {
		return nil, err
	}
	var src row
	if err := a.db.QueryRow(`SELECT type,text,thumb,raw,media_path,file_name,w,h FROM messages WHERE chat=? AND id=? AND deleted=0`, chat, id).
		Scan(&src.Type, &src.Text, &src.Thumb, &src.Raw, &src.MediaPath, &src.FileName, &src.W, &src.H); err != nil {
		return nil, err
	}
	fwd := &waE2E.ContextInfo{IsForwarded: proto.Bool(true), ForwardingScore: proto.Uint32(1)}
	msg := &waE2E.Message{}
	if len(src.Raw) > 0 {
		if err := proto.Unmarshal(src.Raw, msg); err != nil {
			return nil, err
		}
		switch {
		case msg.ImageMessage != nil:
			msg.ImageMessage.ContextInfo = fwd
		case msg.VideoMessage != nil:
			msg.VideoMessage.ContextInfo = fwd
		case msg.AudioMessage != nil:
			msg.AudioMessage.ContextInfo = fwd
		case msg.DocumentMessage != nil:
			msg.DocumentMessage.ContextInfo = fwd
		case msg.StickerMessage != nil:
			msg.StickerMessage.ContextInfo = fwd
		}
	} else if src.Type == "text" || src.Type == "other" {
		msg.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: proto.String(src.Text), ContextInfo: fwd}
	} else {
		return nil, errors.New("This message cannot be forwarded")
	}
	typ := src.Type
	if typ == "other" {
		typ = "text"
	}
	r := a.newRow(cli, dest, typ, src.Text)
	r.Thumb, r.MediaPath, r.FileName, r.W, r.H = src.Thumb, src.MediaPath, src.FileName, src.W, src.H
	return a.deliver(cli, dest, r, func() (*waE2E.Message, error) { return msg, nil })
}

// sendVoice sends a recording as a voice message. The UI records Opus in a
// CAF file (all macOS can encode); WhatsApp wants Ogg, so it is re-wrapped.
func (a *App) sendVoice(q *Req) (*MsgJSON, error) {
	cli, jid, err := a.target(q.Chat)
	if err != nil {
		return nil, err
	}
	caf, err := os.ReadFile(q.Path)
	if err != nil {
		return nil, err
	}
	data, err := cafOpusToOgg(caf)
	if err != nil {
		return nil, err
	}
	r := a.newRow(cli, jid, "audio", "")
	r.W = q.Seconds
	r.MediaPath = filepath.Join(a.dir, "media", safeName(r.ID)+".ogg")
	if err := os.WriteFile(r.MediaPath, data, 0o600); err != nil {
		r.MediaPath = ""
	}
	ctx := a.replyContext(r, q.ReplyTo)
	return a.deliver(cli, jid, r, func() (*waE2E.Message, error) {
		up, err := cli.Upload(bg, data, whatsmeow.MediaAudio)
		if err != nil {
			return nil, err
		}
		return &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			Mimetype: proto.String("audio/ogg; codecs=opus"), FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), Seconds: proto.Uint32(uint32(q.Seconds)), PTT: proto.Bool(true),
			ContextInfo: ctx,
		}}, nil
	})
}

type MemberJSON struct {
	JID     string `json:"jid"`
	Name    string `json:"name"`
	IsAdmin bool   `json:"is_admin"`
	IsMe    bool   `json:"is_me"`
}

type GroupJSON struct {
	Name    string       `json:"name"`
	Topic   string       `json:"topic"`
	Created int64        `json:"created"`
	IsAdmin bool         `json:"is_admin"` // whether we may manage the group
	Members []MemberJSON `json:"members"`
}

func (a *App) groupInfo(chat string) (*GroupJSON, error) {
	cli, jid, err := a.target(chat)
	if err != nil {
		return nil, err
	}
	info, err := cli.GetGroupInfo(bg, jid)
	if err != nil {
		return nil, err
	}
	me, myLID := a.me(), cli.Store.GetLID().ToNonAD()
	out := &GroupJSON{Name: info.Name, Topic: info.Topic, Created: info.GroupCreated.Unix(), Members: []MemberJSON{}}
	for _, p := range info.Participants {
		id := p.JID.ToNonAD()
		if !p.PhoneNumber.IsEmpty() {
			id = p.PhoneNumber.ToNonAD()
		} else {
			id = a.pn(id)
		}
		m := MemberJSON{JID: id.String(), IsAdmin: p.IsAdmin || p.IsSuperAdmin}
		m.IsMe = id == me || (!myLID.IsEmpty() && (p.JID.ToNonAD() == myLID || p.LID.ToNonAD() == myLID))
		m.Name = a.nameOf(m.JID)
		if m.IsMe {
			m.Name = T("You")
			out.IsAdmin = m.IsAdmin
		}
		out.Members = append(out.Members, m)
	}
	sort.SliceStable(out.Members, func(i, j int) bool {
		x, y := out.Members[i], out.Members[j]
		if x.IsAdmin != y.IsAdmin {
			return x.IsAdmin
		}
		return strings.ToLower(x.Name) < strings.ToLower(y.Name)
	})
	a.setGroupName(a.db, chat, info.Name)
	return out, nil
}

func (a *App) groupUpdate(chat, member, action string) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	who, err := types.ParseJID(member)
	if err != nil {
		return err
	}
	change, ok := map[string]whatsmeow.ParticipantChange{
		"add": whatsmeow.ParticipantChangeAdd, "remove": whatsmeow.ParticipantChangeRemove,
		"promote": whatsmeow.ParticipantChangePromote, "demote": whatsmeow.ParticipantChangeDemote,
	}[action]
	if !ok {
		return errors.New("unknown action")
	}
	res, err := cli.UpdateGroupParticipants(bg, jid, []types.JID{who}, change)
	if err != nil {
		return err
	}
	for _, p := range res {
		if p.Error != 0 && p.Error != 200 {
			return errors.New("The change was refused; the person's privacy settings may not allow it")
		}
	}
	return nil
}

func (a *App) groupRename(chat, name string) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	if err := cli.SetGroupName(bg, jid, name); err != nil {
		return err
	}
	a.setGroupName(a.db, chat, name)
	a.emit(map[string]any{"type": "chats"})
	return nil
}

func (a *App) groupLeave(chat string) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	return cli.LeaveGroup(bg, jid)
}

func (a *App) groupLink(chat string) (string, error) {
	cli, jid, err := a.target(chat)
	if err != nil {
		return "", err
	}
	return cli.GetGroupInviteLink(bg, jid, false)
}
