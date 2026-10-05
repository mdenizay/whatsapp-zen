package main

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

type App struct {
	id        string // account id; tags every event so the UI can route it
	dir       string
	closed    bool
	db        *sql.DB
	container *sqlstore.Container
	log       waLog.Logger

	mu        sync.Mutex
	cli       *whatsmeow.Client
	state     string // starting | qr | connecting | connected | logged_out
	qr        string
	available bool
	names     map[string]string

	avatarSem chan struct{}
}

var bg = context.Background()

func newApp(id, dir string) (*App, error) {
	for _, d := range []string{"media", "avatars"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o700); err != nil {
			return nil, err
		}
	}
	db, err := openDB(filepath.Join(dir, "app.db"))
	if err != nil {
		return nil, err
	}
	// Saved media is remembered by absolute path; follow the data folder if it
	// has been moved or renamed since.
	db.Exec(`UPDATE messages SET media_path = ? || substr(media_path, instr(media_path, '/media/'))
		WHERE media_path != '' AND instr(media_path, '/media/') > 0 AND media_path NOT LIKE ? || '%'`, dir, dir)
	log := newFileLog(filepath.Join(dir, "core.log"))
	storeDB, err := sql.Open("sqlite3",
		"file:"+filepath.Join(dir, "store.db")+"?_foreign_keys=on&_journal_mode=WAL&_busy_timeout=5000&_cache_size=-512")
	if err != nil {
		return nil, err
	}
	leanPool(storeDB)
	container := sqlstore.NewWithDB(storeDB, "sqlite3", log.Sub("store"))
	if err := container.Upgrade(bg); err != nil {
		return nil, err
	}
	store.DeviceProps.Os = proto.String("WhatsApp Zen")
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_DESKTOP.Enum()
	// Ask the phone for a year of history when linking, not just the last few
	// weeks: chats that have been quiet for a while would otherwise open empty.
	store.DeviceProps.RequireFullSync = proto.Bool(true)
	store.DeviceProps.HistorySyncConfig.FullSyncDaysLimit = proto.Uint32(365)
	store.DeviceProps.HistorySyncConfig.FullSyncSizeMbLimit = proto.Uint32(512)
	return &App{
		id:        id,
		dir:       dir,
		db:        db,
		container: container,
		log:       log,
		state:     "starting",
		names:     map[string]string{},
		avatarSem: make(chan struct{}, 3),
	}, nil
}

// emit sends an event to the UI, tagged with this account.
func (a *App) emit(m map[string]any) {
	m["account"] = a.id
	emitRaw(m)
}

// close disconnects the account for good; with unlink it also removes this
// device from the phone's linked devices.
func (a *App) close(unlink bool) {
	a.mu.Lock()
	cli := a.cli
	a.cli, a.closed = nil, true
	a.mu.Unlock()
	if cli != nil {
		if unlink && cli.IsLoggedIn() {
			cli.Logout(bg)
		}
		cli.Disconnect()
	}
	a.container.Close()
	a.db.Close()
}

func (a *App) isClosed() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.closed
}

func (a *App) client() *whatsmeow.Client {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.cli
}

func (a *App) me() types.JID {
	if cli := a.client(); cli != nil && cli.Store.ID != nil {
		return cli.Store.ID.ToNonAD()
	}
	return types.EmptyJID
}

func (a *App) meString() string {
	if me := a.me(); !me.IsEmpty() {
		return me.String()
	}
	return ""
}

func (a *App) stateJSON() map[string]any {
	a.mu.Lock()
	state, qr := a.state, a.qr
	a.mu.Unlock()
	return map[string]any{"type": "state", "state": state, "qr": qr, "me": a.meString()}
}

func (a *App) setState(state, qr string) {
	a.mu.Lock()
	a.state, a.qr = state, qr
	a.mu.Unlock()
	a.emit(a.stateJSON())
}

// start creates a client for the stored device (or a fresh one) and connects,
// going through QR pairing first when there is no session.
func (a *App) start() {
	dev, err := a.container.GetFirstDevice(bg)
	if err != nil {
		a.emit(map[string]any{"type": "fatal", "error": err.Error()})
		return
	}
	// The phone refuses to link a client that announces a stale WhatsApp Web
	// version, so ask for the current one instead of relying on the bundled one.
	if v, err := whatsmeow.GetLatestVersion(bg, nil); err == nil && v != nil {
		store.SetWAVersion(*v)
		a.log.Infof("using WhatsApp Web version %s", v)
	} else {
		a.log.Warnf("could not fetch latest version, using bundled %s: %v", store.GetWAVersion(), err)
	}
	cli := whatsmeow.NewClient(dev, a.log.Sub("client"))
	// Without this a full settings sync (at pairing, or resyncSettings) updates
	// the library's own state but tells us nothing.
	cli.EmitAppStateEventsOnFullSync = true
	cli.AddEventHandler(a.handle)
	a.mu.Lock()
	a.cli = cli
	a.mu.Unlock()

	if cli.Store.ID == nil {
		a.loginLoop(cli)
		return
	}
	a.setState("connecting", "")
	for a.client() == cli {
		if err := cli.Connect(); err == nil || errors.Is(err, whatsmeow.ErrAlreadyConnected) {
			return
		}
		time.Sleep(5 * time.Second)
	}
}

// loginLoop keeps handing fresh QR codes to the UI until the phone scans one.
func (a *App) loginLoop(cli *whatsmeow.Client) {
	for a.client() == cli {
		qrChan, err := cli.GetQRChannel(bg)
		if err != nil {
			a.emit(map[string]any{"type": "fatal", "error": err.Error()})
			return
		}
		if err := cli.Connect(); err != nil {
			a.setState("connecting", "")
			time.Sleep(5 * time.Second)
			continue
		}
		paired := false
		for item := range qrChan {
			a.log.Infof("pairing: %s %v", item.Event, item.Error)
			switch item.Event {
			case "code":
				a.setState("qr", item.Code)
			case "success":
				paired = true
			}
		}
		if paired {
			a.setState("connecting", "")
			return
		}
		cli.Disconnect()
	}
}

// reset drops all local data and starts over with a fresh pairing.
func (a *App) reset() {
	if a.isClosed() {
		return
	}
	if cli := a.client(); cli != nil {
		cli.Disconnect()
	}
	a.db.Exec(`DELETE FROM reactions; DELETE FROM messages; DELETE FROM chats;`)
	for _, d := range []string{"media", "avatars"} {
		p := filepath.Join(a.dir, d)
		os.RemoveAll(p)
		os.MkdirAll(p, 0o700)
	}
	a.clearNames()
	a.setState("logged_out", "")
	a.emit(map[string]any{"type": "chats"})
	if !a.isClosed() {
		a.start()
	}
}

func (a *App) clearNames() {
	a.mu.Lock()
	a.names = map[string]string{}
	a.mu.Unlock()
}

// pn maps a LID address to the phone-number JID when the mapping is known, so
// that one person always lands in one chat.
func (a *App) pn(j types.JID) types.JID {
	j = j.ToNonAD()
	if j.Server == types.HiddenUserServer {
		if cli := a.client(); cli != nil {
			if p, err := cli.Store.LIDs.GetPNForLID(bg, j); err == nil && !p.IsEmpty() {
				return p.ToNonAD()
			}
		}
	}
	return j
}

// resolve returns the normalized chat and sender of a message.
func (a *App) resolve(info *types.MessageInfo) (chat, sender types.JID) {
	chat = info.Chat.ToNonAD()
	if chat.Server == types.HiddenUserServer {
		switch {
		case info.IsFromMe && info.RecipientAlt.Server == types.DefaultUserServer:
			chat = info.RecipientAlt.ToNonAD()
		case !info.IsFromMe && info.SenderAlt.Server == types.DefaultUserServer:
			chat = info.SenderAlt.ToNonAD()
		default:
			chat = a.pn(chat)
		}
	}
	if info.IsFromMe {
		return chat, a.me()
	}
	sender = info.Sender.ToNonAD()
	if sender.Server == types.HiddenUserServer {
		if info.SenderAlt.Server == types.DefaultUserServer {
			sender = info.SenderAlt.ToNonAD()
		} else {
			sender = a.pn(sender)
		}
	}
	return chat, sender
}

func isChatJID(j types.JID) bool {
	switch j.Server {
	case types.DefaultUserServer, types.GroupServer, types.HiddenUserServer:
		return j.User != "status"
	}
	return false
}

// nameOf returns the best display name known for a user or group.
func (a *App) nameOf(jidStr string) string {
	a.mu.Lock()
	n, ok := a.names[jidStr]
	a.mu.Unlock()
	if ok {
		return n
	}
	jid, err := types.ParseJID(jidStr)
	if err != nil {
		return jidStr
	}
	name := ""
	if jid.Server == types.GroupServer {
		a.db.QueryRow(`SELECT name FROM chats WHERE jid=?`, jidStr).Scan(&name)
		if name == "" {
			return T("Group") // not cached: the real name may still arrive
		}
	} else {
		if cli := a.client(); cli != nil {
			if c, err := cli.Store.Contacts.GetContact(bg, jid); err == nil {
				switch {
				case c.FullName != "":
					name = c.FullName
				case c.BusinessName != "":
					name = c.BusinessName
				case c.PushName != "":
					name = c.PushName
				case c.RedactedPhone != "":
					name = c.RedactedPhone
				}
			}
		}
		if name == "" {
			if jid.Server == types.DefaultUserServer {
				name = "+" + jid.User
			} else {
				name = jid.User
			}
		}
	}
	a.mu.Lock()
	a.names[jidStr] = name
	a.mu.Unlock()
	return name
}

func (a *App) setGroupName(x execer, jid, name string) {
	if name == "" {
		return
	}
	x.Exec(`INSERT INTO chats(jid,name) VALUES(?,?) ON CONFLICT(jid) DO UPDATE SET name=excluded.name`, jid, name)
	a.mu.Lock()
	delete(a.names, jid)
	a.mu.Unlock()
}

// resyncSettings replays the account's synced settings (archived and pinned
// chats, starred messages) once, for databases paired before those were
// stored. The replay arrives as ordinary Archive/Pin/Star events.
func (a *App) resyncSettings(cli *whatsmeow.Client) {
	marker := filepath.Join(a.dir, ".settings-synced-3")
	if _, err := os.Stat(marker); err == nil {
		return
	}
	for _, name := range []appstate.WAPatchName{appstate.WAPatchRegularLow, appstate.WAPatchRegularHigh, appstate.WAPatchRegular} {
		if err := cli.FetchAppState(bg, name, true, false); err != nil {
			a.log.Warnf("settings resync %s: %v", name, err)
			return
		}
	}
	os.WriteFile(marker, nil, 0o600)
}

func (a *App) refreshGroups(cli *whatsmeow.Client) {
	groups, err := cli.GetJoinedGroups(bg)
	if err != nil {
		return
	}
	for _, g := range groups {
		if g.IsParent {
			// A community itself is not a chat; its groups are listed on their own.
			continue
		}
		a.setGroupName(a.db, g.JID.String(), g.Name)
		// A group we are in always belongs in the list, even when nothing in
		// its history could be shown (only events, system notices, ...).
		a.db.Exec(`UPDATE chats SET last_ts=? WHERE jid=? AND last_ts=0`, g.GroupCreated.Unix(), g.JID.String())
	}
	a.emit(map[string]any{"type": "chats"})
}

func (a *App) handle(raw any) {
	switch evt := raw.(type) {
	case *events.Message:
		a.onMessage(evt)
	case *events.HistorySync:
		a.onHistory(evt)
	case *events.Receipt:
		a.onReceipt(evt)
	case *events.Presence:
		ev := map[string]any{"type": "presence", "jid": a.pn(evt.From).String(), "online": !evt.Unavailable, "last_seen": 0}
		if !evt.LastSeen.IsZero() {
			ev["last_seen"] = evt.LastSeen.Unix()
		}
		a.emit(ev)
	case *events.ChatPresence:
		chat, sender := a.resolve(&types.MessageInfo{MessageSource: evt.MessageSource})
		a.emit(map[string]any{"type": "typing", "chat": chat.String(), "sender": a.nameOf(sender.String()),
			"composing": evt.State == types.ChatPresenceComposing})
	case *events.Connected:
		a.setState("connected", "")
		cli := a.client()
		a.mu.Lock()
		available := a.available
		a.mu.Unlock()
		go func() {
			a.sendPresence(cli, available)
			a.refreshGroups(cli)
			a.resyncSettings(cli)
		}()
	case *events.Disconnected:
		a.mu.Lock()
		was := a.state
		a.mu.Unlock()
		if was == "connected" {
			a.setState("connecting", "")
		}
	case *events.UndecryptableMessage:
		// View-once media is never delivered to linked devices; say that one
		// arrived so it is not missed.
		if evt.IsUnavailable && evt.UnavailableType == events.UnavailableTypeViewOnce {
			a.onViewOnce(&evt.Info)
		}
	case *events.CallOffer:
		// Calls cannot be answered here; tell the UI so it can point the user
		// at the phone and offer to decline.
		from := a.pn(evt.CallCreator)
		if !evt.CallCreatorAlt.IsEmpty() && evt.CallCreatorAlt.Server == types.DefaultUserServer {
			from = evt.CallCreatorAlt.ToNonAD()
		}
		_, video := evt.Data.GetOptionalChildByTag("video")
		a.emit(map[string]any{"type": "call", "jid": from.String(), "raw_jid": evt.CallCreator.String(),
			"name": a.nameOf(from.String()), "id": evt.CallID, "video": video})
	case *events.PairError:
		a.log.Errorf("pair error: %v", evt.Error)
		a.emit(map[string]any{"type": "fatal", "error": "Pairing failed: " + evt.Error.Error()})
	case *events.ClientOutdated:
		a.log.Errorf("client outdated")
		a.emit(map[string]any{"type": "fatal", "error": "WhatsApp rejected this client version as outdated"})
	case *events.LoggedOut:
		a.log.Warnf("logged out: %v", evt.Reason)
		go a.reset()
	case *events.PushName, *events.Contact, *events.BusinessName:
		a.clearNames()
		a.emit(map[string]any{"type": "chats"})
	case *events.Picture:
		jid := a.pn(evt.JID)
		os.Remove(a.avatarPath(jid))
		os.Remove(a.avatarPath(jid) + ".none")
		a.emit(map[string]any{"type": "avatar", "jid": jid.String()})
	case *events.Archive:
		a.db.Exec(`UPDATE chats SET archived=? WHERE jid=?`, evt.Action.GetArchived(), a.pn(evt.JID).String())
		a.emit(map[string]any{"type": "chats"})
	case *events.Pin:
		a.db.Exec(`UPDATE chats SET pinned=? WHERE jid=?`, evt.Action.GetPinned(), a.pn(evt.JID).String())
		a.emit(map[string]any{"type": "chats"})
	case *events.Mute:
		until := int64(0)
		if evt.Action.GetMuted() {
			until = muteUntil(evt.Action.GetMuteEndTimestamp())
		}
		a.db.Exec(`UPDATE chats SET muted_until=? WHERE jid=?`, until, a.pn(evt.JID).String())
		a.emit(map[string]any{"type": "chats"})
	case *events.Star:
		chat := a.pn(evt.ChatJID).String()
		a.db.Exec(`UPDATE messages SET starred=? WHERE chat=? AND id=?`, evt.Action.GetStarred(), chat, evt.MessageID)
		a.emit(map[string]any{"type": "messages", "chat": chat})
	case *events.DeleteForMe:
		// Deleted for me on another of the user's devices.
		a.removeMessage(a.pn(evt.ChatJID).String(), evt.MessageID)
	case *events.MarkChatAsRead:
		if evt.Action.GetRead() {
			a.markReadLocal(a.pn(evt.JID).String())
		}
	case *events.GroupInfo:
		if evt.Name != nil {
			a.setGroupName(a.db, evt.JID.String(), evt.Name.Name)
			a.emit(map[string]any{"type": "chats"})
		}
	case *events.JoinedGroup:
		a.setGroupName(a.db, evt.JID.String(), evt.Name)
		a.emit(map[string]any{"type": "chats"})
	}
}

func (a *App) sendPresence(cli *whatsmeow.Client, available bool) {
	if cli == nil || !cli.IsLoggedIn() {
		return
	}
	state := types.PresenceUnavailable
	if available {
		state = types.PresenceAvailable
	}
	cli.SendPresence(bg, state)
}

func (a *App) markReadLocal(chat string) {
	a.db.Exec(`UPDATE messages SET unread=0 WHERE chat=? AND unread=1`, chat)
	a.db.Exec(`UPDATE chats SET unread=0 WHERE jid=?`, chat)
	a.emit(map[string]any{"type": "chats"})
}

// extracted is the displayable content pulled out of a protobuf message.
type extracted struct {
	typ, text, fileName string
	thumb               []byte
	w, h                int
	ctx                 *waE2E.ContextInfo
	media               bool
}

func extract(m *waE2E.Message) *extracted {
	if m == nil {
		return nil
	}
	switch {
	case m.GetConversation() != "":
		return &extracted{typ: "text", text: m.GetConversation()}
	case m.GetExtendedTextMessage() != nil:
		x := m.GetExtendedTextMessage()
		return &extracted{typ: "text", text: x.GetText(), ctx: x.GetContextInfo()}
	case m.GetImageMessage() != nil:
		x := m.GetImageMessage()
		return &extracted{typ: "image", text: x.GetCaption(), thumb: x.GetJPEGThumbnail(),
			w: int(x.GetWidth()), h: int(x.GetHeight()), ctx: x.GetContextInfo(), media: true}
	case m.GetVideoMessage() != nil, m.GetPtvMessage() != nil:
		x := m.GetVideoMessage()
		if x == nil {
			x = m.GetPtvMessage()
		}
		return &extracted{typ: "video", text: x.GetCaption(), thumb: x.GetJPEGThumbnail(),
			w: int(x.GetWidth()), h: int(x.GetHeight()), ctx: x.GetContextInfo(), media: true}
	case m.GetAudioMessage() != nil:
		x := m.GetAudioMessage()
		return &extracted{typ: "audio", w: int(x.GetSeconds()), ctx: x.GetContextInfo(), media: true}
	case m.GetDocumentMessage() != nil:
		x := m.GetDocumentMessage()
		name := x.GetFileName()
		if name == "" {
			name = x.GetTitle()
		}
		return &extracted{typ: "document", text: x.GetCaption(), fileName: name, thumb: x.GetJPEGThumbnail(),
			ctx: x.GetContextInfo(), media: true}
	case m.GetStickerMessage() != nil:
		x := m.GetStickerMessage()
		return &extracted{typ: "sticker", w: int(x.GetWidth()), h: int(x.GetHeight()), ctx: x.GetContextInfo(), media: true}
	case m.GetContactMessage() != nil:
		return &extracted{typ: "other", text: "👤 " + T("Contact") + ": " + m.GetContactMessage().GetDisplayName()}
	case m.GetContactsArrayMessage() != nil:
		return &extracted{typ: "other", text: "👤 " + T("Contacts")}
	case m.GetLocationMessage() != nil:
		x := m.GetLocationMessage()
		text := "📍 " + T("Location")
		if x.GetName() != "" {
			text += ": " + x.GetName()
		}
		return &extracted{typ: "other", text: text + "\nhttps://maps.apple.com/?ll=" +
			strconv.FormatFloat(x.GetDegreesLatitude(), 'f', 6, 64) + "," + strconv.FormatFloat(x.GetDegreesLongitude(), 'f', 6, 64)}
	case m.GetLiveLocationMessage() != nil:
		return &extracted{typ: "other", text: "📍 " + T("Live location")}
	case m.GetPollCreationMessage() != nil, m.GetPollCreationMessageV2() != nil, m.GetPollCreationMessageV3() != nil:
		x := m.GetPollCreationMessage()
		if x == nil {
			x = m.GetPollCreationMessageV2()
		}
		if x == nil {
			x = m.GetPollCreationMessageV3()
		}
		return &extracted{typ: "poll", text: x.GetName(), ctx: x.GetContextInfo()}
	case m.GetEventMessage() != nil:
		x := m.GetEventMessage()
		text := "📅 " + x.GetName()
		if x.GetStartTime() > 0 {
			text += "\n" + time.Unix(x.GetStartTime(), 0).Format("02.01.2006 15:04")
		}
		if x.GetDescription() != "" {
			text += "\n" + x.GetDescription()
		}
		return &extracted{typ: "other", text: text, ctx: x.GetContextInfo()}
	case m.GetGroupInviteMessage() != nil:
		return &extracted{typ: "other", text: "✉️ " + T("Group invite") + ": " + m.GetGroupInviteMessage().GetGroupName()}
	case m.GetCall() != nil:
		return &extracted{typ: "other", text: "📞 " + T("Call")}
	}
	return nil
}

// previewOf is the one-line text used when a message is quoted.
func previewOf(x *extracted) string {
	if x == nil {
		return ""
	}
	if x.text != "" {
		return x.text
	}
	switch x.typ {
	case "image":
		return "📷 " + T("Photo")
	case "video":
		return "🎥 " + T("Video")
	case "audio":
		return "🎤 " + T("Voice message")
	case "document":
		return "📄 " + x.fileName
	case "sticker":
		return T("Sticker")
	}
	return ""
}

func (a *App) buildRow(evt *events.Message, chat, sender types.JID) *row {
	x := extract(evt.Message)
	if x == nil {
		return nil
	}
	r := &row{
		Chat: chat.String(), ID: evt.Info.ID, Sender: sender.String(), FromMe: evt.Info.IsFromMe,
		TS: evt.Info.Timestamp.Unix(), Type: x.typ, Text: x.text, Thumb: x.thumb, FileName: x.fileName, W: x.w, H: x.h,
	}
	if x.media {
		r.Raw, _ = proto.Marshal(evt.Message)
	}
	if x.ctx != nil && x.ctx.GetStanzaID() != "" {
		r.QuotedID = x.ctx.GetStanzaID()
		r.QuotedText = previewOf(extract(x.ctx.GetQuotedMessage()))
		if p, err := types.ParseJID(x.ctx.GetParticipant()); err == nil {
			r.QuotedSender = a.pn(p).String()
		}
	}
	return r
}

func (a *App) onMessage(evt *events.Message) {
	chat, sender := a.resolve(&evt.Info)
	if (!isChatJID(chat) && chat.String() != statusChat) || evt.Message == nil {
		return
	}
	cs := chat.String()
	if pu := evt.Message.GetPollUpdateMessage(); pu != nil {
		a.onPollVote(evt, cs, sender.String())
		return
	}

	if p := evt.Message.GetPinInChatMessage(); p != nil {
		pinned := p.GetType() == waE2E.PinInChatMessage_PIN_FOR_ALL
		a.db.Exec(`UPDATE messages SET pinned=? WHERE chat=? AND id=?`, pinned, cs, p.GetKey().GetID())
		a.emit(map[string]any{"type": "messages", "chat": cs})
		return
	}
	if r := evt.Message.GetReactionMessage(); r != nil {
		setReaction(a.db, cs, r.GetKey().GetID(), sender.String(), r.GetText())
		a.emit(map[string]any{"type": "messages", "chat": cs})
		return
	}
	if p := evt.Message.GetProtocolMessage(); p != nil {
		switch p.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			a.db.Exec(`UPDATE messages SET deleted=1, text='', thumb=NULL, raw=NULL, media_path='' WHERE chat=? AND id=?`,
				cs, p.GetKey().GetID())
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			if x := extract(p.GetEditedMessage()); x != nil {
				a.db.Exec(`UPDATE messages SET text=?, edited=1 WHERE chat=? AND id=?`, x.text, cs, p.GetKey().GetID())
			}
		default:
			return
		}
		a.emit(map[string]any{"type": "messages", "chat": cs})
		a.emit(map[string]any{"type": "chats"})
		return
	}

	r := a.buildRow(evt, chat, sender)
	if r == nil {
		return
	}
	if r.FromMe {
		r.Status = statusSent
	} else {
		r.Unread = true
	}
	inserted, err := insertMessage(a.db, r)
	if err != nil || !inserted {
		return
	}
	a.decorate(a.db, r, evt.Message)
	if cs == statusChat {
		// A status update: kept for the Status view, not a conversation.
		a.emit(map[string]any{"type": "messages", "chat": cs})
		return
	}
	touchChat(a.db, cs, r.TS)
	if r.FromMe {
		// Sent from the phone or another device: the chat has been seen there.
		a.db.Exec(`UPDATE messages SET unread=0 WHERE chat=? AND unread=1`, cs)
		a.db.Exec(`UPDATE chats SET unread=0 WHERE jid=?`, cs)
	} else {
		a.db.Exec(`UPDATE chats SET unread=unread+1 WHERE jid=?`, cs)
	}
	a.emit(map[string]any{
		"type": "message", "chat": cs, "chat_name": a.nameOf(cs), "msg": a.getMessage(cs, r.ID),
		"notify": !r.FromMe && time.Since(evt.Info.Timestamp) < 2*time.Minute && !a.isMuted(cs),
	})
}

func (a *App) onReceipt(evt *events.Receipt) {
	chat := a.pn(evt.Chat).String()
	isRead := evt.Type == types.ReceiptTypeRead || evt.Type == types.ReceiptTypeReadSelf || evt.Type == types.ReceiptTypePlayed
	if evt.IsFromMe || evt.Type == types.ReceiptTypeReadSelf {
		// Our own receipt from another device: we read this chat elsewhere.
		if isRead {
			a.markReadLocal(chat)
		}
		return
	}
	st := statusDelivered
	if isRead {
		st = statusRead
	} else if evt.Type != types.ReceiptTypeDelivered {
		return
	}
	changed := int64(0)
	for _, id := range evt.MessageIDs {
		if res, err := a.db.Exec(`UPDATE messages SET status=? WHERE chat=? AND id=? AND from_me=1 AND status>=0 AND status<?`, st, chat, id, st); err == nil {
			n, _ := res.RowsAffected()
			changed += n
		}
	}
	// Every device of every recipient sends its own receipt; most of them
	// change nothing, and then there is nothing for the UI to redraw.
	if changed == 0 {
		return
	}
	a.emit(map[string]any{"type": "messages", "chat": chat})
	a.emit(map[string]any{"type": "chats"})
}

func (a *App) onHistory(evt *events.HistorySync) {
	cli := a.client()
	if cli == nil {
		return
	}
	for _, conv := range evt.Data.GetConversations() {
		orig, err := types.ParseJID(conv.GetID())
		if err != nil || !isChatJID(orig) {
			continue
		}
		chat := a.pn(orig)
		if chat.Server == types.HiddenUserServer && conv.GetPnJID() != "" {
			if p, err := types.ParseJID(conv.GetPnJID()); err == nil {
				chat = p.ToNonAD()
			}
		}
		cs := chat.String()

		tx, err := a.db.Begin()
		if err != nil {
			continue
		}
		// The conversation's own timestamp places it in the list even if none
		// of its messages turn out to be displayable.
		touchChat(tx, cs, int64(conv.GetConversationTimestamp()))
		if chat.Server == types.GroupServer {
			a.setGroupName(tx, cs, conv.GetName())
		}
		// Only the first sync after pairing describes a chat's settings. Later
		// ones (recent messages, on-demand history) leave those fields empty,
		// and taking them at their word unpinned and unmuted every chat.
		if evt.Data.GetSyncType() == waHistorySync.HistorySync_INITIAL_BOOTSTRAP {
			tx.Exec(`UPDATE chats SET archived=?, pinned=?, ephemeral=?, muted_until=? WHERE jid=?`,
				conv.GetArchived(), conv.GetPinned() > 0, conv.GetEphemeralExpiration(), muteUntil(int64(conv.GetMuteEndTime())), cs)
		} else if secs := conv.GetEphemeralExpiration(); secs > 0 {
			tx.Exec(`UPDATE chats SET ephemeral=? WHERE jid=?`, secs, cs)
		}

		for _, hm := range conv.GetMessages() {
			wm := hm.GetMessage()
			pm, err := cli.ParseWebMessage(orig, wm)
			if err != nil || pm.Message == nil {
				continue
			}
			_, sender := a.resolve(&pm.Info)
			r := a.buildRow(pm, chat, sender)
			if r == nil {
				continue
			}
			if r.FromMe {
				// WebMessageInfo status: 0 error, 1 pending, 2 server ack, 3 delivered, 4 read, 5 played
				r.Status = min(max(int(wm.GetStatus())-1, statusSent), statusRead)
			}
			if ok, _ := insertMessage(tx, r); ok {
				a.decorate(tx, r, pm.Message)
				if wm.GetStarred() {
					tx.Exec(`UPDATE messages SET starred=1 WHERE chat=? AND id=?`, cs, r.ID)
				}
				touchChat(tx, cs, r.TS)
			}
			for _, rx := range wm.GetReactions() {
				rs := a.me()
				if !rx.GetKey().GetFromMe() {
					rs = chat
					if p, err := types.ParseJID(rx.GetKey().GetParticipant()); err == nil && !p.IsEmpty() {
						rs = a.pn(p)
					}
				}
				setReaction(tx, cs, r.ID, rs.String(), rx.GetText())
			}
		}
		// Older messages fetched on request say nothing about what is unread.
		if n := conv.GetUnreadCount(); n > 0 && n < 10000 && evt.Data.GetSyncType() != waHistorySync.HistorySync_ON_DEMAND {
			tx.Exec(`UPDATE chats SET unread=? WHERE jid=?`, n, cs)
			tx.Exec(`UPDATE messages SET unread=1 WHERE chat=? AND id IN
				(SELECT id FROM messages WHERE chat=? AND from_me=0 ORDER BY ts DESC LIMIT ?)`, cs, cs, n)
		}
		tx.Commit()
	}
	a.clearNames()
	a.emit(map[string]any{"type": "chats"})
	a.emit(map[string]any{"type": "messages", "chat": ""})
}
