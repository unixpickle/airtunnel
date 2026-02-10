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
}

type sessionEntry struct {
	key      []byte
	lastUsed time.Time
	item     *sessionHeapItem
}

type sessionHeap []*sessionHeapItem

type sessionHeapItem struct {
	id       string
	lastUsed time.Time
	index    int
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
	if entry.item != nil {
		entry.item.lastUsed = entry.lastUsed
		heap.Fix(&s.expHeap, entry.item.index)
	}
	return entry.key, true
}

func (s *SessionStore) Put(id []byte, key []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	idStr := string(id)
	entry, ok := s.sessions[idStr]
	if !ok {
		item := &sessionHeapItem{id: idStr, lastUsed: now}
		entry = &sessionEntry{key: key, lastUsed: now, item: item}
		s.sessions[idStr] = entry
		heap.Push(&s.expHeap, item)
		return
	}
	entry.key = key
	entry.lastUsed = now
	if entry.item != nil {
		entry.item.lastUsed = now
		heap.Fix(&s.expHeap, entry.item.index)
	}
}

func (s *SessionStore) Prune(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for s.expHeap.Len() > 0 {
		item := s.expHeap[0]
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

func (h sessionHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}

func (h *sessionHeap) Push(x any) {
	item := x.(*sessionHeapItem)
	item.index = len(*h)
	*h = append(*h, item)
}

func (h *sessionHeap) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	item.index = -1
	*h = old[:n-1]
	return item
}
