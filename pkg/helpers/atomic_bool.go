package helpers

import "sync/atomic"

type AtomicBool struct {
	Val int32
}

func NewAtomicBool(v bool) *AtomicBool {
	var i int32
	if v {
		i = 1
	}
	return &AtomicBool{Val: i}
}

func (b *AtomicBool) Get() bool {
	return atomic.LoadInt32(&b.Val) == 1
}

func (b *AtomicBool) Set(v bool) {
	var i int32
	if v {
		i = 1
	}
	atomic.StoreInt32(&b.Val, i)
}
