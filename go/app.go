package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	appTypeChunk    = 0x01
	appTypePoll     = 0x02
	appTypeDone     = 0x03
	appTypeAck      = 0x81
	appTypeResp     = 0x82
	appTypeError    = 0x83
	appTypeMeta     = 0x84
	appFlagDone     = 0x01
	appFlagPending  = 0x02
	appFlagError    = 0x04
	msgIDSize       = 8
	headerChunkSize = 1 + msgIDSize + 4 + 4
	headerRespSize  = 1 + msgIDSize + 4 + 1
)

type AppServer struct {
	mu         sync.Mutex
	uploads    map[string]*UploadState
	responses  map[string]*ResponseState
	maxReqSize int
	maxTotal   int
	maxResp    int
	respChunk  int
	ttl        time.Duration
}

type UploadState struct {
	Total      int
	Chunks     map[uint32][]byte
	Updated    time.Time
	Done       bool
	Processing bool
}

type ResponseState struct {
	mu         sync.Mutex
	Buffer     []byte
	Done       bool
	ResponseID string
	ErrorMsg   string
	IsError    bool
	MetaSent   bool
}

type ChatRequest struct {
	APIKey             string `json:"api_key"`
	Model              string `json:"model"`
	Message            string `json:"message"`
	PreviousResponseID string `json:"previous_response_id"`
}

func NewAppServer(maxReqSize, maxRespSize int) *AppServer {
	respChunk := maxRespSize - headerRespSize
	if respChunk < 0 {
		respChunk = 0
	}
	return &AppServer{
		uploads:    make(map[string]*UploadState),
		responses:  make(map[string]*ResponseState),
		maxReqSize: maxReqSize,
		maxTotal:   maxReqSize * 128,
		maxResp:    maxRespSize,
		respChunk:  respChunk,
		ttl:        10 * time.Minute,
	}
}

func (a *AppServer) Handle(sessionID []byte, payload []byte) ([]byte, error) {
	if len(payload) < 1 {
		return nil, errors.New("empty payload")
	}
	switch payload[0] {
	case appTypeChunk:
		return a.handleChunk(sessionID, payload)
	case appTypePoll:
		return a.handlePoll(sessionID, payload)
	case appTypeDone:
		return a.handleDone(sessionID, payload)
	default:
		return a.errorResp(nil, "unknown message type"), nil
	}
}

func (a *AppServer) handleChunk(sessionID []byte, payload []byte) ([]byte, error) {
	if len(payload) < headerChunkSize {
		return a.errorResp(nil, "malformed chunk"), nil
	}
	msgID := payload[1 : 1+msgIDSize]
	offset := readU32(payload, 1+msgIDSize)
	total := readU32(payload, 1+msgIDSize+4)
	data := payload[headerChunkSize:]
	log.Printf("app: chunk msg=%s offset=%d len=%d total=%d", shortHex(msgID), offset, len(data), total)

	if int(total) > a.maxTotal {
		log.Printf("app: request too large total=%d max=%d", total, a.maxTotal)
		return a.errorResp(msgID, "request too large"), nil
	}
	if int(offset)+len(data) > int(total) {
		log.Printf("app: chunk out of range offset=%d len=%d total=%d", offset, len(data), total)
		return a.errorResp(msgID, "chunk out of range"), nil
	}

	key := a.scopedKey(sessionID, msgID)
	var completeData []byte
	startProcess := false

	a.mu.Lock()
	if _, exists := a.responses[key]; exists {
		a.mu.Unlock()
		return a.ackResp(msgID, offset), nil
	}
	state, ok := a.uploads[key]
	if !ok {
		state = &UploadState{Total: int(total), Chunks: make(map[uint32][]byte)}
		a.uploads[key] = state
	}
	if state.Done {
		a.mu.Unlock()
		return a.ackResp(msgID, offset), nil
	}
	if state.Total != int(total) {
		a.mu.Unlock()
		return a.errorResp(msgID, "total length mismatch"), nil
	}
	if _, exists := state.Chunks[offset]; !exists {
		state.Chunks[offset] = append([]byte{}, data...)
	}
	state.Updated = time.Now()

	if assembled, ok := assembleChunks(state); ok {
		completeData = assembled
		state.Done = true
		if !state.Processing {
			state.Processing = true
			startProcess = true
		}
	}
	a.mu.Unlock()

	if startProcess && completeData != nil {
		log.Printf("app: received full request total=%d", len(completeData))
		sidCopy := append([]byte{}, sessionID...)
		midCopy := append([]byte{}, msgID...)
		go a.processRequest(sidCopy, midCopy, completeData)
	}
	return a.ackResp(msgID, offset), nil
}

func (a *AppServer) handlePoll(sessionID []byte, payload []byte) ([]byte, error) {
	if len(payload) < 1+msgIDSize+4 {
		return a.errorResp(nil, "malformed poll"), nil
	}
	msgID := payload[1 : 1+msgIDSize]
	nextOffset := readU32(payload, 1+msgIDSize)

	a.cleanupExpired()
	a.mu.Lock()
	key := a.scopedKey(sessionID, msgID)
	resp := a.responses[key]
	upload := a.uploads[key]
	if resp == nil && upload != nil {
		if assembled, ok := assembleChunks(upload); ok {
			if !upload.Processing {
				upload.Done = true
				upload.Processing = true
				completeData := assembled
				sidCopy := append([]byte{}, sessionID...)
				midCopy := append([]byte{}, msgID...)
				a.mu.Unlock()
				go a.processRequest(sidCopy, midCopy, completeData)
				// Let the next poll find the response.
				return a.responseResp(msgID, nextOffset, nil, false, true, false), nil
			}
		} else if len(upload.Chunks) >= 2 {
			log.Printf("app: assemble failed total=%d %s", upload.Total, summarizeChunks(upload))
		}
	}
	a.mu.Unlock()
	if resp == nil {
		if upload != nil {
			log.Printf("app: poll pending msg=%s upload total=%d chunks=%d", shortHex(msgID), upload.Total, len(upload.Chunks))
		} else {
			log.Printf("app: poll unknown msg=%s (pending)", shortHex(msgID))
		}
		return a.responseResp(msgID, nextOffset, nil, false, true, false), nil
	}

	resp.mu.Lock()
	defer resp.mu.Unlock()

	if resp.ResponseID != "" && !resp.MetaSent {
		log.Printf("app: sending response_id=%s", resp.ResponseID)
		resp.MetaSent = true
		return a.metaResp(msgID, resp.ResponseID), nil
	}
	if int(nextOffset) < len(resp.Buffer) {
		log.Printf("app: sending chunk offset=%d total=%d done=%v", nextOffset, len(resp.Buffer), resp.Done)
		end := len(resp.Buffer)
		chunkMax := a.respChunk
		hardMax := a.maxResp - headerRespSize
		if hardMax < 0 {
			hardMax = 0
		}
		if chunkMax <= 0 || chunkMax > hardMax {
			chunkMax = hardMax
		}
		if chunkMax > 0 && int(nextOffset)+chunkMax < end {
			end = int(nextOffset) + chunkMax
		}
		data := resp.Buffer[int(nextOffset):end]
		done := resp.Done && end == len(resp.Buffer)
		return a.responseResp(msgID, nextOffset, data, done, false, resp.IsError), nil
	}
	if resp.Done {
		log.Printf("app: done with empty chunk offset=%d", nextOffset)
		return a.responseResp(msgID, nextOffset, nil, true, false, resp.IsError), nil
	}
	return a.responseResp(msgID, nextOffset, nil, false, true, false), nil
}

func (a *AppServer) handleDone(sessionID []byte, payload []byte) ([]byte, error) {
	if len(payload) < 1+msgIDSize {
		return a.errorResp(nil, "malformed done"), nil
	}
	msgID := payload[1 : 1+msgIDSize]
	key := a.scopedKey(sessionID, msgID)
	a.mu.Lock()
	delete(a.responses, key)
	delete(a.uploads, key)
	a.mu.Unlock()
	return a.ackResp(msgID, 0), nil
}

func (a *AppServer) processRequest(sessionID []byte, msgID []byte, data []byte) {
	var req ChatRequest
	if err := json.Unmarshal(data, &req); err != nil {
		log.Printf("app: invalid request json: %v", err)
		a.setResponseError(sessionID, msgID, "invalid request")
		return
	}
	if req.APIKey == "" || req.Message == "" {
		log.Printf("app: missing api_key or message")
		a.setResponseError(sessionID, msgID, "missing api_key or message")
		return
	}
	if req.Model == "" {
		req.Model = "gpt-4o-mini"
	}

	state := &ResponseState{}
	a.mu.Lock()
	a.responses[a.scopedKey(sessionID, msgID)] = state
	a.mu.Unlock()

	err := streamOpenAI(req, func(event StreamEvent) {
		state.mu.Lock()
		defer state.mu.Unlock()
		if event.ResponseID != "" && state.ResponseID == "" {
			state.ResponseID = event.ResponseID
		}
		if event.Delta != "" {
			state.Buffer = append(state.Buffer, []byte(event.Delta)...)
		}
		if event.Error != "" {
			state.ErrorMsg = event.Error
			state.Done = true
			state.IsError = true
			if len(state.Buffer) == 0 {
				state.Buffer = []byte(event.Error)
			}
		}
		if event.Done {
			state.Done = true
		}
	})
	if err != nil {
		log.Printf("openai stream error: %v", err)
		a.setResponseError(sessionID, msgID, err.Error())
	}
}

func (a *AppServer) setResponseError(sessionID []byte, msgID []byte, msg string) {
	a.mu.Lock()
	state := a.responses[a.scopedKey(sessionID, msgID)]
	a.mu.Unlock()
	if state == nil {
		state = &ResponseState{}
		a.mu.Lock()
		a.responses[a.scopedKey(sessionID, msgID)] = state
		a.mu.Unlock()
	}
	state.mu.Lock()
	state.ErrorMsg = msg
	state.Done = true
	state.IsError = true
	if len(state.Buffer) == 0 {
		state.Buffer = []byte(msg)
	}
	state.mu.Unlock()
}

func (a *AppServer) ackResp(msgID []byte, offset uint32) []byte {
	b := make([]byte, 1+msgIDSize+4)
	b[0] = appTypeAck
	copy(b[1:], msgID)
	writeU32(b, 1+msgIDSize, offset)
	return b
}

func (a *AppServer) responseResp(msgID []byte, offset uint32, data []byte, done bool, pending bool, isError bool) []byte {
	maxData := a.maxResp - headerRespSize
	if maxData < 0 {
		maxData = 0
	}
	if len(data) > maxData {
		data = data[:maxData]
	}
	b := make([]byte, 1+msgIDSize+4+1+len(data))
	b[0] = appTypeResp
	copy(b[1:], msgID)
	writeU32(b, 1+msgIDSize, offset)
	flags := byte(0)
	if done {
		flags |= appFlagDone
	}
	if pending {
		flags |= appFlagPending
	}
	if isError {
		flags |= appFlagError
	}
	b[1+msgIDSize+4] = flags
	copy(b[1+msgIDSize+4+1:], data)
	return b
}

func (a *AppServer) metaResp(msgID []byte, responseID string) []byte {
	idBytes := []byte(responseID)
	b := make([]byte, 1+msgIDSize+2+len(idBytes))
	b[0] = appTypeMeta
	copy(b[1:], msgID)
	writeU16(b, 1+msgIDSize, uint16(len(idBytes)))
	copy(b[1+msgIDSize+2:], idBytes)
	return b
}

func (a *AppServer) errorResp(msgID []byte, msg string) []byte {
	msgBytes := []byte(a.truncateError(msg))
	b := make([]byte, 1+msgIDSize+1+len(msgBytes))
	b[0] = appTypeError
	if msgID != nil {
		copy(b[1:], msgID)
	}
	b[1+msgIDSize] = 1
	copy(b[1+msgIDSize+1:], msgBytes)
	return b
}

func (a *AppServer) scopedKey(sessionID []byte, msgID []byte) string {
	b := make([]byte, 0, len(sessionID)+len(msgID))
	b = append(b, sessionID...)
	b = append(b, msgID...)
	return string(b)
}

func (a *AppServer) cleanupExpired() {
	now := time.Now()
	a.mu.Lock()
	for k, v := range a.uploads {
		if now.Sub(v.Updated) > a.ttl {
			delete(a.uploads, k)
		}
	}
	for k, v := range a.responses {
		if v.Done && v.MetaSent {
			delete(a.responses, k)
		}
	}
	a.mu.Unlock()
}

func (a *AppServer) truncateError(msg string) string {
	maxLen := a.maxResp - (1 + msgIDSize + 1)
	if maxLen < 0 {
		maxLen = 0
	}
	if len(msg) <= maxLen {
		return msg
	}
	if maxLen <= 3 {
		return msg[:maxLen]
	}
	return msg[:maxLen-3] + "..."
}

func assembleChunks(state *UploadState) ([]byte, bool) {
	if len(state.Chunks) == 0 {
		return nil, false
	}
	keys := make([]int, 0, len(state.Chunks))
	for k := range state.Chunks {
		keys = append(keys, int(k))
	}
	sort.Ints(keys)

	buf := make([]byte, state.Total)
	offset := 0
	for _, key := range keys {
		if key != offset {
			return nil, false
		}
		chunk := state.Chunks[uint32(key)]
		copy(buf[offset:], chunk)
		offset += len(chunk)
		if offset > state.Total {
			return nil, false
		}
	}
	if offset != state.Total {
		return nil, false
	}
	return buf, true
}

func summarizeChunks(state *UploadState) string {
	keys := make([]int, 0, len(state.Chunks))
	for k := range state.Chunks {
		keys = append(keys, int(k))
	}
	sort.Ints(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%d:%d", k, len(state.Chunks[uint32(k)])))
	}
	return "chunks=[" + strings.Join(parts, ",") + "]"
}

func readU32(data []byte, offset int) uint32 {
	return uint32(data[offset])<<24 | uint32(data[offset+1])<<16 | uint32(data[offset+2])<<8 | uint32(data[offset+3])
}

func writeU32(data []byte, offset int, value uint32) {
	data[offset] = byte(value >> 24)
	data[offset+1] = byte(value >> 16)
	data[offset+2] = byte(value >> 8)
	data[offset+3] = byte(value)
}

func writeU16(data []byte, offset int, value uint16) {
	data[offset] = byte(value >> 8)
	data[offset+1] = byte(value)
}
