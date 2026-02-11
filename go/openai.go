package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

type StreamEvent struct {
	ResponseID string
	Delta      string
	Done       bool
	Error      string
}

func streamOpenAI(req ChatRequest, onEvent func(StreamEvent)) error {
	tools := []map[string]any{
		{
			"type":        "function",
			"name":        "get_time_gmt",
			"description": "Get the current time in GMT/UTC.",
			"parameters": map[string]any{
				"type":                 "object",
				"properties":           map[string]any{},
				"additionalProperties": false,
			},
			"function": map[string]any{
				"name":        "get_time_gmt",
				"description": "Get the current time in GMT/UTC.",
				"parameters": map[string]any{
					"type":                 "object",
					"properties":           map[string]any{},
					"additionalProperties": false,
				},
			},
		},
	}
	client := &http.Client{Timeout: 0 * time.Second}
	initialBody, err := createResponse(req, tools, false, nil, req.PreviousResponseID)
	if err != nil {
		return err
	}
	respBytes, err := doOpenAIRequestBytes(client, req.APIKey, initialBody, req.PreviousResponseID != "")
	if err != nil {
		return err
	}
	var respObj map[string]any
	if err := json.Unmarshal(respBytes, &respObj); err != nil {
		return err
	}
	var responseID string
	if id, ok := respObj["id"].(string); ok && id != "" {
		responseID = id
		onEvent(StreamEvent{ResponseID: id})
	}
	outputItems, _ := respObj["output"].([]any)
	if call := extractToolCallFromOutput(outputItems); call != nil {
		output, err := executeTool(call.Name, call.Arguments)
		if err != nil {
			onEvent(StreamEvent{Error: err.Error()})
			return nil
		}
		input := []any{
			map[string]any{
				"type":    "function_call_output",
				"call_id": call.CallID,
				"output":  output,
			},
		}
		secondBody, err := createResponse(req, tools, true, input, responseID)
		if err != nil {
			return err
		}
		return streamResponse(req, tools, secondBody, onEvent)
	}
	if text, ok := respObj["output_text"].(string); ok && text != "" {
		onEvent(StreamEvent{Delta: text})
		onEvent(StreamEvent{Done: true})
		return nil
	}
	streamBody, err := createResponse(req, tools, true, nil, req.PreviousResponseID)
	if err != nil {
		return err
	}
	return streamResponse(req, tools, streamBody, onEvent)
}

func doOpenAIRequest(client *http.Client, apiKey string, body []byte, hadPrev bool) (*http.Response, error) {
	for attempt := 0; attempt < 2; attempt++ {
		httpReq, err := http.NewRequest("POST", "https://api.openai.com/v1/responses", bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		httpReq.Header.Set("Authorization", "Bearer "+apiKey)
		httpReq.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(httpReq)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return resp, nil
		}
		data, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if hadPrev && attempt == 0 && isPrevResponseNotFound(data) {
			log.Printf("openai: previous_response_id not found, retrying")
			time.Sleep(750 * time.Millisecond)
			continue
		}
		return nil, errors.New(string(data))
	}
	return nil, errors.New("openai request failed")
}

func isPrevResponseNotFound(data []byte) bool {
	var obj struct {
		Error struct {
			Code string `json:"code"`
			Type string `json:"type"`
		} `json:"error"`
	}
	if err := json.Unmarshal(data, &obj); err != nil {
		return false
	}
	return obj.Error.Code == "previous_response_not_found" || obj.Error.Type == "previous_response_not_found"
}

type toolCall struct {
	ResponseID string
	CallID     string
	Name       string
	Arguments  string
}

func handleSSEData(lines []string, onEvent func(StreamEvent)) error {
	data := strings.Join(lines, "\n")
	if data == "[DONE]" {
		onEvent(StreamEvent{Done: true})
		return io.EOF
	}
	var obj map[string]any
	if err := json.Unmarshal([]byte(data), &obj); err != nil {
		return nil
	}
	typeVal, _ := obj["type"].(string)
	// Capture any response_id present on any event type.
	if id := extractResponseID(obj); id != "" {
		onEvent(StreamEvent{ResponseID: id})
	}
	switch typeVal {
	case "response.created":
		log.Printf("openai: response created")
	case "response.output_text.delta":
		delta := extractDelta(obj)
		if delta != "" {
			log.Printf("openai: delta len=%d", len(delta))
			onEvent(StreamEvent{Delta: delta})
		}
	case "response.output_text.done":
		// Do not end the stream here; wait for response.completed or [DONE].
		log.Printf("openai: output_text done")
	case "response.completed":
		if id := extractResponseID(obj); id != "" {
			log.Printf("openai: response completed id=%s", id)
		} else {
			log.Printf("openai: response completed without id data=%s", truncateLog(data, 500))
		}
		onEvent(StreamEvent{Done: true})
		return io.EOF
	case "response.failed", "error":
		errMsg := extractError(obj)
		if errMsg == "" {
			errMsg = "openai error"
		}
		log.Printf("openai: error=%s", errMsg)
		onEvent(StreamEvent{Error: errMsg})
		return io.EOF
	}
	return nil
}

func truncateLog(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}

func extractResponseID(obj map[string]any) string {
	if id, ok := obj["response_id"].(string); ok {
		return id
	}
	if resp, ok := obj["response"].(map[string]any); ok {
		if id, ok := resp["id"].(string); ok {
			return id
		}
	}
	return ""
}

func extractDelta(obj map[string]any) string {
	if delta, ok := obj["delta"].(string); ok {
		return delta
	}
	if text, ok := obj["text"].(string); ok {
		return text
	}
	return ""
}

func extractError(obj map[string]any) string {
	if errObj, ok := obj["error"].(map[string]any); ok {
		if msg, ok := errObj["message"].(string); ok {
			return msg
		}
	}
	return ""
}

func extractToolCall(obj map[string]any) *toolCall {
	item, ok := obj["item"].(map[string]any)
	if !ok {
		return nil
	}
	if itemType, _ := item["type"].(string); itemType != "function_call" {
		return nil
	}
	callID, _ := item["call_id"].(string)
	name, _ := item["name"].(string)
	args, _ := item["arguments"].(string)
	if callID == "" || name == "" {
		return nil
	}
	return &toolCall{
		ResponseID: extractResponseID(obj),
		CallID:     callID,
		Name:       name,
		Arguments:  args,
	}
}

func executeTool(name string, _ string) (string, error) {
	switch name {
	case "get_time_gmt":
		now := time.Now().UTC().Format(time.RFC3339)
		payload := map[string]string{"utc": now}
		data, err := json.Marshal(payload)
		if err != nil {
			return "", err
		}
		return string(data), nil
	default:
		return "", errors.New("unknown tool: " + name)
	}
}

func createResponse(req ChatRequest, tools []map[string]any, stream bool, input []any, prevID string) ([]byte, error) {
	body := map[string]any{
		"model":  req.Model,
		"stream": stream,
		"store":  true,
		"tools":  tools,
	}
	if input != nil {
		body["input"] = input
	} else {
		body["input"] = []map[string]any{
			{
				"role":    "user",
				"content": req.Message,
			},
		}
	}
	if prevID != "" {
		body["previous_response_id"] = prevID
	}
	return json.Marshal(body)
}

func doOpenAIRequestBytes(client *http.Client, apiKey string, body []byte, hadPrev bool) ([]byte, error) {
	resp, err := doOpenAIRequest(client, apiKey, body, hadPrev)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}

func streamResponse(req ChatRequest, tools []map[string]any, body []byte, onEvent func(StreamEvent)) error {
	client := &http.Client{Timeout: 0 * time.Second}
	resp, err := doOpenAIRequest(client, req.APIKey, body, req.PreviousResponseID != "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	reader := bufio.NewReader(resp.Body)
	var dataLines []string
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if errors.Is(err, io.EOF) {
				if len(dataLines) > 0 {
					if err := handleSSEData(dataLines, onEvent); err != nil && !errors.Is(err, io.EOF) {
						return err
					}
				}
				return nil
			}
			return err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			if len(dataLines) > 0 {
				if err := handleSSEData(dataLines, onEvent); err != nil {
					if errors.Is(err, io.EOF) {
						return nil
					}
					return err
				}
				dataLines = dataLines[:0]
			}
			continue
		}
		if strings.HasPrefix(line, "data:") {
			dataLines = append(dataLines, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		}
	}
}

func extractToolCallFromOutput(items []any) *toolCall {
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if typ, _ := obj["type"].(string); typ != "function_call" {
			continue
		}
		callID, _ := obj["call_id"].(string)
		name, _ := obj["name"].(string)
		args, _ := obj["arguments"].(string)
		if callID == "" || name == "" {
			continue
		}
		return &toolCall{CallID: callID, Name: name, Arguments: args}
	}
	return nil
}
