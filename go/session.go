package main

import "sync"

type SessionStore struct {
	mu       sync.RWMutex
	sessions map[string][]byte
}

func NewSessionStore() *SessionStore {
	return &SessionStore{sessions: make(map[string][]byte)}
}

func (s *SessionStore) Get(id []byte) ([]byte, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	key, ok := s.sessions[string(id)]
	return key, ok
}

func (s *SessionStore) Put(id []byte, key []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[string(id)] = key
}
