package settings

import (
	"encoding/json"
	"sync"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/theme"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/exec"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
	"github.com/ventsislav-georgiev/prosper/pkg/shell"
)

const shortcutsStore = "shortcuts.json"

var (
	Prefs *sync.Map
)

type shortcut struct {
	ExecInfo        *exec.Info
	ShellCommand    *string
	Command         *Command
	KeyNames        []fyne.KeyName
	DisplayKeyNames string
	unregister      func()
}

func Load() error {
	if Prefs != nil {
		return nil
	}

	Prefs = &sync.Map{}

	r, err := global.App.Storage().Open(shortcutsStore)
	if err != nil {
		w, err := global.App.Storage().Create(shortcutsStore)
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
		Prefs.Store(k, v)
	}

	return nil
}

func Save() error {
	w, err := global.App.Storage().Save(shortcutsStore)
	if err != nil {
		return err
	}

	defer w.Close()

	s := make(map[string]*shortcut)
	Prefs.Range(func(k, v interface{}) bool {
		sh := v.(*shortcut)
		if sh.Command != nil && sh.Command.run == nil {
			return true
		}
		s[k.(string)] = sh
		return true
	})

	e := json.NewEncoder(w)
	e.SetIndent("", "\t")
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
	if e.ShellCommand != nil {
		return *e.ShellCommand
	}
	return e.Command.ID
}

func (e shortcut) Name() string {
	if e.ExecInfo != nil {
		return e.ExecInfo.DisplayName
	}
	if e.ShellCommand != nil {
		return *e.ShellCommand
	}
	return e.Command.Name
}

func (e shortcut) Icon() (icon []byte) {
	if e.ExecInfo != nil {
		_, icon, _, _ = open.EvalApp(*e.ExecInfo)
		return
	}
	if e.ShellCommand != nil {
		icon = theme.ComputerIcon().Content()
		return
	}
	icon = e.Command.icon()
	return
}

func (e shortcut) Run() {
	if e.ExecInfo != nil {
		e.ExecInfo.Exec()
		return
	}
	if e.ShellCommand != nil {
		_, _, exec, err := shell.Eval(*e.ShellCommand)
		if err == nil {
			exec()
		}
		return
	}
	e.Command.run()
}

func (e shortcut) Data() shortcut {
	return e
}
