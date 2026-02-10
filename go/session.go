package main

import (
	"sync"
	"time"
)

type SessionStore struct {
	mu       sync.RWMutex
	sessions map[string]*sessionEntry
	tracker  *LRUTracker[*sessionEntry]
	ttl      time.Duration
}

type sessionEntry struct {
	id       string
	key      []byte
	lastUsed time.Time
}

func (s *sessionEntry) LastUsed() time.Time {
	return s.lastUsed
}


func NewSessionStore(ttl time.Duration) *SessionStore {
	return &SessionStore{
		sessions: make(map[string]*sessionEntry),
		tracker:  NewLRUTracker[*sessionEntry](),
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
	s.tracker.PushOrUpdate(entry)
	return entry.key, true
}

func (s *SessionStore) Put(id []byte, key []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	idStr := string(id)
	entry, ok := s.sessions[idStr]
	if !ok {
		entry = &sessionEntry{id: idStr, key: key, lastUsed: now}
		s.sessions[idStr] = entry
		s.tracker.PushOrUpdate(entry)
		return
	}
	entry.key = key
	entry.lastUsed = now
	s.tracker.PushOrUpdate(entry)
}

func (s *SessionStore) Prune(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for {
		entry, ok := s.tracker.PeekLastUsed()
		if !ok {
			break
		}
		if now.Sub(entry.lastUsed) <= s.ttl {
			break
		}
		s.tracker.PopLastUsed()
		delete(s.sessions, entry.id)
	}
}
