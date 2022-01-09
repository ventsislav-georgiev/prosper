package helpers

import "sync/atomic"

type AtomicBool struct {
	val int32
}

func (b *AtomicBool) Get() bool {
	return atomic.LoadInt32(&b.val) == 1
}

func (b *AtomicBool) Set(v bool) {
	var i int32
	if v {
		i = 1
	}
	atomic.StoreInt32(&b.val, i)
}
