package open

import (
	"sync"

	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
)

type fuzzySource []exec.Info

func (f fuzzySource) String(i int) string {
	return f[i].DisplayName
}

func (f fuzzySource) Len() int {
	return len(f)
}

type appsList struct {
	rw   sync.RWMutex
	apps []exec.Info
}

func newAppsList() *appsList {
	return &appsList{
		apps: make([]exec.Info, 0),
	}
}

func (s *appsList) reinit() {
	s.rw.Lock()
	defer s.rw.Unlock()
	s.apps = make([]exec.Info, 0)
}

func (s *appsList) set(d []exec.Info) {
	s.rw.Lock()
	defer s.rw.Unlock()
	s.apps = d
}

func (s *appsList) len() int {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return len(s.apps)
}

func (s *appsList) get(idx int) exec.Info {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return s.apps[idx]
}

func (s *appsList) fuzzy() fuzzySource {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return s.apps
}
