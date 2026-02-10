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
	body := map[string]any{
		"model": req.Model,
		"input": []map[string]any{
			{
				"role":    "user",
				"content": req.Message,
			},
		},
		"stream": true,
		"store":  true,
	}
	if req.PreviousResponseID != "" {
		body["previous_response_id"] = req.PreviousResponseID
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}

	client := &http.Client{Timeout: 0 * time.Second}
	resp, err := doOpenAIRequest(client, req.APIKey, buf, req.PreviousResponseID != "")
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
					if err := handleSSEData(dataLines, onEvent); err != nil {
						if errors.Is(err, io.EOF) {
							return nil
						}
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
