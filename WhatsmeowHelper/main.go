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
	"mime"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

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

// Default per-kind auto-download caps. The Swift UI shows a "Tap to download"
// placeholder for any media that exceeds these — bytes are still decrypted on
// demand via the `download_media` command. Override uniformly with the env
// var MULTIVERSEWP_MEDIA_CAP_MB (an integer expressed in megabytes).
const (
	defaultMediaCapImageMB    = 8
	defaultMediaCapVideoMB    = 20
	defaultMediaCapAudioMB    = 10
	defaultMediaCapDocumentMB = 50
	defaultMediaCapStickerMB  = 4
)

// mediaCap returns the soft cap (in bytes) used to decide whether the helper
// should auto-download a freshly received media message. A 0 size means we
// have no hint (history replay sometimes omits FileLength) — in that case we
// pessimistically assume "within cap" so the user still gets the file inline.
func mediaCap(kind string) int64 {
	override := strings.TrimSpace(os.Getenv("MULTIVERSEWP_MEDIA_CAP_MB"))
	if override != "" {
		if n, err := strconv.ParseInt(override, 10, 64); err == nil && n > 0 {
			return n * 1024 * 1024
		}
	}
	switch kind {
	case "image":
		return int64(defaultMediaCapImageMB) * 1024 * 1024
	case "video":
		return int64(defaultMediaCapVideoMB) * 1024 * 1024
	case "audio":
		return int64(defaultMediaCapAudioMB) * 1024 * 1024
	case "document":
		return int64(defaultMediaCapDocumentMB) * 1024 * 1024
	case "sticker":
		return int64(defaultMediaCapStickerMB) * 1024 * 1024
	default:
		return 0
	}
}

// extensionForMimeType maps a wire MIME string to a friendly file extension.
// Falls back to Go's `mime` package and finally "bin" so the on-disk file
// always has *some* suffix Quick Look can dispatch on.
func extensionForMimeType(mimeType string) string {
	switch strings.ToLower(strings.TrimSpace(strings.Split(mimeType, ";")[0])) {
	case "image/jpeg", "image/jpg":
		return "jpg"
	case "image/png":
		return "png"
	case "image/gif":
		return "gif"
	case "image/webp":
		return "webp"
	case "image/heic":
		return "heic"
	case "video/mp4":
		return "mp4"
	case "video/quicktime":
		return "mov"
	case "video/3gpp":
		return "3gp"
	case "audio/ogg", "audio/ogg; codecs=opus":
		return "ogg"
	case "audio/mpeg":
		return "mp3"
	case "audio/mp4", "audio/aac":
		return "m4a"
	case "audio/wav", "audio/x-wav":
		return "wav"
	case "application/pdf":
		return "pdf"
	case "application/zip":
		return "zip"
	case "application/msword":
		return "doc"
	case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
		return "docx"
	case "application/vnd.ms-excel":
		return "xls"
	case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
		return "xlsx"
	}
	exts, err := mime.ExtensionsByType(mimeType)
	if err == nil && len(exts) > 0 {
		// mime.ExtensionsByType includes the leading dot.
		return strings.TrimPrefix(exts[0], ".")
	}
	return "bin"
}

// mediaUploadKind maps our wire `kind` string to the whatsmeow MediaType
// constant required by `client.Upload`. Returns false for kinds we cannot
// upload directly (e.g. unsupported / sticker without explicit MediaType).
func mediaUploadKind(kind string) (whatsmeow.MediaType, bool) {
	switch kind {
	case "image":
		return whatsmeow.MediaImage, true
	case "video":
		return whatsmeow.MediaVideo, true
	case "audio":
		return whatsmeow.MediaAudio, true
	case "document":
		return whatsmeow.MediaDocument, true
	}
	return "", false
}

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

	// protoCache keeps a clone of every media-bearing inbound *waE2E.Message
	// keyed by message ID so on-demand `download_media` requests can re-run
	// the decryption without re-fetching the envelope. We only retain the
	// most recent N entries; cold-cache misses fall back to returning the
	// existing on-disk file path if one is present.
	protoCacheMu sync.Mutex
	protoCache   map[string]*waE2E.Message
	protoOrder   []string

	// groupTitles caches the group-chat name we've already fetched via
	// client.GetGroupInfo. Lets the helper emit a chat_info event the
	// first time it sees a group message, then skip the network round-trip
	// on subsequent messages from the same group.
	groupTitlesMu sync.Mutex
	groupTitles   map[string]string

	shutdownOnce sync.Once
}

// protoCacheCap bounds the in-memory cache size so a long-running helper
// process does not retain the entire chat history. 256 messages covers the
// active scroll-back of a typical session.
const protoCacheCap = 256

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
		protoCache: make(map[string]*waE2E.Message),
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
	case "list_group_members":
		h.handleListGroupMembers(cmd)
	case "create_group":
		h.handleCreateGroup(cmd)
	case "check_phone":
		h.handleCheckPhone(cmd)
	case "subscribe_presence":
		h.handleSubscribePresence(cmd)
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
		// As soon as we're online, walk every joined group and broadcast a
		// chat_info event so the Swift side can replace JID-prefix /
		// sender-name placeholders with the real group title.
		go h.refreshAllGroupTitles()
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
	case *events.Presence:
		// Whatsmeow only delivers Presence for JIDs we have subscribed to.
		// We subscribe in handleListChats so the chat list bootstrap is
		// enough; the From JID is the contact whose presence changed.
		payload := map[string]interface{}{
			"jid":         v.From.String(),
			"unavailable": v.Unavailable,
		}
		if !v.LastSeen.IsZero() {
			payload["last_seen"] = v.LastSeen.Unix()
		}
		h.emit(event{Type: "presence", Payload: payload})
	case *events.ChatPresence:
		// Typing / recording indicator. State is "composing" or "paused";
		// Media is "" for typing, "audio" for recording.
		h.emit(event{Type: "chat_presence", Payload: map[string]interface{}{
			"chat_jid": v.MessageSource.Chat.String(),
			"sender":   v.MessageSource.Sender.String(),
			"state":    string(v.State),
			"media":    string(v.Media),
		}})
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

// cacheProto stores a clone of the inbound *waE2E.Message keyed by ID. The
// cache is bounded; the oldest entry is evicted when the cap is reached so the
// helper does not retain unlimited history.
func (h *helper) cacheProto(id string, msg *waE2E.Message) {
	if id == "" || msg == nil {
		return
	}
	h.protoCacheMu.Lock()
	defer h.protoCacheMu.Unlock()
	if _, exists := h.protoCache[id]; exists {
		return
	}
	if len(h.protoOrder) >= protoCacheCap {
		oldest := h.protoOrder[0]
		h.protoOrder = h.protoOrder[1:]
		delete(h.protoCache, oldest)
	}
	h.protoCache[id] = msg
	h.protoOrder = append(h.protoOrder, id)
}

func (h *helper) cachedProto(id string) *waE2E.Message {
	h.protoCacheMu.Lock()
	defer h.protoCacheMu.Unlock()
	return h.protoCache[id]
}

// mediaDir returns the per-session directory media bytes are written to.
// Created on demand with 0o700 — the helper writes here exclusively.
func (h *helper) mediaDir() (string, error) {
	dir := filepath.Join(h.sessionDir, "media")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// downloadable produces the strongest concrete media accessor the proto can
// offer. The returned interface is the same one `client.Download` consumes; a
// nil result means the message has no downloadable media payload.
func downloadable(msg *waE2E.Message) whatsmeow.DownloadableMessage {
	if msg == nil {
		return nil
	}
	if img := msg.GetImageMessage(); img != nil {
		return img
	}
	if vid := msg.GetVideoMessage(); vid != nil {
		return vid
	}
	if aud := msg.GetAudioMessage(); aud != nil {
		return aud
	}
	if doc := msg.GetDocumentMessage(); doc != nil {
		return doc
	}
	if sticker := msg.GetStickerMessage(); sticker != nil {
		return sticker
	}
	return nil
}

// downloadAndPersist decrypts the media body referenced by `msg`, writes it to
// `<sessionDir>/media/<id>.<ext>` and returns the absolute path. Errors are
// returned to the caller — the live event path treats them as non-fatal so the
// metadata envelope still ships even when media cannot be materialised.
func (h *helper) downloadAndPersist(ctx context.Context, id, kind, mimeType string, msg *waE2E.Message) (string, error) {
	if id == "" || msg == nil {
		return "", fmt.Errorf("missing id or message")
	}
	dl := downloadable(msg)
	if dl == nil {
		return "", fmt.Errorf("message has no downloadable payload")
	}
	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil {
		return "", fmt.Errorf("client not initialised")
	}
	data, err := client.Download(ctx, dl)
	if err != nil {
		return "", fmt.Errorf("download: %w", err)
	}
	dir, err := h.mediaDir()
	if err != nil {
		return "", fmt.Errorf("mediaDir: %w", err)
	}
	ext := extensionForMimeType(mimeType)
	// Sanitise the message ID just in case — IDs are typically opaque
	// strings but we want a safe filename component.
	safe := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		}
		return '_'
	}, id)
	path := filepath.Join(dir, fmt.Sprintf("%s.%s", safe, ext))
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", fmt.Errorf("write: %w", err)
	}
	_ = kind // currently unused; reserved for kind-specific post-processing.
	return path, nil
}

// shouldAutoDownload returns true when the helper should pull bytes inline as
// part of the regular message-event emit. Caller supplies the proto kind and
// the proto-declared byte size; a zero size means we have no hint and should
// optimistically proceed.
func shouldAutoDownload(kind string, byteSize int64) bool {
	cap := mediaCap(kind)
	if cap == 0 {
		return false
	}
	if byteSize <= 0 {
		return true
	}
	return byteSize <= cap
}

// maybeAutoDownload is the helper used by both the live and the HistorySync
// paths. It caches the proto for later on-demand downloads, then (when within
// the size cap) decrypts the body and returns the on-disk path. Failures are
// logged to stderr and an empty path is returned — callers should still emit
// the metadata envelope.
func (h *helper) maybeAutoDownload(id, kind, mimeType string, byteSize int64, msg *waE2E.Message) string {
	if id == "" || msg == nil || downloadable(msg) == nil {
		return ""
	}
	h.cacheProto(id, msg)
	if !shouldAutoDownload(kind, byteSize) {
		return ""
	}
	path, err := h.downloadAndPersist(h.rootCtx, id, kind, mimeType, msg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[Media] auto-download failed id=%s kind=%s: %v\n", id, kind, err)
		return ""
	}
	return path
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
	if mediaPath := h.maybeAutoDownload(info.ID, kind, mimeType, byteSize, msg); mediaPath != "" {
		payload["media_path"] = mediaPath
	}

	h.emit(event{Type: "message", Payload: payload})

	if info.IsGroup {
		go h.ensureGroupChatInfo(info.Chat.String())
	}
}

// refreshAllGroupTitles asks whatsmeow for every group this account is in
// and emits a chat_info event per group so the Swift side can heal stale
// titles left over from earlier ingestion paths (HistorySync, individual
// message rows that were labelled with the sender's name, etc.).
func (h *helper) refreshAllGroupTitles() {
	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil {
		return
	}

	ctx, cancel := context.WithTimeout(h.rootCtx, 15*time.Second)
	defer cancel()
	groups, err := client.GetJoinedGroups(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "refreshAllGroupTitles failed: %v\n", err)
		return
	}

	h.groupTitlesMu.Lock()
	if h.groupTitles == nil {
		h.groupTitles = make(map[string]string)
	}
	h.groupTitlesMu.Unlock()

	for _, info := range groups {
		title := strings.TrimSpace(info.GroupName.Name)
		if title == "" {
			continue
		}
		chatJID := info.JID.String()

		h.groupTitlesMu.Lock()
		h.groupTitles[chatJID] = title
		h.groupTitlesMu.Unlock()

		h.emit(event{Type: "chat_info", Payload: map[string]interface{}{
			"jid":      chatJID,
			"title":    title,
			"is_group": true,
		}})
	}
}

// ensureGroupChatInfo lazily fetches the human-readable name for a group
// JID and emits a chat_info event the first time we learn it. Subsequent
// messages from the same group reuse the cached title.
func (h *helper) ensureGroupChatInfo(chatJID string) {
	h.groupTitlesMu.Lock()
	if h.groupTitles == nil {
		h.groupTitles = make(map[string]string)
	}
	cached, ok := h.groupTitles[chatJID]
	h.groupTitlesMu.Unlock()
	if ok && cached != "" {
		return
	}

	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil {
		return
	}

	jid, err := types.ParseJID(chatJID)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(h.rootCtx, 8*time.Second)
	defer cancel()
	info, err := client.GetGroupInfo(ctx, jid)
	if err != nil || info == nil {
		return
	}

	title := strings.TrimSpace(info.GroupName.Name)
	if title == "" {
		return
	}

	h.groupTitlesMu.Lock()
	h.groupTitles[chatJID] = title
	h.groupTitlesMu.Unlock()

	h.emit(event{Type: "chat_info", Payload: map[string]interface{}{
		"jid":      chatJID,
		"title":    title,
		"is_group": true,
	}})
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
		if mediaPath := h.maybeAutoDownload(id, kind, mimeType, byteSize, inner); mediaPath != "" {
			payload["media_path"] = mediaPath
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
		MediaPath       string `json:"media_path"`
		MimeType        string `json:"mime_type"`
		Caption         string `json:"caption"`
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

	var msg *waE2E.Message
	var sentKind string
	var sentLocalPath string
	if payload.MediaPath != "" {
		built, kind, err := h.buildOutgoingMediaMessage(h.rootCtx, payload.MediaPath, payload.MimeType, payload.Caption)
		if err != nil {
			h.replyError(cmd.ID, fmt.Sprintf("attach: %v", err))
			return
		}
		msg = built
		sentKind = kind
		sentLocalPath = payload.MediaPath
	} else {
		msg = &waE2E.Message{Conversation: proto.String(payload.Text)}
	}

	resp, err := client.SendMessage(h.rootCtx, jid, msg)
	if err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("send: %v", err))
		return
	}

	replyPayload := map[string]interface{}{"message_id": resp.ID}
	if sentLocalPath != "" {
		replyPayload["local_path"] = sentLocalPath
		replyPayload["kind"] = sentKind
	}
	h.replyOK(cmd.ID, replyPayload)

	deliveryPayload := map[string]interface{}{
		"message_id": resp.ID,
		"status":     "sent",
	}
	if sentLocalPath != "" {
		// Surface the local copy so the Swift side can render the outgoing
		// thumbnail without waiting for the server to round-trip the media
		// proto back to us.
		deliveryPayload["media_path"] = sentLocalPath
	}
	h.emit(event{Type: "delivery", Payload: deliveryPayload})
}

// buildOutgoingMediaMessage uploads the bytes at `path` to WhatsApp's media
// store and returns the corresponding *waE2E.Message (Image/Video/Audio/
// Document) plus the wire-protocol `kind` describing it.
func (h *helper) buildOutgoingMediaMessage(ctx context.Context, path, mimeType, caption string) (*waE2E.Message, string, error) {
	if path == "" {
		return nil, "", fmt.Errorf("empty media_path")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", fmt.Errorf("read: %w", err)
	}
	if mimeType == "" {
		// Best-effort sniff via the file extension; the user-facing layer
		// usually already supplies an explicit MIME but historic clients may
		// omit it.
		mimeType = mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
		if mimeType == "" {
			mimeType = "application/octet-stream"
		}
	}
	kind := mimeKind(mimeType)
	mediaType, ok := mediaUploadKind(kind)
	if !ok {
		return nil, "", fmt.Errorf("unsupported media kind: %s", kind)
	}
	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil {
		return nil, "", fmt.Errorf("client not initialised")
	}
	uploaded, err := client.Upload(ctx, data, mediaType)
	if err != nil {
		return nil, "", fmt.Errorf("upload: %w", err)
	}

	switch kind {
	case "image":
		msg := &waE2E.Message{
			ImageMessage: &waE2E.ImageMessage{
				Caption:       proto.String(caption),
				Mimetype:      proto.String(mimeType),
				URL:           &uploaded.URL,
				DirectPath:    &uploaded.DirectPath,
				MediaKey:      uploaded.MediaKey,
				FileEncSHA256: uploaded.FileEncSHA256,
				FileSHA256:    uploaded.FileSHA256,
				FileLength:    &uploaded.FileLength,
			},
		}
		return msg, kind, nil
	case "video":
		msg := &waE2E.Message{
			VideoMessage: &waE2E.VideoMessage{
				Caption:       proto.String(caption),
				Mimetype:      proto.String(mimeType),
				URL:           &uploaded.URL,
				DirectPath:    &uploaded.DirectPath,
				MediaKey:      uploaded.MediaKey,
				FileEncSHA256: uploaded.FileEncSHA256,
				FileSHA256:    uploaded.FileSHA256,
				FileLength:    &uploaded.FileLength,
			},
		}
		return msg, kind, nil
	case "audio":
		msg := &waE2E.Message{
			AudioMessage: &waE2E.AudioMessage{
				Mimetype:      proto.String(mimeType),
				URL:           &uploaded.URL,
				DirectPath:    &uploaded.DirectPath,
				MediaKey:      uploaded.MediaKey,
				FileEncSHA256: uploaded.FileEncSHA256,
				FileSHA256:    uploaded.FileSHA256,
				FileLength:    &uploaded.FileLength,
			},
		}
		return msg, kind, nil
	case "document":
		filename := filepath.Base(path)
		msg := &waE2E.Message{
			DocumentMessage: &waE2E.DocumentMessage{
				Title:         proto.String(filename),
				FileName:      proto.String(filename),
				Mimetype:      proto.String(mimeType),
				URL:           &uploaded.URL,
				DirectPath:    &uploaded.DirectPath,
				MediaKey:      uploaded.MediaKey,
				FileEncSHA256: uploaded.FileEncSHA256,
				FileSHA256:    uploaded.FileSHA256,
				FileLength:    &uploaded.FileLength,
				Caption:       proto.String(caption),
			},
		}
		return msg, kind, nil
	}
	return nil, "", fmt.Errorf("unsupported media kind: %s", kind)
}

// mimeKind classifies a MIME type into the wire-protocol kind string. Falls
// back to "document" for anything that isn't obviously a/v/i so the receiver
// at least sees the file with a generic icon.
func mimeKind(mimeType string) string {
	lower := strings.ToLower(strings.TrimSpace(strings.Split(mimeType, ";")[0]))
	switch {
	case strings.HasPrefix(lower, "image/"):
		return "image"
	case strings.HasPrefix(lower, "video/"):
		return "video"
	case strings.HasPrefix(lower, "audio/"):
		return "audio"
	default:
		return "document"
	}
}

// handleDownloadMedia decrypts the media bytes for a previously-emitted message
// and returns the on-disk path. If the proto cache no longer holds the message
// (e.g. the helper was restarted) we fall back to any existing file under
// sessionDir/media that matches the ID prefix.
func (h *helper) handleDownloadMedia(cmd command) {
	var payload struct {
		MessageID string `json:"message_id"`
	}
	if err := json.Unmarshal(cmd.Payload, &payload); err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("invalid payload: %v", err))
		return
	}
	if payload.MessageID == "" {
		h.replyError(cmd.ID, "message_id is required")
		return
	}

	// If we already have a copy on disk, return it without re-downloading.
	if existing := h.findExistingMediaFile(payload.MessageID); existing != "" {
		h.replyOK(cmd.ID, map[string]interface{}{"local_path": existing})
		h.emit(event{Type: "delivery", Payload: map[string]interface{}{
			"message_id": payload.MessageID,
			"status":     "downloaded",
			"media_path": existing,
		}})
		return
	}

	msg := h.cachedProto(payload.MessageID)
	if msg == nil {
		h.replyError(cmd.ID, "message proto not cached; restart helper after fresh receipt")
		return
	}
	kind, _, mimeType, _, _, _ := extractMessageContent(msg)
	path, err := h.downloadAndPersist(h.rootCtx, payload.MessageID, kind, mimeType, msg)
	if err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("download: %v", err))
		return
	}
	h.replyOK(cmd.ID, map[string]interface{}{"local_path": path})
	h.emit(event{Type: "delivery", Payload: map[string]interface{}{
		"message_id": payload.MessageID,
		"status":     "downloaded",
		"media_path": path,
	}})
}

// handleListGroupMembers resolves a group chat's participants via
// client.GetGroupInfo. Runs in its own goroutine so the network round-trip
// never blocks the event-handler goroutine that calls into dispatch from the
// stdin scanner. The MCP layer uses this to expose group membership without
// keeping a local mirror.
func (h *helper) handleListGroupMembers(cmd command) {
	var payload struct {
		ChatJID string `json:"chat_jid"`
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

	go func() {
		ctx, cancel := context.WithTimeout(h.rootCtx, 15*time.Second)
		defer cancel()
		info, err := client.GetGroupInfo(ctx, jid)
		if err != nil || info == nil {
			if err == nil {
				err = fmt.Errorf("group not found")
			}
			h.replyError(cmd.ID, fmt.Sprintf("get_group_info: %v", err))
			return
		}
		members := make([]map[string]interface{}, 0, len(info.Participants))
		for _, p := range info.Participants {
			entry := map[string]interface{}{
				"jid":            p.JID.String(),
				"is_admin":       p.IsAdmin,
				"is_super_admin": p.IsSuperAdmin,
			}
			if p.PhoneNumber.User != "" {
				entry["phone_number"] = p.PhoneNumber.User
			} else if p.JID.User != "" {
				entry["phone_number"] = p.JID.User
			}
			if p.DisplayName != "" {
				entry["push_name"] = p.DisplayName
			}
			members = append(members, entry)
		}
		h.replyOK(cmd.ID, map[string]interface{}{"members": members})
	}()
}

// handleCreateGroup creates a new WhatsApp group via client.CreateGroup. The
// participant_jids array is parsed into types.JID values; any malformed entry
// short-circuits the request before hitting the wire.
func (h *helper) handleCreateGroup(cmd command) {
	var payload struct {
		Subject         string   `json:"subject"`
		ParticipantJIDs []string `json:"participant_jids"`
	}
	if err := json.Unmarshal(cmd.Payload, &payload); err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("invalid payload: %v", err))
		return
	}
	subject := strings.TrimSpace(payload.Subject)
	if subject == "" {
		h.replyError(cmd.ID, "subject is required")
		return
	}
	if len(payload.ParticipantJIDs) == 0 {
		h.replyError(cmd.ID, "at least one participant is required")
		return
	}

	parsed := make([]types.JID, 0, len(payload.ParticipantJIDs))
	for _, raw := range payload.ParticipantJIDs {
		jid, err := types.ParseJID(raw)
		if err != nil {
			h.replyError(cmd.ID, fmt.Sprintf("invalid participant jid %q: %v", raw, err))
			return
		}
		parsed = append(parsed, jid)
	}

	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil || !client.IsConnected() {
		h.replyError(cmd.ID, "not connected")
		return
	}

	go func() {
		ctx, cancel := context.WithTimeout(h.rootCtx, 30*time.Second)
		defer cancel()
		info, err := client.CreateGroup(ctx, whatsmeow.ReqCreateGroup{
			Name:         subject,
			Participants: parsed,
		})
		if err != nil {
			h.replyError(cmd.ID, fmt.Sprintf("create_group: %v", err))
			return
		}
		jidStr := info.JID.String()
		h.replyOK(cmd.ID, map[string]interface{}{
			"chat_id": jidStr,
			"jid":     jidStr,
		})
	}()
}

// handleCheckPhone resolves whether a phone number is on WhatsApp via
// client.IsOnWhatsApp. Accepts E.164 (`+90555…`) or bare digits — the underlying
// call handles either form.
func (h *helper) handleCheckPhone(cmd command) {
	var payload struct {
		PhoneNumber string `json:"phone_number"`
	}
	if err := json.Unmarshal(cmd.Payload, &payload); err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("invalid payload: %v", err))
		return
	}
	phone := strings.TrimSpace(payload.PhoneNumber)
	if phone == "" {
		h.replyError(cmd.ID, "phone_number is required")
		return
	}

	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil || !client.IsConnected() {
		h.replyError(cmd.ID, "not connected")
		return
	}

	go func() {
		ctx, cancel := context.WithTimeout(h.rootCtx, 15*time.Second)
		defer cancel()
		results, err := client.IsOnWhatsApp(ctx, []string{phone})
		if err != nil {
			h.replyError(cmd.ID, fmt.Sprintf("is_on_whatsapp: %v", err))
			return
		}
		out := map[string]interface{}{
			"phone":          phone,
			"is_on_whatsapp": false,
		}
		if len(results) > 0 {
			r := results[0]
			out["is_on_whatsapp"] = r.IsIn
			if r.IsIn {
				out["jid"] = r.JID.String()
			}
			if r.VerifiedName != nil {
				out["business"] = true
				if r.VerifiedName.Details != nil {
					if name := r.VerifiedName.Details.GetVerifiedName(); name != "" {
						out["verified_name"] = name
					}
				}
			}
		}
		h.replyOK(cmd.ID, out)
	}()
}

func (h *helper) handleSubscribePresence(cmd command) {
	var payload struct {
		JID string `json:"jid"`
	}
	if err := json.Unmarshal(cmd.Payload, &payload); err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("invalid payload: %v", err))
		return
	}
	if payload.JID == "" {
		h.replyError(cmd.ID, "jid is required")
		return
	}

	h.clientMu.Lock()
	client := h.client
	h.clientMu.Unlock()
	if client == nil || !client.IsConnected() {
		h.replyError(cmd.ID, "not connected")
		return
	}

	jid, err := types.ParseJID(payload.JID)
	if err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("invalid jid: %v", err))
		return
	}

	ctx, cancel := context.WithTimeout(h.rootCtx, 10*time.Second)
	defer cancel()

	// Whatsmeow requires us to broadcast our own presence as Available at
	// least once before the server starts streaming the contacts' presence
	// to us. SendPresence is idempotent so calling it on every subscribe
	// is fine.
	_ = client.SendPresence(ctx, types.PresenceAvailable)

	if err := client.SubscribePresence(ctx, jid); err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("subscribe_presence: %v", err))
		return
	}
	h.replyOK(cmd.ID, nil)
}

// findExistingMediaFile looks under sessionDir/media for any file whose stem
// matches the requested message ID. Returns the first match or "" if absent.
func (h *helper) findExistingMediaFile(id string) string {
	dir := filepath.Join(h.sessionDir, "media")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		stem := strings.TrimSuffix(name, filepath.Ext(name))
		if stem == id {
			return filepath.Join(dir, name)
		}
	}
	return ""
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
