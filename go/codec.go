package main

import (
	"encoding/base32"
	"strings"

	"github.com/miekg/dns"
)

var base32Encoding = base32.NewEncoding("abcdefghijklmnopqrstuvwxyz234567").WithPadding(base32.NoPadding)

func encodeBase32(data []byte) string {
	return base32Encoding.EncodeToString(data)
}

func decodeBase32(s string) ([]byte, error) {
	s = strings.ToLower(s)
	return base32Encoding.DecodeString(s)
}

func maxEncodedChars(root string) int {
	root = strings.TrimSuffix(root, ".")
	if root == "" {
		return 0
	}
	rootLen := len(root)
	maxTotal := 253
	best := 0
	for n := 0; n <= maxTotal; n++ {
		labels := (n + 62) / 63
		dots := 0
		if labels > 1 {
			dots = labels - 1
		}
		total := n + dots + 1 + rootLen
		if total <= maxTotal {
			best = n
		}
	}
	return best
}

func maxBytesForChars(maxChars int) int {
	max := 0
	for b := 0; b <= 2048; b++ {
		enc := (b*8 + 4) / 5
		if enc <= maxChars {
			max = b
		}
	}
	return max
}

func maxRequestSize(root string) int {
	return maxBytesForChars(maxEncodedChars(root))
}

func maxResponseSize() int {
	return maxBytesForChars(255)
}

func decodeQuestion(root string, q dns.Question) ([]byte, bool) {
	name := strings.ToLower(q.Name)
	root = strings.ToLower(root)
	if !strings.HasSuffix(name, root) {
		return nil, false
	}

	prefix := strings.TrimSuffix(name, root)
	prefix = strings.TrimSuffix(prefix, ".")
	if prefix == "" {
		return []byte{}, true
	}

	labels := strings.Split(prefix, ".")
	var b strings.Builder
	for _, label := range labels {
		if label == "" {
			return nil, false
		}
		b.WriteString(label)
	}

	payload, err := decodeBase32(b.String())
	if err != nil {
		return nil, false
	}
	return payload, true
}
