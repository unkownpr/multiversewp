// MultiverseWP whatsmeow helper.
//
// Speaks the simple JSON-over-stdio protocol consumed by the Swift WAClient
// (see Sources/Core/WAClient/WireProtocol.swift). One process per WhatsApp
// account. Session data lives in --session-dir, owned by the macOS app.
//
// Wire protocol (newline-delimited JSON):
//   IN  (stdin):  {"id":"<uuid>","type":"<command>","payload":{...}}
//   OUT (stdout): {"type":"<event>","payload":{...}}
//                 {"type":"response","id":"<uuid>","payload":{...},"error":null}
//
// Build:  go build -o bin/whatsmeow-helper ./...
// Run:    whatsmeow-helper --account-id <uuid> --session-dir <path>
//
// Personal use only. Single user, single device. No automation, no mass-DM —
// every outbound send is a direct response to a Swift-side user/MCP action.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

// historyBacklogCap limits how many recent messages we replay per conversation
// during HistorySync. Cold-pair can deliver thousands of messages per chat;
// the Swift side only needs enough context to render the chat list and recent
// scrollback, and the user can request older history on demand.
const historyBacklogCap = 50

// stderrLogger is a tiny waLog.Logger that writes to STDERR so it never
// corrupts the wire protocol we own on STDOUT.
type stderrLogger struct {
	mod string
	min int
}

const (
	logLevelDebug = 0
	logLevelInfo  = 1
	logLevelWarn  = 2
	logLevelError = 3
)

func newStderrLogger(mod string, min int) waLog.Logger {
	return &stderrLogger{mod: mod, min: min}
}

func (s *stderrLogger) outputf(level int, levelName, msg string, args ...interface{}) {
	if level < s.min {
		return
	}
	fmt.Fprintf(os.Stderr, "[%s %s] %s\n", s.mod, levelName, fmt.Sprintf(msg, args...))
}

func (s *stderrLogger) Errorf(msg string, args ...interface{}) {
	s.outputf(logLevelError, "ERROR", msg, args...)
}
func (s *stderrLogger) Warnf(msg string, args ...interface{}) {
	s.outputf(logLevelWarn, "WARN", msg, args...)
}
func (s *stderrLogger) Infof(msg string, args ...interface{}) {
	s.outputf(logLevelInfo, "INFO", msg, args...)
}
func (s *stderrLogger) Debugf(msg string, args ...interface{}) {
	s.outputf(logLevelDebug, "DEBUG", msg, args...)
}
func (s *stderrLogger) Sub(mod string) waLog.Logger {
	return &stderrLogger{mod: s.mod + "/" + mod, min: s.min}
}

type command struct {
	ID      string          `json:"id"`
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

type response struct {
	Type    string                 `json:"type"`
	ID      string                 `json:"id,omitempty"`
	Payload map[string]interface{} `json:"payload"`
	Error   *string                `json:"error,omitempty"`
}

type event struct {
	Type    string                 `json:"type"`
	Payload map[string]interface{} `json:"payload"`
}

type helper struct {
	accountID  string
	sessionDir string

	out     *json.Encoder
	outLock sync.Mutex

	rootCtx context.Context
	stop    context.CancelFunc

	clientMu  sync.Mutex
	client    *whatsmeow.Client
	container *sqlstore.Container

	qrCancelMu sync.Mutex
	qrCancel   context.CancelFunc

	shutdownOnce sync.Once
}

func main() {
	accountID := flag.String("account-id", "", "UUID of the account this helper instance manages")
	sessionDir := flag.String("session-dir", "", "Directory holding the whatsmeow session DB")
	flag.Parse()

	if *accountID == "" || *sessionDir == "" {
		log.Fatalf("usage: whatsmeow-helper --account-id <uuid> --session-dir <path>")
	}
	if err := os.MkdirAll(*sessionDir, 0o700); err != nil {
		log.Fatalf("failed to create session dir: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	h := &helper{
		accountID:  *accountID,
		sessionDir: *sessionDir,
		out:        json.NewEncoder(os.Stdout),
		rootCtx:    ctx,
		stop:       cancel,
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		h.shutdown("signal")
		os.Exit(0)
	}()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 1024*1024), 32*1024*1024)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return
		default:
		}
		var cmd command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			h.replyError("", fmt.Sprintf("invalid json: %v", err))
			continue
		}
		h.dispatch(cmd)
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "stdin scan error: %v\n", err)
	}
	h.shutdown("stdin-closed")
}

func (h *helper) dispatch(cmd command) {
	switch cmd.Type {
	case "connect":
		h.handleConnect(cmd)
	case "disconnect":
		h.replyOK(cmd.ID, nil)
		h.shutdown("requested")
		h.stop()
	case "send_message":
		h.handleSendMessage(cmd)
	case "fetch_history":
		// TODO: walk the local message store / request history sync from whatsmeow.
		h.replyOK(cmd.ID, nil)
	case "download_media":
		// TODO: locate the cached *events.Message proto and call client.Download.
		h.handleDownloadMedia(cmd)
	case "mark_read":
		// TODO: call client.MarkRead with the message IDs in the chat.
		h.replyOK(cmd.ID, nil)
	default:
		h.replyError(cmd.ID, fmt.Sprintf("unknown command: %s", cmd.Type))
	}
}

// handleConnect spins up the real whatsmeow client. On a fresh session-dir it
// drives the QR pairing channel and emits each rotated code as a "qr" event;
// once paired or for an already-paired device it goes straight to Connect.
func (h *helper) handleConnect(cmd command) {
	h.clientMu.Lock()
	already := h.client != nil
	h.clientMu.Unlock()
	if already {
		h.replyOK(cmd.ID, nil)
		return
	}

	dbPath := "file:" + filepath.Join(h.sessionDir, "store.db") + "?_foreign_keys=on"
	dbLog := newStderrLogger("Database", logLevelInfo)
	container, err := sqlstore.New(h.rootCtx, "sqlite3", dbPath, dbLog)
	if err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("open store: %v", err))
		return
	}

	deviceStore, err := container.GetFirstDevice(h.rootCtx)
	if err != nil {
		_ = container.Close()
		h.replyError(cmd.ID, fmt.Sprintf("get device: %v", err))
		return
	}

	clientLog := newStderrLogger("Client", logLevelInfo)
	client := whatsmeow.NewClient(deviceStore, clientLog)
	client.AddEventHandler(h.handleEvent)

	h.clientMu.Lock()
	h.client = client
	h.container = container
	h.clientMu.Unlock()

	h.replyOK(cmd.ID, nil)

	go h.startConnection()
}

func (h *helper) startConnection() {
	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil {
		return
	}

	if client.Store.ID == nil {
		// First-time login: subscribe to QR codes before connecting.
		qrCtx, qrCancel := context.WithCancel(h.rootCtx)
		h.qrCancelMu.Lock()
		h.qrCancel = qrCancel
		h.qrCancelMu.Unlock()

		qrChan, err := client.GetQRChannel(qrCtx)
		if err != nil {
			h.emit(event{Type: "error", Payload: map[string]interface{}{"message": fmt.Sprintf("qr channel: %v", err)}})
			return
		}
		if err := client.Connect(); err != nil {
			h.emit(event{Type: "error", Payload: map[string]interface{}{"message": fmt.Sprintf("connect: %v", err)}})
			return
		}
		go func() {
			for evt := range qrChan {
				switch evt.Event {
				case "code":
					h.emit(event{Type: "qr", Payload: map[string]interface{}{"code": evt.Code}})
				case "success":
					// PairSuccess event will fire from the main handler with the
					// real JID; nothing to do here.
				case "timeout":
					h.emit(event{Type: "error", Payload: map[string]interface{}{"message": "qr timeout"}})
				case "err-client-outdated":
					h.emit(event{Type: "error", Payload: map[string]interface{}{"message": "whatsmeow client outdated"}})
				}
			}
		}()
		return
	}

	if err := client.Connect(); err != nil {
		h.emit(event{Type: "error", Payload: map[string]interface{}{"message": fmt.Sprintf("connect: %v", err)}})
	}
}

func (h *helper) handleEvent(evt interface{}) {
	switch v := evt.(type) {
	case *events.Connected:
		h.emit(event{Type: "connected", Payload: map[string]interface{}{}})
	case *events.Disconnected:
		h.emit(event{Type: "disconnected", Payload: map[string]interface{}{"reason": "server"}})
	case *events.LoggedOut:
		h.emit(event{Type: "disconnected", Payload: map[string]interface{}{"reason": fmt.Sprintf("logged_out:%s", v.Reason)}})
	case *events.PairSuccess:
		pushName := ""
		h.clientMu.Lock()
		if h.client != nil && h.client.Store != nil {
			pushName = h.client.Store.PushName
		}
		h.clientMu.Unlock()
		h.emit(event{Type: "pair_success", Payload: map[string]interface{}{
			"jid":       v.ID.String(),
			"push_name": pushName,
		}})
	case *events.Message:
		h.emitMessage(v)
	case *events.Receipt:
		h.emitReceipt(v)
	case *events.PushName:
		h.emit(event{Type: "contact", Payload: map[string]interface{}{
			"jid":          v.JID.String(),
			"push_name":    v.NewPushName,
			"phone_number": v.JID.User,
		}})
	case *events.HistorySync:
		h.emitHistorySync(v)
	}
}

// extractMessageContent inspects a whatsmeow *waE2E.Message and returns the
// frozen wire-protocol kind plus any body/media/quoted-id derived from the
// strongest match. Used by both the live emitMessage path and the HistorySync
// backfill path so they cannot drift.
func extractMessageContent(msg *waE2E.Message) (kind, body, mimeType, mediaURL string, byteSize int64, quotedID string) {
	if msg == nil {
		return "unsupported", "", "", "", 0, ""
	}
	if text := msg.GetConversation(); text != "" {
		return "text", text, "", "", 0, ""
	}
	if ext := msg.GetExtendedTextMessage(); ext != nil {
		quoted := ""
		if ctx := ext.GetContextInfo(); ctx != nil {
			quoted = ctx.GetStanzaID()
		}
		return "text", ext.GetText(), "", "", 0, quoted
	}
	if img := msg.GetImageMessage(); img != nil {
		quoted := ""
		if ctx := img.GetContextInfo(); ctx != nil {
			quoted = ctx.GetStanzaID()
		}
		return "image", img.GetCaption(), img.GetMimetype(), img.GetURL(), int64(img.GetFileLength()), quoted
	}
	if vid := msg.GetVideoMessage(); vid != nil {
		quoted := ""
		if ctx := vid.GetContextInfo(); ctx != nil {
			quoted = ctx.GetStanzaID()
		}
		return "video", vid.GetCaption(), vid.GetMimetype(), vid.GetURL(), int64(vid.GetFileLength()), quoted
	}
	if aud := msg.GetAudioMessage(); aud != nil {
		quoted := ""
		if ctx := aud.GetContextInfo(); ctx != nil {
			quoted = ctx.GetStanzaID()
		}
		return "audio", "", aud.GetMimetype(), aud.GetURL(), int64(aud.GetFileLength()), quoted
	}
	if doc := msg.GetDocumentMessage(); doc != nil {
		quoted := ""
		if ctx := doc.GetContextInfo(); ctx != nil {
			quoted = ctx.GetStanzaID()
		}
		return "document", doc.GetFileName(), doc.GetMimetype(), doc.GetURL(), int64(doc.GetFileLength()), quoted
	}
	if sticker := msg.GetStickerMessage(); sticker != nil {
		return "sticker", "", sticker.GetMimetype(), sticker.GetURL(), int64(sticker.GetFileLength()), ""
	}
	return "unsupported", "", "", "", 0, ""
}

func (h *helper) emitMessage(v *events.Message) {
	info := v.Info
	msg := v.Message
	if msg == nil {
		return
	}

	kind, body, mimeType, mediaURL, byteSize, quotedID := extractMessageContent(msg)

	payload := map[string]interface{}{
		"id":               info.ID,
		"chat_jid":         info.Chat.String(),
		"sender_jid":       info.Sender.String(),
		"sender_push_name": info.PushName,
		"is_from_me":       info.IsFromMe,
		"is_group":         info.IsGroup,
		"kind":             kind,
		"timestamp":        info.Timestamp.Unix(),
	}
	if body != "" {
		payload["body"] = body
	}
	if mimeType != "" {
		payload["mime_type"] = mimeType
	}
	if mediaURL != "" {
		payload["media_url"] = mediaURL
	}
	if byteSize > 0 {
		payload["media_byte_size"] = byteSize
	}
	if quotedID != "" {
		payload["quoted_message_id"] = quotedID
	}

	h.emit(event{Type: "message", Payload: payload})
}

// emitHistorySync translates a whatsmeow HistorySync blob into the same wire
// envelopes the live event stream uses, so the Swift ingestion service can
// backfill pre-pair contacts and chats without any new protocol surface.
//
// Pushnames become "contact" events. Each Conversation's messages are sorted
// by MessageTimestamp descending, capped at historyBacklogCap, then emitted in
// chronological order as "message" events.
func (h *helper) emitHistorySync(v *events.HistorySync) {
	if v == nil || v.Data == nil {
		return
	}
	data := v.Data

	for _, pn := range data.GetPushnames() {
		jid := pn.GetID()
		name := pn.GetPushname()
		if jid == "" || name == "" {
			continue
		}
		phone := jid
		if at := strings.IndexByte(jid, '@'); at >= 0 {
			phone = jid[:at]
		}
		h.emit(event{Type: "contact", Payload: map[string]interface{}{
			"jid":          jid,
			"push_name":    name,
			"phone_number": phone,
		}})
	}

	for _, conv := range data.GetConversations() {
		h.emitHistoryConversation(conv)
	}
}

func (h *helper) emitHistoryConversation(conv *waHistorySync.Conversation) {
	if conv == nil {
		return
	}
	chatJID := conv.GetID()
	if chatJID == "" {
		return
	}
	rawMsgs := conv.GetMessages()
	if len(rawMsgs) == 0 {
		return
	}

	// Sort descending by message timestamp, then keep only the newest N. We
	// then flip to chronological order before emission so downstream stores
	// can append without resorting.
	msgs := make([]*waHistorySync.HistorySyncMsg, 0, len(rawMsgs))
	for _, m := range rawMsgs {
		if m != nil && m.GetMessage() != nil {
			msgs = append(msgs, m)
		}
	}
	sort.SliceStable(msgs, func(i, j int) bool {
		return msgs[i].GetMessage().GetMessageTimestamp() > msgs[j].GetMessage().GetMessageTimestamp()
	})
	if len(msgs) > historyBacklogCap {
		msgs = msgs[:historyBacklogCap]
	}
	// Flip to chronological order.
	for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
		msgs[i], msgs[j] = msgs[j], msgs[i]
	}

	isGroup := strings.Contains(chatJID, "@g.us")

	for _, hm := range msgs {
		wmi := hm.GetMessage()
		if wmi == nil {
			continue
		}
		inner := wmi.GetMessage()
		if inner == nil {
			// Skip control / stub frames — they have no displayable content
			// in our current schema and would otherwise show as "unsupported".
			continue
		}
		key := wmi.GetKey()
		if key == nil {
			continue
		}
		id := key.GetID()
		if id == "" {
			continue
		}

		senderJID := key.GetParticipant()
		if senderJID == "" {
			// Direct chat: sender is the peer (or self if FromMe).
			senderJID = chatJID
		}

		kind, body, mimeType, mediaURL, byteSize, quotedID := extractMessageContent(inner)

		payload := map[string]interface{}{
			"id":               id,
			"chat_jid":         chatJID,
			"sender_jid":       senderJID,
			"sender_push_name": wmi.GetPushName(),
			"is_from_me":       key.GetFromMe(),
			"is_group":         isGroup,
			"kind":             kind,
			"timestamp":        int64(wmi.GetMessageTimestamp()),
		}
		if body != "" {
			payload["body"] = body
		}
		if mimeType != "" {
			payload["mime_type"] = mimeType
		}
		if mediaURL != "" {
			payload["media_url"] = mediaURL
		}
		if byteSize > 0 {
			payload["media_byte_size"] = byteSize
		}
		if quotedID != "" {
			payload["quoted_message_id"] = quotedID
		}

		h.emit(event{Type: "message", Payload: payload})
	}
}

func (h *helper) emitReceipt(v *events.Receipt) {
	var status string
	switch v.Type {
	case types.ReceiptTypeDelivered:
		status = "delivered"
	case types.ReceiptTypeRead, types.ReceiptTypeReadSelf:
		status = "read"
	case types.ReceiptTypePlayed, types.ReceiptTypePlayedSelf:
		status = "read"
	default:
		return
	}
	for _, id := range v.MessageIDs {
		h.emit(event{Type: "delivery", Payload: map[string]interface{}{
			"message_id": id,
			"status":     status,
		}})
	}
}

func (h *helper) handleSendMessage(cmd command) {
	var payload struct {
		ChatJID         string `json:"chat_jid"`
		Text            string `json:"text"`
		QuotedMessageID string `json:"quoted_message_id"`
	}
	if err := json.Unmarshal(cmd.Payload, &payload); err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("invalid payload: %v", err))
		return
	}
	if payload.ChatJID == "" {
		h.replyError(cmd.ID, "chat_jid is required")
		return
	}

	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil || !client.IsConnected() {
		h.replyError(cmd.ID, "not connected")
		return
	}

	jid, err := types.ParseJID(payload.ChatJID)
	if err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("invalid chat_jid: %v", err))
		return
	}

	msg := &waE2E.Message{
		Conversation: proto.String(payload.Text),
	}

	resp, err := client.SendMessage(h.rootCtx, jid, msg)
	if err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("send: %v", err))
		return
	}
	h.replyOK(cmd.ID, map[string]interface{}{"message_id": resp.ID})
	h.emit(event{Type: "delivery", Payload: map[string]interface{}{
		"message_id": resp.ID,
		"status":     "sent",
	}})
}

func (h *helper) handleDownloadMedia(cmd command) {
	// TODO(media): re-fetch the original *events.Message from the local store
	// and call client.Download to materialise the bytes under sessionDir/media.
	var payload struct {
		MessageID string `json:"message_id"`
	}
	_ = json.Unmarshal(cmd.Payload, &payload)
	h.replyError(cmd.ID, "download_media not yet implemented")
}

func (h *helper) shutdown(reason string) {
	h.shutdownOnce.Do(func() {
		h.qrCancelMu.Lock()
		if h.qrCancel != nil {
			h.qrCancel()
			h.qrCancel = nil
		}
		h.qrCancelMu.Unlock()

		h.clientMu.Lock()
		client := h.client
		container := h.container
		h.client = nil
		h.container = nil
		h.clientMu.Unlock()

		if client != nil {
			client.Disconnect()
		}
		if container != nil {
			_ = container.Close()
		}
		h.emit(event{Type: "disconnected", Payload: map[string]interface{}{"reason": reason}})
	})
}

func (h *helper) emit(e event) {
	h.outLock.Lock()
	defer h.outLock.Unlock()
	if e.Payload == nil {
		e.Payload = map[string]interface{}{}
	}
	if err := h.out.Encode(e); err != nil {
		fmt.Fprintf(os.Stderr, "emit failed: %v\n", err)
	}
}

func (h *helper) replyOK(id string, payload map[string]interface{}) {
	if payload == nil {
		payload = map[string]interface{}{"ok": true}
	} else {
		payload["ok"] = true
	}
	h.outLock.Lock()
	defer h.outLock.Unlock()
	_ = h.out.Encode(response{Type: "response", ID: id, Payload: payload})
}

func (h *helper) replyError(id, message string) {
	h.outLock.Lock()
	defer h.outLock.Unlock()
	err := message
	_ = h.out.Encode(response{
		Type:    "response",
		ID:      id,
		Payload: map[string]interface{}{"ok": false},
		Error:   &err,
	})
}
