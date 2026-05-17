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
// NOTE: This file uses a thin stub interface around the upstream `whatsmeow`
// library so the helper compiles even before the dependency graph is fetched.
// The first `go mod tidy` will replace the stub with the real client. The
// helper deliberately exposes ONLY the surface area documented in CLAUDE.md.
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
	"sync"
	"syscall"
	"time"
)

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
	out        *json.Encoder
	outLock    sync.Mutex
	stopCtx    context.Context
	stop       context.CancelFunc
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
		stopCtx:    ctx,
		stop:       cancel,
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		h.emit(event{Type: "disconnected", Payload: map[string]interface{}{"reason": "signal"}})
		cancel()
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
}

func (h *helper) dispatch(cmd command) {
	switch cmd.Type {
	case "connect":
		h.handleConnect(cmd)
	case "disconnect":
		h.replyOK(cmd.ID, nil)
		h.stop()
	case "send_message":
		h.handleSendMessage(cmd)
	case "fetch_history":
		h.replyOK(cmd.ID, nil)
	case "download_media":
		h.handleDownloadMedia(cmd)
	case "mark_read":
		h.replyOK(cmd.ID, nil)
	default:
		h.replyError(cmd.ID, fmt.Sprintf("unknown command: %s", cmd.Type))
	}
}

// handleConnect simulates the QR + pairing handshake until the real whatsmeow
// dependency is wired in. Replace `simulate=true` once `go mod tidy` succeeds.
func (h *helper) handleConnect(cmd command) {
	h.replyOK(cmd.ID, nil)
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		// emit one QR right away so the UI can render something
		h.emit(event{
			Type: "qr",
			Payload: map[string]interface{}{
				"code": fmt.Sprintf("multiversewp:stub:%s:%d", h.accountID, time.Now().Unix()),
			},
		})
		select {
		case <-h.stopCtx.Done():
			return
		case <-ticker.C:
			h.emit(event{
				Type: "qr",
				Payload: map[string]interface{}{
					"code": fmt.Sprintf("multiversewp:stub:%s:%d", h.accountID, time.Now().Unix()),
				},
			})
		}
	}()
}

func (h *helper) handleSendMessage(cmd command) {
	var payload struct {
		ChatJID string `json:"chat_jid"`
		Text    string `json:"text"`
	}
	if err := json.Unmarshal(cmd.Payload, &payload); err != nil {
		h.replyError(cmd.ID, fmt.Sprintf("invalid payload: %v", err))
		return
	}
	if payload.ChatJID == "" {
		h.replyError(cmd.ID, "chat_jid is required")
		return
	}
	id := fmt.Sprintf("local-%d", time.Now().UnixNano())
	h.replyOK(cmd.ID, map[string]interface{}{"message_id": id})
	h.emit(event{
		Type: "delivery",
		Payload: map[string]interface{}{
			"message_id": id,
			"status":     "sent",
		},
	})
}

func (h *helper) handleDownloadMedia(cmd command) {
	var payload struct {
		MessageID string `json:"message_id"`
	}
	_ = json.Unmarshal(cmd.Payload, &payload)
	path := fmt.Sprintf("%s/media/%s", h.sessionDir, payload.MessageID)
	h.replyOK(cmd.ID, map[string]interface{}{"local_path": path})
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
