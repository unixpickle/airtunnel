package main

import (
	"flag"
	"log"
	"strings"

	"github.com/miekg/dns"
)

type Handler func([]byte) ([]byte, error)

func main() {
	var root string
	var addr string
	flag.StringVar(&root, "root", "", "root domain (e.g. ns.aqnichol.com)")
	flag.StringVar(&addr, "addr", ":5353", "listen address")
	flag.Parse()

	if strings.TrimSpace(root) == "" {
		log.Fatal("-root is required")
	}

	root = dns.Fqdn(root)
	maxReq := maxRequestSize(root)
	maxResp := maxResponseSize()
	log.Printf("root=%s max_request_bytes=%d max_response_bytes=%d", root, maxReq, maxResp)

	server := &dns.Server{Addr: addr, Net: "udp"}
	server.Handler = dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		m := new(dns.Msg)
		m.SetReply(r)
		m.Authoritative = true

		if len(r.Question) == 0 {
			m.Rcode = dns.RcodeFormatError
			_ = w.WriteMsg(m)
			return
		}

		q := r.Question[0]
		payload, ok := decodeQuestion(root, q)
		if !ok {
			m.Rcode = dns.RcodeNameError
			_ = w.WriteMsg(m)
			return
		}
		if len(payload) > maxReq {
			m.Rcode = dns.RcodeFormatError
			_ = w.WriteMsg(m)
			return
		}

		resp, err := echoHandler(payload)
		if err != nil {
			m.Rcode = dns.RcodeServerFailure
			_ = w.WriteMsg(m)
			return
		}
		if len(resp) > maxResp {
			m.Rcode = dns.RcodeFormatError
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
			Txt: []string{encodeBase32(resp)},
		}
		m.Answer = append(m.Answer, txt)
		_ = w.WriteMsg(m)
	})

	log.Printf("listening on %s", addr)
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
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

func echoHandler(data []byte) ([]byte, error) {
	return data, nil
}
