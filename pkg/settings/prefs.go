package settings

import (
	"encoding/json"
	"sync"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/theme"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
)

const shortcutsStore = "shortcuts.json"

var (
	prefs           *sync.Map
	defaultCommands map[string]*shortcut
)

type shortcut struct {
	ExecInfo        *exec.Info
	Command         *Command
	KeyNames        []fyne.KeyName
	DisplayKeyNames string
	unregister      func()
}

func init() {
	optionKey := "Alt"
	if helpers.IsDarwin {
		optionKey = "Option"
	}

	defaultCommands = map[string]*shortcut{
		"Show Launcher": {
			Command: &Command{
				ID:   "Show Launcher",
				Name: "Show Launcher",
				icon: func() []byte { return theme.RadioButtonCheckedIcon().Content() },
				run:  func() { global.AppWindow.Show() },
			},
			KeyNames:        []fyne.KeyName{desktop.KeyAltLeft, fyne.KeySpace},
			DisplayKeyNames: optionKey + "+Space",
		},
		"Open Settings": {
			Command: &Command{
				ID:   "Open Settings",
				Name: "Open Settings",
				icon: func() []byte { return theme.SettingsIcon().Content() },
				run:  func() { Edit() },
			},
		},
	}
}

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

type Command struct {
	ID   string
	Name string

	icon func() []byte
	run  func()
}

func (e shortcut) ID() string {
	if e.ExecInfo != nil {
		return e.ExecInfo.Filepath()
	}
	return e.Command.ID
}

func (e shortcut) Name() string {
	if e.ExecInfo != nil {
		return e.ExecInfo.DisplayName
	}
	return e.Command.Name
}

func (e shortcut) Icon() (icon []byte) {
	if e.ExecInfo != nil {
		_, icon, _, _ = open.EvalApp(*e.ExecInfo)
	} else {
		icon = e.Command.icon()
	}
	return
}

func (e shortcut) Run() {
	if e.ExecInfo != nil {
		e.ExecInfo.Exec()
		return
	}

	e.Command.run()
}

func (e shortcut) Data() shortcut {
	return e
}
