package apps

import (
	"sync"

	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
)

type FuzzySource []exec.Info

func (f FuzzySource) String(i int) string {
	return f[i].DisplayName
}

func (f FuzzySource) Len() int {
	return len(f)
}

type List struct {
	rw   sync.RWMutex
	apps []exec.Info
}

func NewAppsList() *List {
	return &List{
		apps: make([]exec.Info, 0),
	}
}

func (s *List) Reinit() {
	s.rw.Lock()
	defer s.rw.Unlock()
	s.apps = make([]exec.Info, 0)
}

func (s *List) Set(d []exec.Info) {
	if d == nil {
		return
	}
	s.rw.Lock()
	defer s.rw.Unlock()
	s.apps = d
}

func (s *List) Len() int {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return len(s.apps)
}

func (s *List) Get(idx int) exec.Info {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return s.apps[idx]
}

func (s *List) Fuzzy() FuzzySource {
	s.rw.RLock()
	defer s.rw.RUnlock()
	return s.apps
}
