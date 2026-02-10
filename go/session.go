package main

import (
	"container/heap"
	"sync"
	"time"
)

type SessionStore struct {
	mu       sync.RWMutex
	sessions map[string]*sessionEntry
	expHeap  sessionHeap
	ttl      time.Duration
	seq      uint64
}

type sessionEntry struct {
	key      []byte
	lastUsed time.Time
	seq      uint64
}

type sessionHeap []sessionHeapItem

type sessionHeapItem struct {
	id       string
	lastUsed time.Time
	seq      uint64
}

func NewSessionStore(ttl time.Duration) *SessionStore {
	return &SessionStore{
		sessions: make(map[string]*sessionEntry),
		ttl:      ttl,
	}
}

func (s *SessionStore) Get(id []byte) ([]byte, bool) {
	key := string(id)
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.sessions[key]
	if !ok {
		return nil, false
	}
	entry.lastUsed = time.Now()
	s.seq++
	entry.seq = s.seq
	heap.Push(&s.expHeap, sessionHeapItem{id: key, lastUsed: entry.lastUsed, seq: entry.seq})
	return entry.key, true
}

func (s *SessionStore) Put(id []byte, key []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seq++
	entry := &sessionEntry{
		key:      key,
		lastUsed: time.Now(),
		seq:      s.seq,
	}
	s.sessions[string(id)] = entry
	heap.Push(&s.expHeap, sessionHeapItem{id: string(id), lastUsed: entry.lastUsed, seq: entry.seq})
}

func (s *SessionStore) Prune(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for s.expHeap.Len() > 0 {
		item := s.expHeap[0]
		entry, ok := s.sessions[item.id]
		if !ok {
			heap.Pop(&s.expHeap)
			continue
		}
		if entry.seq != item.seq || !entry.lastUsed.Equal(item.lastUsed) {
			heap.Pop(&s.expHeap)
			continue
		}
		if now.Sub(item.lastUsed) <= s.ttl {
			break
		}
		delete(s.sessions, item.id)
		heap.Pop(&s.expHeap)
	}
}

func (h sessionHeap) Len() int { return len(h) }

func (h sessionHeap) Less(i, j int) bool {
	return h[i].lastUsed.Before(h[j].lastUsed)
}

func (h sessionHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }

func (h *sessionHeap) Push(x any) {
	*h = append(*h, x.(sessionHeapItem))
}

func (h *sessionHeap) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	*h = old[:n-1]
	return item
}
