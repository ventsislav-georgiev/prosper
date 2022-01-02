package shortcuts

import (
	"encoding/json"
	"sync"

	"fyne.io/fyne/v2"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
)

type shortcut struct {
	ExecInfo        open.ExecInfo
	KeyNames        []fyne.KeyName
	DisplayKeyNames string
	unregister      func()
}

const shortcutsStore = "shortcuts.json"

var prefs *sync.Map

func Load() error {
	if prefs != nil {
		return nil
	}

	prefs = &sync.Map{}

	r, err := global.AppInstance.Storage().Open(shortcutsStore)
	if err != nil {
		w, err := global.AppInstance.Storage().Create(shortcutsStore)
		if err != nil {
			return err
		}
		w.Close()
		return nil
	}

	defer r.Close()

	var s map[string]*shortcut
	e := json.NewDecoder(r)
	err = e.Decode(&s)
	if err != nil {
		return err
	}

	for k, v := range s {
		prefs.Store(k, v)
	}

	return nil
}

func Save() error {
	w, err := global.AppInstance.Storage().Save(shortcutsStore)
	if err != nil {
		return err
	}

	defer w.Close()

	s := make(map[string]*shortcut)
	prefs.Range(func(k, v interface{}) bool {
		s[k.(string)] = v.(*shortcut)
		return true
	})

	e := json.NewEncoder(w)
	err = e.Encode(s)
	if err != nil {
		return err
	}

	return nil
}
