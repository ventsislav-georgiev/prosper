package open

import (
	"sync"
)

type fuzzySource []ExecInfo

func (f fuzzySource) String(i int) string {
	return f[i].DisplayName
}

func (f fuzzySource) Len() int {
	return len(f)
}

type appsList struct {
	rw   sync.RWMutex
	apps []ExecInfo
}

func newAppsList() *appsList {
	return &appsList{
		apps: make([]ExecInfo, 0),
	}
}

func (s *appsList) reinit() {
	s.rw.Lock()
	defer s.rw.Unlock()
	s.apps = make([]ExecInfo, 0)
}

func (s *appsList) set(d []ExecInfo) {
	s.rw.Lock()
	defer s.rw.Unlock()
	s.apps = d
}

func (s *appsList) len() int {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return len(s.apps)
}

func (s *appsList) get(idx int) ExecInfo {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return s.apps[idx]
}

func (s *appsList) fuzzy() fuzzySource {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return s.apps
}
