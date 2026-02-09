package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
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
	body := map[string]any{
		"model": req.Model,
		"input": []map[string]any{
			{
				"role":    "user",
				"content": req.Message,
			},
		},
		"stream": true,
	}
	if req.PreviousResponseID != "" {
		body["previous_response_id"] = req.PreviousResponseID
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}

	httpReq, err := http.NewRequest("POST", "https://api.openai.com/v1/responses", bytes.NewReader(buf))
	if err != nil {
		return err
	}
	httpReq.Header.Set("Authorization", "Bearer "+req.APIKey)
	httpReq.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 0 * time.Second}
	resp, err := client.Do(httpReq)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(resp.Body)
		return errors.New(string(data))
	}

	reader := bufio.NewReader(resp.Body)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			onEvent(StreamEvent{Done: true})
			return nil
		}
		var obj map[string]any
		if err := json.Unmarshal([]byte(data), &obj); err != nil {
			continue
		}
		typeVal, _ := obj["type"].(string)
		switch typeVal {
		case "response.created":
			id := extractResponseID(obj)
			if id != "" {
				onEvent(StreamEvent{ResponseID: id})
			}
		case "response.output_text.delta":
			delta := extractDelta(obj)
			if delta != "" {
				onEvent(StreamEvent{Delta: delta})
			}
		case "response.completed", "response.output_text.done":
			id := extractResponseID(obj)
			if id != "" {
				onEvent(StreamEvent{ResponseID: id})
			}
			onEvent(StreamEvent{Done: true})
			return nil
		case "response.failed", "error":
			errMsg := extractError(obj)
			if errMsg == "" {
				errMsg = "openai error"
			}
			onEvent(StreamEvent{Error: errMsg})
			return nil
		}
	}
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
