package helpers

import "sync"

type ConcurrentSliceWithFuncs struct {
	rw    sync.RWMutex
	funcs []func()
}

type ConcurrentSliceFunc struct {
	Index int
	Fn    func()
}

func NewConcurrentSliceWithFuncs() *ConcurrentSliceWithFuncs {
	return &ConcurrentSliceWithFuncs{
		funcs: make([]func(), 0),
	}
}

func (s *ConcurrentSliceWithFuncs) Append(fn func()) {
	s.rw.Lock()
	defer s.rw.Unlock()
	s.funcs = append(s.funcs, fn)
}

func (s *ConcurrentSliceWithFuncs) Iter() <-chan func() {
	ch := make(chan func())
	go func() {
		s.rw.RLock()
		defer s.rw.RUnlock()
		for _, fn := range s.funcs {
			ch <- fn
		}
		close(ch)
	}()
	return ch
}
