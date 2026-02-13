package main

import (
	"bufio"
	"bytes"
	"crypto/subtle"
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

type toolConfig struct {
	password string
}

func streamOpenAI(req ChatRequest, toolPass string, onEvent func(StreamEvent)) error {
	cfg := toolConfig{password: toolPass}
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
	if toolPass != "" {
		tools = append(tools, map[string]any{
			"type":        "function",
			"name":        "fetch_url",
			"description": "Fetch the contents of a URL. Do not call this tool until the user tells you what password to pass in. You may reuse a previously provided password in the conversation.",
			"parameters": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"url": map[string]any{
						"type":        "string",
						"description": "The URL to fetch (http or https).",
					},
					"password": map[string]any{
						"type":        "string",
						"description": "Password provided by the user.",
					},
				},
				"required":             []string{"url", "password"},
				"additionalProperties": false,
			},
			"function": map[string]any{
				"name":        "fetch_url",
				"description": "Fetch the contents of a URL. Do not call this tool until the user tells you what password to pass in. You may reuse a previously provided password in the conversation.",
				"parameters": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"url": map[string]any{
							"type":        "string",
							"description": "The URL to fetch (http or https).",
						},
						"password": map[string]any{
							"type":        "string",
							"description": "Password provided by the user.",
						},
					},
					"required":             []string{"url", "password"},
					"additionalProperties": false,
				},
			},
		})
	}
	prevID := req.PreviousResponseID
	for {
		streamBody, err := createResponse(req, tools, true, nil, prevID)
		if err != nil {
			return err
		}
		result, err := streamResponseOnce(req, tools, streamBody, onEvent)
		if err != nil {
			return err
		}
		if result.Error != "" {
			onEvent(StreamEvent{Error: result.Error})
			return nil
		}
		if len(result.ToolCalls) == 0 {
			if result.ResponseID != "" {
				onEvent(StreamEvent{ResponseID: result.ResponseID})
			}
			onEvent(StreamEvent{Done: true})
			return nil
		}
		if result.ResponseID == "" {
			return errors.New("openai response missing id for tool call")
		}
		input := make([]any, 0, len(result.ToolCalls))
		for _, call := range result.ToolCalls {
			log.Printf("openai: tool call name=%s call_id=%s", call.Name, call.CallID)
			output, err := executeTool(call.Name, call.Arguments, cfg)
			if err != nil {
				onEvent(StreamEvent{Error: err.Error()})
				return nil
			}
			log.Printf("openai: tool output ready name=%s", call.Name)
			input = append(input, map[string]any{
				"type":    "function_call_output",
				"call_id": call.CallID,
				"output":  output,
			})
		}
		log.Printf("openai: streaming tool response")
		prevID = result.ResponseID
		req.PreviousResponseID = prevID
		toolBody, err := createResponse(req, tools, true, input, prevID)
		if err != nil {
			return err
		}
		result, err = streamResponseOnce(req, tools, toolBody, onEvent)
		if err != nil {
			return err
		}
		if result.Error != "" {
			onEvent(StreamEvent{Error: result.Error})
			return nil
		}
		if len(result.ToolCalls) == 0 {
			if result.ResponseID != "" {
				onEvent(StreamEvent{ResponseID: result.ResponseID})
			}
			onEvent(StreamEvent{Done: true})
			return nil
		}
		prevID = result.ResponseID
		req.PreviousResponseID = prevID
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

type toolCall struct {
	CallID    string
	Name      string
	Arguments string
}

type streamResult struct {
	ResponseID string
	ToolCalls  []toolCall
	Error      string
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

func executeTool(name string, args string, cfg toolConfig) (string, error) {
	switch name {
	case "get_time_gmt":
		now := time.Now().UTC().Format(time.RFC3339)
		payload := map[string]string{"utc": now}
		data, err := json.Marshal(payload)
		if err != nil {
			return "", err
		}
		return string(data), nil
	case "fetch_url":
		payload := map[string]any{}
		if cfg.password == "" {
			payload["error"] = "fetch_url tool disabled"
			data, _ := json.Marshal(payload)
			return string(data), nil
		}
		var req struct {
			URL      string `json:"url"`
			Password string `json:"password"`
		}
		if err := json.Unmarshal([]byte(args), &req); err != nil {
			payload["error"] = "invalid arguments for fetch_url"
			data, _ := json.Marshal(payload)
			return string(data), nil
		}
		if subtle.ConstantTimeCompare([]byte(req.Password), []byte(cfg.password)) != 1 {
			payload["error"] = "invalid password"
			data, _ := json.Marshal(payload)
			return string(data), nil
		}
		if !strings.HasPrefix(req.URL, "http://") && !strings.HasPrefix(req.URL, "https://") {
			payload["error"] = "unsupported URL scheme"
			data, _ := json.Marshal(payload)
			return string(data), nil
		}
		client := &http.Client{Timeout: 10 * time.Second}
		resp, err := client.Get(req.URL)
		if err != nil {
			payload["error"] = err.Error()
			data, _ := json.Marshal(payload)
			return string(data), nil
		}
		defer resp.Body.Close()
		const maxBytes = 64 * 1024
		limited := io.LimitReader(resp.Body, maxBytes)
		body, err := io.ReadAll(limited)
		if err != nil {
			payload["error"] = err.Error()
			data, _ := json.Marshal(payload)
			return string(data), nil
		}
		payload["status"] = resp.Status
		payload["content_type"] = resp.Header.Get("Content-Type")
		payload["body"] = string(body)
		data, _ := json.Marshal(payload)
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

func streamResponseOnce(req ChatRequest, tools []map[string]any, body []byte, onEvent func(StreamEvent)) (streamResult, error) {
	client := &http.Client{Timeout: 0 * time.Second}
	resp, err := doOpenAIRequest(client, req.APIKey, body, req.PreviousResponseID != "")
	if err != nil {
		return streamResult{}, err
	}
	defer resp.Body.Close()

	reader := bufio.NewReader(resp.Body)
	var dataLines []string
	result := streamResult{}
	callOrder := []string{}
	callMap := map[string]*toolCall{}

	handleEvent := func(obj map[string]any) bool {
		if id := extractResponseID(obj); id != "" {
			result.ResponseID = id
		}
		typeVal, _ := obj["type"].(string)
		switch typeVal {
		case "response.created":
			log.Printf("openai: response created")
		case "response.output_text.delta":
			delta := extractDelta(obj)
			if delta != "" {
				onEvent(StreamEvent{Delta: delta})
			}
		case "response.output_text.done":
			// wait for response.completed
		case "response.output_item.added", "response.output_item.delta":
			item, ok := obj["item"].(map[string]any)
			if !ok {
				return false
			}
			if itemType, _ := item["type"].(string); itemType != "function_call" {
				return false
			}
			callID, _ := item["call_id"].(string)
			if callID == "" {
				return false
			}
			call := callMap[callID]
			if call == nil {
				call = &toolCall{CallID: callID}
				callMap[callID] = call
				callOrder = append(callOrder, callID)
			}
			if name, _ := item["name"].(string); name != "" {
				call.Name = name
			}
			if args, _ := item["arguments"].(string); args != "" {
				call.Arguments = args
			}
		case "response.function_call_arguments.delta":
			callID, _ := obj["call_id"].(string)
			delta := extractDelta(obj)
			if callID != "" && delta != "" {
				call := callMap[callID]
				if call == nil {
					call = &toolCall{CallID: callID}
					callMap[callID] = call
					callOrder = append(callOrder, callID)
				}
				call.Arguments += delta
			}
		case "response.completed":
			if id := extractResponseID(obj); id != "" {
				log.Printf("openai: response completed id=%s", id)
			} else {
				log.Printf("openai: response completed without id data=%s", truncateLog(stringify(obj), 500))
			}
			return true
		case "response.failed", "error":
			errMsg := extractError(obj)
			if errMsg == "" {
				errMsg = "openai error"
			}
			log.Printf("openai: error=%s", errMsg)
			result.Error = errMsg
			return true
		}
		return false
	}

	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return result, err
		}
		line = strings.TrimSpace(line)
		if line == "" {
			if len(dataLines) > 0 {
				data := strings.Join(dataLines, "\n")
				dataLines = dataLines[:0]
				if data == "[DONE]" {
					break
				}
				var obj map[string]any
				if err := json.Unmarshal([]byte(data), &obj); err == nil {
					if handleEvent(obj) {
						break
					}
				}
			}
			continue
		}
		if strings.HasPrefix(line, "data:") {
			dataLines = append(dataLines, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		}
	}

	for _, id := range callOrder {
		call := callMap[id]
		if call == nil || call.Name == "" {
			continue
		}
		result.ToolCalls = append(result.ToolCalls, *call)
	}
	return result, nil
}

func stringify(obj map[string]any) string {
	data, err := json.Marshal(obj)
	if err != nil {
		return ""
	}
	return string(data)
}
