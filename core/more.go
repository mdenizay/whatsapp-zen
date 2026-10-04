package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/HugoSmits86/nativewebp"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// statusChat is where status updates ("stories") arrive.
const statusChat = "status@broadcast"

// muteUntil normalises WhatsApp's mute end (milliseconds, or -1 for "always")
// to seconds, keeping -1.
func muteUntil(ms int64) int64 {
	if ms < 0 {
		return -1
	}
	return ms / 1000
}

func (a *App) isMuted(chat string) bool {
	var until int64
	a.db.QueryRow(`SELECT muted_until FROM chats WHERE jid=?`, chat).Scan(&until)
	return until < 0 || until > time.Now().Unix()
}

// mute silences a chat for the given seconds; 0 unmutes, -1 mutes for good.
func (a *App) mute(chat string, seconds int) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	until := int64(0)
	patch := appstate.BuildMute(jid, false, 0)
	switch {
	case seconds < 0:
		until = -1
		patch = appstate.BuildMuteAbs(jid, true, proto.Int64(-1))
	case seconds > 0:
		until = time.Now().Unix() + int64(seconds)
		patch = appstate.BuildMute(jid, true, time.Duration(seconds)*time.Second)
	}
	if err := cli.SendAppState(bg, patch); err != nil {
		return err
	}
	a.db.Exec(`UPDATE chats SET muted_until=? WHERE jid=?`, until, chat)
	a.emit(map[string]any{"type": "chats"})
	return nil
}

// setEphemeral turns disappearing messages on (seconds) or off (0).
func (a *App) setEphemeral(chat string, seconds int) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	if err := cli.SetDisappearingTimer(bg, jid, time.Duration(seconds)*time.Second, time.Now()); err != nil {
		return err
	}
	a.db.Exec(`UPDATE chats SET ephemeral=? WHERE jid=?`, seconds, chat)
	a.emit(map[string]any{"type": "chats"})
	return nil
}

// applyExpiration marks an outgoing message as disappearing when its chat has
// a timer, as every client in the chat is expected to.
func (a *App) applyExpiration(r *row, m *waE2E.Message) {
	var secs uint32
	a.db.QueryRow(`SELECT ephemeral FROM chats WHERE jid=?`, r.Chat).Scan(&secs)
	if secs == 0 {
		return
	}
	if m.Conversation != nil {
		m.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: m.Conversation}
		m.Conversation = nil
	}
	var ctx **waE2E.ContextInfo
	switch {
	case m.ExtendedTextMessage != nil:
		ctx = &m.ExtendedTextMessage.ContextInfo
	case m.ImageMessage != nil:
		ctx = &m.ImageMessage.ContextInfo
	case m.VideoMessage != nil:
		ctx = &m.VideoMessage.ContextInfo
	case m.AudioMessage != nil:
		ctx = &m.AudioMessage.ContextInfo
	case m.DocumentMessage != nil:
		ctx = &m.DocumentMessage.ContextInfo
	case m.StickerMessage != nil:
		ctx = &m.StickerMessage.ContextInfo
	default:
		return
	}
	if *ctx == nil {
		*ctx = &waE2E.ContextInfo{}
	}
	(*ctx).Expiration = proto.Uint32(secs)
	a.db.Exec(`UPDATE messages SET expires_at=? WHERE chat=? AND id=?`, r.TS+int64(secs), r.Chat, r.ID)
}

type pollDef struct {
	Options    []string `json:"options"`
	Selectable int      `json:"selectable"`
}

type PollOption struct {
	Name  string `json:"name"`
	Votes int    `json:"votes"`
	Mine  bool   `json:"mine"`
}

type PollJSON struct {
	Options    []PollOption `json:"options"`
	Selectable int          `json:"selectable"`
	Voters     int          `json:"voters"`
}

// decorate records what a freshly stored message carries beyond its text:
// link preview, mentions, poll options and its disappearing time.
func (a *App) decorate(x execer, r *row, m *waE2E.Message) {
	if e := m.GetExtendedTextMessage(); e != nil && e.GetTitle() != "" {
		x.Exec(`UPDATE messages SET link_title=?, link_desc=?, thumb=COALESCE(?, thumb) WHERE chat=? AND id=?`,
			e.GetTitle(), e.GetDescription(), e.GetJPEGThumbnail(), r.Chat, r.ID)
	}
	var def *pollDef
	for _, p := range []*waE2E.PollCreationMessage{m.GetPollCreationMessage(), m.GetPollCreationMessageV2(), m.GetPollCreationMessageV3()} {
		if p != nil {
			def = &pollDef{Selectable: int(p.GetSelectableOptionsCount())}
			for _, o := range p.GetOptions() {
				def.Options = append(def.Options, o.GetOptionName())
			}
		}
	}
	if def != nil {
		b, _ := json.Marshal(def)
		x.Exec(`UPDATE messages SET poll=? WHERE chat=? AND id=?`, string(b), r.Chat, r.ID)
	}
	ex := extract(m)
	if ex == nil || ex.ctx == nil {
		return
	}
	if secs := ex.ctx.GetExpiration(); secs > 0 {
		x.Exec(`UPDATE messages SET expires_at=? WHERE chat=? AND id=?`, r.TS+int64(secs), r.Chat, r.ID)
	}
	if ids := ex.ctx.GetMentionedJID(); len(ids) > 0 && r.Text != "" {
		me := a.meString()
		mentionsMe := false
		for _, id := range ids {
			if j, err := types.ParseJID(id); err == nil && a.pn(j).String() == me {
				mentionsMe = true
			}
		}
		x.Exec(`UPDATE messages SET text=?, mentions_me=? WHERE chat=? AND id=?`, a.mentionNames(r.Text, ids), mentionsMe, r.Chat, r.ID)
	}
}

// mentionNames rewrites the "@1234567890" tokens of a message into "@Name".
func (a *App) mentionNames(text string, ids []string) string {
	for _, id := range ids {
		j, err := types.ParseJID(id)
		if err != nil {
			continue
		}
		name := a.nameOf(a.pn(j).String())
		if a.pn(j).String() == a.meString() {
			name = T("You")
		}
		text = strings.ReplaceAll(text, "@"+j.User, "@"+name)
	}
	return text
}

// attachPolls fills in options and the current tally for poll messages.
func (a *App) attachPolls(msgs []*MsgJSON) {
	me := a.meString()
	for _, m := range msgs {
		if m.pollRaw == "" {
			continue
		}
		var def pollDef
		if json.Unmarshal([]byte(m.pollRaw), &def) != nil {
			continue
		}
		poll := &PollJSON{Selectable: def.Selectable}
		index := map[string]int{}
		for i, name := range def.Options {
			poll.Options = append(poll.Options, PollOption{Name: name})
			index[name] = i
		}
		rows, err := a.db.Query(`SELECT voter, options FROM poll_votes WHERE chat=? AND msg_id=?`, m.Chat, m.ID)
		if err == nil {
			for rows.Next() {
				var voter, raw string
				var chosen []string
				if rows.Scan(&voter, &raw) != nil || json.Unmarshal([]byte(raw), &chosen) != nil || len(chosen) == 0 {
					continue
				}
				poll.Voters++
				for _, name := range chosen {
					if i, ok := index[name]; ok {
						poll.Options[i].Votes++
						if voter == me {
							poll.Options[i].Mine = true
						}
					}
				}
			}
			rows.Close()
		}
		m.Poll = poll
	}
}

func (a *App) pollOptions(chat, id string) (*pollDef, error) {
	var raw string
	if err := a.db.QueryRow(`SELECT poll FROM messages WHERE chat=? AND id=?`, chat, id).Scan(&raw); err != nil {
		return nil, err
	}
	var def pollDef
	if err := json.Unmarshal([]byte(raw), &def); err != nil {
		return nil, errors.New("not a poll")
	}
	return &def, nil
}

func (a *App) saveVote(chat, id, voter string, options []string) {
	b, _ := json.Marshal(options)
	a.db.Exec(`INSERT INTO poll_votes(chat,msg_id,voter,options) VALUES(?,?,?,?)
		ON CONFLICT(chat,msg_id,voter) DO UPDATE SET options=excluded.options`, chat, id, voter, string(b))
	a.emit(map[string]any{"type": "messages", "chat": chat})
}

// onPollVote decrypts someone's vote; it names its choices by SHA-256 hash.
func (a *App) onPollVote(evt *events.Message, chat, voter string) {
	cli := a.client()
	if cli == nil {
		return
	}
	vote, err := cli.DecryptPollVote(bg, evt)
	if err != nil {
		return
	}
	id := evt.Message.GetPollUpdateMessage().GetPollCreationMessageKey().GetID()
	def, err := a.pollOptions(chat, id)
	if err != nil {
		return
	}
	byHash := map[string]string{}
	for _, name := range def.Options {
		sum := sha256.Sum256([]byte(name))
		byHash[hex.EncodeToString(sum[:])] = name
	}
	chosen := []string{}
	for _, h := range vote.GetSelectedOptions() {
		if name, ok := byHash[hex.EncodeToString(h)]; ok {
			chosen = append(chosen, name)
		}
	}
	a.saveVote(chat, id, voter, chosen)
}

func (a *App) sendPoll(chat, name string, options []string) (*MsgJSON, error) {
	cli, jid, err := a.target(chat)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(name) == "" || len(options) < 2 {
		return nil, errors.New("A poll needs a question and at least two options")
	}
	msg := cli.BuildPollCreation(name, options, 1)
	r := a.newRow(cli, jid, "poll", name)
	out, err := a.deliver(cli, jid, r, func() (*waE2E.Message, error) { return msg, nil })
	if err == nil {
		b, _ := json.Marshal(pollDef{Options: options, Selectable: 1})
		a.db.Exec(`UPDATE messages SET poll=? WHERE chat=? AND id=?`, string(b), r.Chat, r.ID)
		out = a.getMessage(r.Chat, r.ID)
	}
	return out, err
}

// vote casts (or, with no options, withdraws) our vote in a poll.
func (a *App) vote(chat, id string, options []string) error {
	cli, jid, err := a.target(chat)
	if err != nil {
		return err
	}
	sender, fromMe, _, err := a.messageKey(jid, id)
	if err != nil {
		return err
	}
	var ts int64
	a.db.QueryRow(`SELECT ts FROM messages WHERE chat=? AND id=?`, chat, id).Scan(&ts)
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{Chat: jid, Sender: sender, IsFromMe: fromMe, IsGroup: jid.Server == types.GroupServer},
		ID:            id, Timestamp: time.Unix(ts, 0),
	}
	msg, err := cli.BuildPollVote(bg, info, options)
	if err != nil {
		return err
	}
	if _, err := cli.SendMessage(bg, jid, msg); err != nil {
		return err
	}
	a.saveVote(chat, id, a.meString(), options)
	return nil
}

func (a *App) sendContact(chat, contact, name string) (*MsgJSON, error) {
	cli, jid, err := a.target(chat)
	if err != nil {
		return nil, err
	}
	who, err := types.ParseJID(contact)
	if err != nil {
		return nil, err
	}
	if name == "" {
		name = a.nameOf(contact)
	}
	vcard := fmt.Sprintf("BEGIN:VCARD\nVERSION:3.0\nFN:%s\nTEL;type=CELL;waid=%s:+%s\nEND:VCARD", name, who.User, who.User)
	msg := &waE2E.Message{ContactMessage: &waE2E.ContactMessage{DisplayName: proto.String(name), Vcard: proto.String(vcard)}}
	r := a.newRow(cli, jid, "other", "👤 "+T("Contact")+": "+name)
	return a.deliver(cli, jid, r, func() (*waE2E.Message, error) { return msg, nil })
}

func (a *App) sendLocation(chat string, lat, lng float64) (*MsgJSON, error) {
	cli, jid, err := a.target(chat)
	if err != nil {
		return nil, err
	}
	msg := &waE2E.Message{LocationMessage: &waE2E.LocationMessage{DegreesLatitude: proto.Float64(lat), DegreesLongitude: proto.Float64(lng)}}
	r := a.newRow(cli, jid, "other", fmt.Sprintf("📍 %s\nhttps://maps.apple.com/?ll=%.6f,%.6f", T("Location"), lat, lng))
	return a.deliver(cli, jid, r, func() (*waE2E.Message, error) { return msg, nil })
}

func like(text string) string {
	return "%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(strings.TrimSpace(text)) + "%"
}

// searchAll finds messages in every chat.
func (a *App) searchAll(text string) ([]*MsgJSON, error) {
	if strings.TrimSpace(text) == "" {
		return []*MsgJSON{}, nil
	}
	return a.queryMessages(`deleted=0 AND chat != ? AND text LIKE ? ESCAPE '\' ORDER BY ts DESC LIMIT 80`, statusChat, like(text))
}

// chatMedia lists a chat's photos and videos, documents, or links.
func (a *App) chatMedia(chat, kind string) ([]*MsgJSON, error) {
	cond := `type IN ('image','video')`
	switch kind {
	case "docs":
		cond = `type='document'`
	case "links":
		cond = `(text LIKE '%http://%' OR text LIKE '%https://%')`
	}
	return a.queryMessages(`chat=? AND deleted=0 AND `+cond+` ORDER BY ts DESC LIMIT 120`, chat)
}

type UserInfoJSON struct {
	About   string `json:"about"`
	Blocked bool   `json:"blocked"`
}

func (a *App) userInfo(jidStr string) (*UserInfoJSON, error) {
	cli, jid, err := a.target(jidStr)
	if err != nil {
		return nil, err
	}
	out := &UserInfoJSON{}
	if info, err := cli.GetUserInfo(bg, []types.JID{jid}); err == nil {
		out.About = info[jid].Status
	}
	if list, err := cli.GetBlocklist(bg); err == nil {
		for _, b := range list.JIDs {
			if a.pn(b) == jid {
				out.Blocked = true
			}
		}
	}
	return out, nil
}

func (a *App) block(jidStr string, on bool) error {
	cli, jid, err := a.target(jidStr)
	if err != nil {
		return err
	}
	action := events.BlocklistChangeActionUnblock
	if on {
		action = events.BlocklistChangeActionBlock
	}
	_, err = cli.UpdateBlocklist(bg, jid, action)
	return err
}

// export writes a chat as plain text, oldest message first.
func (a *App) export(chat, path string) error {
	rows, err := a.db.Query(`SELECT sender, from_me, ts, type, text, file_name FROM messages WHERE chat=? AND deleted=0 ORDER BY ts, id`, chat)
	if err != nil {
		return err
	}
	type line struct {
		sender, typ, text, file string
		fromMe                  bool
		ts                      int64
	}
	var lines []line
	for rows.Next() {
		var l line
		if rows.Scan(&l.sender, &l.fromMe, &l.ts, &l.typ, &l.text, &l.file) == nil {
			lines = append(lines, l)
		}
	}
	rows.Close()
	var out bytes.Buffer
	for _, l := range lines {
		who := T("You")
		if !l.fromMe {
			who = a.nameOf(l.sender)
		}
		body := previewOf(&extracted{typ: l.typ, text: l.text, fileName: l.file})
		if l.typ != "text" && l.typ != "other" && l.text != "" {
			body = previewOf(&extracted{typ: l.typ, fileName: l.file}) + " " + l.text
		}
		fmt.Fprintf(&out, "[%s] %s: %s\n", time.Unix(l.ts, 0).Format("2006-01-02 15:04"), who, body)
	}
	return os.WriteFile(path, out.Bytes(), 0o600)
}

func dirSize(dir string) int64 {
	var total int64
	filepath.Walk(dir, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total
}

// clearCache deletes downloaded media. Anything still on WhatsApp's servers
// is fetched again when it is next looked at.
func (a *App) clearCache() error {
	dir := filepath.Join(a.dir, "media")
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	os.MkdirAll(dir, 0o700)
	_, err := a.db.Exec(`UPDATE messages SET media_path='' WHERE media_path != ''`)
	return err
}

type linkPreview struct {
	url, title, desc string
	thumb            []byte
}

var (
	urlRe   = regexp.MustCompile(`https?://[^\s]+`)
	titleRe = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
	metaRe  = regexp.MustCompile(`(?is)<meta[^>]+>`)
	attrRe  = regexp.MustCompile(`(?is)(property|name|content)\s*=\s*["']([^"']*)["']`)
	httpc   = &http.Client{Timeout: 4 * time.Second}
)

// fetchLinkPreview reads the title, description and picture of the first
// link in a message. It gives up quickly: a preview must not delay sending.
func fetchLinkPreview(text string) *linkPreview {
	link := urlRe.FindString(text)
	if link == "" {
		return nil
	}
	body, ok := httpGet(link, 512<<10)
	if !ok {
		return nil
	}
	p := &linkPreview{url: link}
	image := ""
	for _, tag := range metaRe.FindAllString(string(body), -1) {
		attrs := map[string]string{}
		for _, m := range attrRe.FindAllStringSubmatch(tag, -1) {
			attrs[strings.ToLower(m[1])] = m[2]
		}
		key := attrs["property"]
		if key == "" {
			key = attrs["name"]
		}
		switch strings.ToLower(key) {
		case "og:title":
			p.title = attrs["content"]
		case "og:description", "description":
			if p.desc == "" {
				p.desc = attrs["content"]
			}
		case "og:image":
			image = attrs["content"]
		}
	}
	if p.title == "" {
		if m := titleRe.FindSubmatch(body); m != nil {
			p.title = strings.TrimSpace(string(m[1]))
		}
	}
	if p.title == "" {
		return nil
	}
	if strings.HasPrefix(image, "http") {
		if data, ok := httpGet(image, 3<<20); ok {
			p.thumb = jpegThumb(data, 160)
		}
	}
	return p
}

func httpGet(url string, limit int64) ([]byte, bool) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, false
	}
	// Many sites only send their preview tags to something that looks like a browser.
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh) WhatsApp/2")
	resp, err := httpc.Do(req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, false
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	return data, err == nil && len(data) > 0
}

// jpegThumb shrinks a JPEG or PNG to at most max pixels wide, as a JPEG.
func jpegThumb(data []byte, max int) []byte {
	src, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil
	}
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w == 0 || h == 0 {
		return nil
	}
	nw, nh := w, h
	if w > max {
		nw, nh = max, h*max/w
	}
	if nh == 0 {
		nh = 1
	}
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		for x := 0; x < nw; x++ {
			dst.Set(x, y, src.At(b.Min.X+x*w/nw, b.Min.Y+y*h/nh))
		}
	}
	var out bytes.Buffer
	if jpeg.Encode(&out, dst, &jpeg.Options{Quality: 60}) != nil {
		return nil
	}
	return out.Bytes()
}

// onViewOnce records a placeholder for a view-once message, which only the
// phone can open.
func (a *App) onViewOnce(info *types.MessageInfo) {
	chat, sender := a.resolve(info)
	if !isChatJID(chat) {
		return
	}
	cs := chat.String()
	r := &row{
		Chat: cs, ID: info.ID, Sender: sender.String(), FromMe: info.IsFromMe, TS: info.Timestamp.Unix(),
		Type: "other", Text: "👁 " + T("View-once message. Open it on your phone."), Unread: !info.IsFromMe, Status: statusSent,
	}
	if ok, err := insertMessage(a.db, r); err != nil || !ok {
		return
	}
	touchChat(a.db, cs, r.TS)
	if !r.FromMe {
		a.db.Exec(`UPDATE chats SET unread=unread+1 WHERE jid=?`, cs)
	}
	a.emit(map[string]any{
		"type": "message", "chat": cs, "chat_name": a.nameOf(cs), "msg": a.getMessage(cs, r.ID),
		"notify": !r.FromMe && time.Since(info.Timestamp) < 2*time.Minute && !a.isMuted(cs),
	})
}

// sendStickerImage turns a PNG prepared by the UI (square, transparent
// padding) into a WebP sticker and sends it. macOS cannot write WebP, so the
// encoding happens here.
func (a *App) sendStickerImage(chat, path string) (*MsgJSON, error) {
	cli, jid, err := a.target(chat)
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	src, _, err := image.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	// The encoder is lossless, so a photo can come out large; step the size
	// down until the sticker is light enough to be accepted everywhere.
	var data []byte
	side := 512
	for _, s := range []int{512, 384, 256, 192} {
		var buf bytes.Buffer
		if err := nativewebp.Encode(&buf, scaleSquare(src, s), nil); err != nil {
			return nil, err
		}
		data, side = buf.Bytes(), s
		if len(data) <= 300<<10 {
			break
		}
	}
	r := a.newRow(cli, jid, "sticker", "")
	r.W, r.H = side, side
	r.MediaPath = filepath.Join(a.dir, "media", safeName(r.ID)+".webp")
	if err := os.WriteFile(r.MediaPath, data, 0o600); err != nil {
		r.MediaPath = ""
	}
	return a.deliver(cli, jid, r, func() (*waE2E.Message, error) {
		up, err := cli.Upload(bg, data, whatsmeow.MediaImage)
		if err != nil {
			return nil, err
		}
		return &waE2E.Message{StickerMessage: &waE2E.StickerMessage{
			URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			Mimetype: proto.String("image/webp"), FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(up.FileLength), Width: proto.Uint32(uint32(side)), Height: proto.Uint32(uint32(side)),
		}}, nil
	})
}

// scaleSquare resamples an image to side×side, averaging the source pixels
// under each destination pixel and keeping transparency.
func scaleSquare(src image.Image, side int) image.Image {
	b := src.Bounds()
	if b.Dx() == side && b.Dy() == side {
		return src
	}
	dst := image.NewNRGBA(image.Rect(0, 0, side, side))
	for y := 0; y < side; y++ {
		y0, y1 := b.Min.Y+y*b.Dy()/side, b.Min.Y+(y+1)*b.Dy()/side
		for x := 0; x < side; x++ {
			x0, x1 := b.Min.X+x*b.Dx()/side, b.Min.X+(x+1)*b.Dx()/side
			var r, g, bl, al, n uint64
			for sy := y0; sy < max(y1, y0+1); sy++ {
				for sx := x0; sx < max(x1, x0+1); sx++ {
					cr, cg, cb, ca := src.At(sx, sy).RGBA() // premultiplied, 16 bit
					r, g, bl, al, n = r+uint64(cr), g+uint64(cg), bl+uint64(cb), al+uint64(ca), n+1
				}
			}
			i := dst.PixOffset(x, y)
			if al == 0 {
				continue
			}
			// Back from premultiplied to straight alpha.
			dst.Pix[i] = uint8(r * 255 / al)
			dst.Pix[i+1] = uint8(g * 255 / al)
			dst.Pix[i+2] = uint8(bl * 255 / al)
			dst.Pix[i+3] = uint8(al / n >> 8)
		}
	}
	return dst
}
