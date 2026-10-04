package main

import (
	"context"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/types"
)

// What was last asked of the phone per chat, so the same page is not requested
// over and over while the answer is on its way (or will never come).
type historyAsk struct {
	before string
	at     time.Time
}

var (
	historyMu    sync.Mutex
	historyAsked = map[string]historyAsk{}
)

// fetchHistory asks the phone for the messages just before the oldest one this
// Mac has of a chat. A newly linked device is only sent the recent part of
// each conversation; the rest stays on the phone until it is asked for. The
// answer arrives later as an on-demand history sync (see onHistory).
//
// Reports whether a request went out. A chat with no message at all has
// nothing to ask from, and is left alone.
func (a *App) fetchHistory(chat string) (bool, error) {
	cli := a.client()
	if cli == nil || !cli.IsConnected() {
		return false, nil
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		return false, err
	}
	var (
		id     string
		fromMe bool
		ts     int64
	)
	if a.db.QueryRow(`SELECT id,from_me,ts FROM messages WHERE chat=? ORDER BY ts ASC, id ASC LIMIT 1`, chat).Scan(&id, &fromMe, &ts) != nil {
		return false, nil
	}
	key := a.id + "/" + chat
	historyMu.Lock()
	last := historyAsked[key]
	// The phone may have been offline; the same page may be asked again later.
	asked := last.before == id && time.Since(last.at) < time.Minute
	if !asked {
		historyAsked[key] = historyAsk{id, time.Now()}
	}
	historyMu.Unlock()
	if asked {
		return false, nil
	}
	req := cli.BuildHistorySyncRequest(&types.MessageInfo{
		MessageSource: types.MessageSource{Chat: jid, IsFromMe: fromMe},
		ID:            id,
		Timestamp:     time.Unix(ts, 0),
	}, 50)
	ctx, cancel := context.WithTimeout(bg, 20*time.Second)
	defer cancel()
	if _, err := cli.SendPeerMessage(ctx, req); err != nil {
		historyMu.Lock()
		delete(historyAsked, key)
		historyMu.Unlock()
		return false, err
	}
	return true, nil
}
