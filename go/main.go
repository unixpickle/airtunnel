package main

import (
	"crypto/ed25519"
	"flag"
	"log"
	"strings"

	"github.com/miekg/dns"
)

const (
	protoVersion      = 1
	handshakeRequest  = 1
	handshakeResponse = 2
	sessionIDSize     = 8
	nonceSize         = 12
	keySize           = 32
	signatureSize     = 64
)

type Handler func([]byte) ([]byte, error)

func main() {
	var root string
	var addr string
	var keyPath string
	flag.StringVar(&root, "root", "", "root domain (e.g. someserver.google.com)")
	flag.StringVar(&addr, "addr", ":5353", "listen address")
	flag.StringVar(&keyPath, "key", "", "ed25519 private key PEM")
	flag.Parse()

	if strings.TrimSpace(root) == "" {
		log.Fatal("-root is required")
	}
	if strings.TrimSpace(keyPath) == "" {
		log.Fatal("-key is required")
	}

	priv, err := loadEd25519PrivateKey(keyPath)
	if err != nil {
		log.Fatalf("load key: %v", err)
	}

	root = dns.Fqdn(root)
	maxReq := maxRequestSize(root)
	maxResp := maxResponseSize()
	log.Printf("root=%s max_request_bytes=%d max_response_bytes=%d", root, maxReq, maxResp)
	maxPlainReq := maxReq - (sessionIDSize + nonceSize + 16)
	maxPlainResp := maxResp - (sessionIDSize + nonceSize + 16)
	if maxPlainReq < 0 {
		maxPlainReq = 0
	}
	if maxPlainResp < 0 {
		maxPlainResp = 0
	}
	log.Printf("max_plaintext_request_bytes=%d", maxPlainReq)
	log.Printf("max_plaintext_response_bytes=%d", maxPlainResp)
	log.Printf("max_request_total_bytes=%d", maxPlainReq*128)
	log.Printf("app_response_chunk_bytes=%d", maxPlainResp-(1+msgIDSize+4+1))

	sessions := NewSessionStore()
	app := NewAppServer(maxPlainReq, maxPlainResp)
	server := &dns.Server{Addr: addr, Net: "udp"}
	server.Handler = dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		handleRequest(w, r, root, priv, sessions, app, maxReq, maxResp)
	})

	log.Printf("listening on %s", addr)
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func handleRequest(w dns.ResponseWriter, r *dns.Msg, root string, priv ed25519.PrivateKey, sessions *SessionStore, app *AppServer, maxReq, maxResp int) {
	m := new(dns.Msg)
	m.SetReply(r)
	m.Authoritative = true

	if len(r.Question) == 0 {
		log.Printf("dns: no question from %s", w.RemoteAddr())
		m.Rcode = dns.RcodeFormatError
		_ = w.WriteMsg(m)
		return
	}

	q := r.Question[0]
	log.Printf("dns: query name=%s type=%d class=%d from=%s", q.Name, q.Qtype, q.Qclass, w.RemoteAddr())
	payload, ok := decodeQuestion(root, q)
	if !ok {
		log.Printf("dns: name not under root or decode failed name=%s root=%s", q.Name, root)
		m.Rcode = dns.RcodeNameError
		_ = w.WriteMsg(m)
		return
	}
	if len(payload) > maxReq {
		log.Printf("dns: payload too large len=%d max=%d", len(payload), maxReq)
		m.Rcode = dns.RcodeFormatError
		_ = w.WriteMsg(m)
		return
	}

	respPayload, ok := processPayload(payload, priv, sessions, app)
	if !ok {
		log.Printf("dns: app processing failed len=%d", len(payload))
		m.Rcode = dns.RcodeServerFailure
		_ = w.WriteMsg(m)
		return
	}
	if len(respPayload) > maxResp {
		log.Printf("dns: response too large len=%d max=%d", len(respPayload), maxResp)
		m.Rcode = dns.RcodeServerFailure
		_ = w.WriteMsg(m)
		return
	}

	txt := &dns.TXT{
		Hdr: dns.RR_Header{
			Name:   q.Name,
			Rrtype: dns.TypeTXT,
			Class:  dns.ClassINET,
			Ttl:    0,
		},
		Txt: []string{encodeBase32(respPayload)},
	}
	m.Answer = append(m.Answer, txt)
	log.Printf("dns: respond len=%d txt_len=%d", len(respPayload), len(txt.Txt[0]))
	_ = w.WriteMsg(m)
}

func processPayload(payload []byte, priv ed25519.PrivateKey, sessions *SessionStore, app *AppServer) ([]byte, bool) {
	if len(payload) >= 2 && payload[0] == protoVersion && payload[1] == handshakeRequest {
		log.Printf("app: handshake request len=%d", len(payload))
		return handleHandshake(payload, priv, sessions)
	}
	log.Printf("app: encrypted payload len=%d", len(payload))
	return handleEncrypted(payload, sessions, app)
}

func handleHandshake(payload []byte, priv ed25519.PrivateKey, sessions *SessionStore) ([]byte, bool) {
	if len(payload) != 1+1+8 {
		return nil, false
	}
	clientNonce := payload[2:]

	sessionID, err := randomBytes(sessionIDSize)
	if err != nil {
		return nil, false
	}
	key, err := randomBytes(keySize)
	if err != nil {
		return nil, false
	}

	signed := make([]byte, 0, 1+1+sessionIDSize+keySize+len(clientNonce))
	signed = append(signed, protoVersion, handshakeResponse)
	signed = append(signed, sessionID...)
	signed = append(signed, key...)
	signed = append(signed, clientNonce...)

	sig := ed25519.Sign(priv, signed)

	sessions.Put(sessionID, key)

	resp := make([]byte, 0, 1+1+sessionIDSize+keySize+signatureSize)
	resp = append(resp, protoVersion, handshakeResponse)
	resp = append(resp, sessionID...)
	resp = append(resp, key...)
	resp = append(resp, sig...)
	return resp, true
}

func handleEncrypted(payload []byte, sessions *SessionStore, app *AppServer) ([]byte, bool) {
	minLen := sessionIDSize + nonceSize + 16
	if len(payload) < minLen {
		return nil, false
	}
	id := payload[:sessionIDSize]
	nonce := payload[sessionIDSize : sessionIDSize+nonceSize]
	ciphertext := payload[sessionIDSize+nonceSize:]

	key, ok := sessions.Get(id)
	if !ok {
		return nil, false
	}

	plaintext, err := decryptAESGCM(key, nonce, ciphertext, id)
	if err != nil {
		return nil, false
	}

	respPayload, err := app.Handle(plaintext)
	if err != nil {
		return nil, false
	}

	respNonce, err := randomBytes(nonceSize)
	if err != nil {
		return nil, false
	}
	respCipher, err := encryptAESGCM(key, respNonce, respPayload, id)
	if err != nil {
		return nil, false
	}

	resp := make([]byte, 0, sessionIDSize+nonceSize+len(respCipher))
	resp = append(resp, id...)
	resp = append(resp, respNonce...)
	resp = append(resp, respCipher...)
	return resp, true
}
