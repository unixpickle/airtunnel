package main

import (
	"container/heap"
	"time"
)

type LastUser interface {
	LastUsed() time.Time
}

type LRUTracker[T interface {
	LastUser
	comparable
}] struct {
	items map[T]*lruItem[T]
	heap  lruHeap[T]
}

type lruItem[T interface {
	LastUser
	comparable
}] struct {
	value    T
	lastUsed time.Time
	index    int
}

type lruHeap[T interface {
	LastUser
	comparable
}] []*lruItem[T]

func NewLRUTracker[T interface {
	LastUser
	comparable
}]() *LRUTracker[T] {
	return &LRUTracker[T]{
		items: make(map[T]*lruItem[T]),
	}
}

func (l *LRUTracker[T]) PushOrUpdate(value T) {
	ts := value.LastUsed()
	if item, ok := l.items[value]; ok {
		item.lastUsed = ts
		heap.Fix(&l.heap, item.index)
		return
	}
	item := &lruItem[T]{value: value, lastUsed: ts}
	l.items[value] = item
	heap.Push(&l.heap, item)
}

func (l *LRUTracker[T]) Remove(value T) {
	item, ok := l.items[value]
	if !ok {
		return
	}
	delete(l.items, value)
	heap.Remove(&l.heap, item.index)
}

func (l *LRUTracker[T]) PeekLastUsed() (T, bool) {
	if len(l.heap) == 0 {
		var zero T
		return zero, false
	}
	return l.heap[0].value, true
}

func (l *LRUTracker[T]) PopLastUsed() (T, bool) {
	if len(l.heap) == 0 {
		var zero T
		return zero, false
	}
	item := heap.Pop(&l.heap).(*lruItem[T])
	delete(l.items, item.value)
	return item.value, true
}

func (l *LRUTracker[T]) Len() int {
	return len(l.items)
}

func (h lruHeap[T]) Len() int { return len(h) }

func (h lruHeap[T]) Less(i, j int) bool {
	return h[i].lastUsed.Before(h[j].lastUsed)
}

func (h lruHeap[T]) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}

func (h *lruHeap[T]) Push(x any) {
	item := x.(*lruItem[T])
	item.index = len(*h)
	*h = append(*h, item)
}

func (h *lruHeap[T]) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	item.index = -1
	*h = old[:n-1]
	return item
}
