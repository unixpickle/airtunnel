package main

import (
	"encoding/json"
	"errors"
	"log"
	"sort"
	"sync"
	"time"
)

const (
	appTypeChunk    = 0x01
	appTypePoll     = 0x02
	appTypeAck      = 0x81
	appTypeResp     = 0x82
	appTypeError    = 0x83
	appTypeMeta     = 0x84
	appFlagDone     = 0x01
	appFlagPending  = 0x02
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
}

type UploadState struct {
	Total   int
	Chunks  map[uint32][]byte
	Updated time.Time
}

type ResponseState struct {
	mu         sync.Mutex
	Buffer     []byte
	Done       bool
	ResponseID string
	ErrorMsg   string
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
	}
}

func (a *AppServer) Handle(payload []byte) ([]byte, error) {
	if len(payload) < 1 {
		return nil, errors.New("empty payload")
	}
	switch payload[0] {
	case appTypeChunk:
		return a.handleChunk(payload)
	case appTypePoll:
		return a.handlePoll(payload)
	default:
		return a.errorResp(nil, "unknown message type"), nil
	}
}

func (a *AppServer) handleChunk(payload []byte) ([]byte, error) {
	if len(payload) < headerChunkSize {
		return a.errorResp(nil, "malformed chunk"), nil
	}
	msgID := payload[1 : 1+msgIDSize]
	offset := readU32(payload, 1+msgIDSize)
	total := readU32(payload, 1+msgIDSize+4)
	data := payload[headerChunkSize:]

	if int(total) > a.maxTotal {
		return a.errorResp(msgID, "request too large"), nil
	}
	if int(offset)+len(data) > int(total) {
		return a.errorResp(msgID, "chunk out of range"), nil
	}

	key := string(msgID)
	var completeData []byte

	a.mu.Lock()
	state, ok := a.uploads[key]
	if !ok {
		state = &UploadState{Total: int(total), Chunks: make(map[uint32][]byte)}
		a.uploads[key] = state
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
		delete(a.uploads, key)
	}
	a.mu.Unlock()

	if completeData != nil {
		go a.processRequest(msgID, completeData)
	}
	return a.ackResp(msgID, offset), nil
}

func (a *AppServer) handlePoll(payload []byte) ([]byte, error) {
	if len(payload) < 1+msgIDSize+4 {
		return a.errorResp(nil, "malformed poll"), nil
	}
	msgID := payload[1 : 1+msgIDSize]
	nextOffset := readU32(payload, 1+msgIDSize)

	a.mu.Lock()
	resp := a.responses[string(msgID)]
	a.mu.Unlock()
	if resp == nil {
		return a.errorResp(msgID, "unknown message id"), nil
	}

	resp.mu.Lock()
	defer resp.mu.Unlock()

	if resp.ResponseID != "" && !resp.MetaSent {
		resp.MetaSent = true
		return a.metaResp(msgID, resp.ResponseID), nil
	}
	if resp.ErrorMsg != "" {
		return a.errorResp(msgID, resp.ErrorMsg), nil
	}

	if int(nextOffset) < len(resp.Buffer) {
		end := len(resp.Buffer)
		if a.respChunk > 0 && int(nextOffset)+a.respChunk < end {
			end = int(nextOffset) + a.respChunk
		}
		data := resp.Buffer[int(nextOffset):end]
		done := resp.Done && end == len(resp.Buffer)
		return a.responseResp(msgID, nextOffset, data, done, false), nil
	}
	if resp.Done {
		return a.responseResp(msgID, nextOffset, nil, true, false), nil
	}
	return a.responseResp(msgID, nextOffset, nil, false, true), nil
}

func (a *AppServer) processRequest(msgID []byte, data []byte) {
	var req ChatRequest
	if err := json.Unmarshal(data, &req); err != nil {
		a.setResponseError(msgID, "invalid request")
		return
	}
	if req.APIKey == "" || req.Message == "" {
		a.setResponseError(msgID, "missing api_key or message")
		return
	}
	if req.Model == "" {
		req.Model = "gpt-4o-mini"
	}

	state := &ResponseState{}
	a.mu.Lock()
	a.responses[string(msgID)] = state
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
		}
		if event.Done {
			state.Done = true
		}
	})
	if err != nil {
		log.Printf("openai stream error: %v", err)
		a.setResponseError(msgID, err.Error())
	}
}

func (a *AppServer) setResponseError(msgID []byte, msg string) {
	a.mu.Lock()
	state := a.responses[string(msgID)]
	a.mu.Unlock()
	if state == nil {
		state = &ResponseState{}
		a.mu.Lock()
		a.responses[string(msgID)] = state
		a.mu.Unlock()
	}
	state.mu.Lock()
	state.ErrorMsg = msg
	state.Done = true
	state.mu.Unlock()
}

func (a *AppServer) ackResp(msgID []byte, offset uint32) []byte {
	b := make([]byte, 1+msgIDSize+4)
	b[0] = appTypeAck
	copy(b[1:], msgID)
	writeU32(b, 1+msgIDSize, offset)
	return b
}

func (a *AppServer) responseResp(msgID []byte, offset uint32, data []byte, done bool, pending bool) []byte {
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
	msgBytes := []byte(msg)
	b := make([]byte, 1+msgIDSize+1+len(msgBytes))
	b[0] = appTypeError
	if msgID != nil {
		copy(b[1:], msgID)
	}
	b[1+msgIDSize] = 1
	copy(b[1+msgIDSize+1:], msgBytes)
	return b
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
