package settings

import (
	"fmt"
	"io"

	"fyne.io/fyne/v2"
	"github.com/go-gl/glfw/v3.3/glfw"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/settings/keymap"
	"golang.design/x/hotkey"
)

func RegisterDefined() {
	err := Load()
	if err != nil && err != io.EOF {
		fmt.Println(err)
		return
	}

	if defaultCommands != nil {
		Prefs.Range(func(k, value interface{}) bool {
			v := value.(*shortcut)
			d, ok := defaultCommands[v.ID()]
			if ok {
				v.Command.icon = d.Command.icon
				v.Command.run = d.Command.run
				delete(defaultCommands, v.ID())
			}
			return true
		})

		for k, v := range defaultCommands {
			Prefs.Store(k, v)
		}
	}

	defaultCommands = nil

	Prefs.Range(func(k, value interface{}) bool {
		v := value.(*shortcut)
		if v.Command != nil && v.Command.run == nil {
			Prefs.Delete(v.Command.ID)
			return true
		}
		RegisterShortcut(v)
		return true
	})

	Save()
}

func RegisterShortcut(s *shortcut) {
	if m, k, ok := ToHotkey(s.KeyNames); ok {
		s.unregister = register(s.Name(), m, k, s.Run)
	}
}

func register(c string, m []hotkey.Modifier, k hotkey.Key, fn func()) func() {
	hk := hotkey.New(m, k)

	err := hk.Register()
	if err != nil {
		fmt.Printf("failed to register hotkey: %v\n", err)
		return nil
	}

	if c == commandRunnerName {
		global.IsRunnerCommandRegistered.Set(true)
	}

	unregister := make(chan struct{})
	go func() {
		for {
			select {
			case <-hk.Keydown():
				go fn()
			case <-unregister:
				hk.Unregister()
				return
			}
		}
	}()

	return func() {
		unregister <- struct{}{}
	}
}

func ToHotkey(keyNames []fyne.KeyName) (m []hotkey.Modifier, k hotkey.Key, ok bool) {
	m = make([]hotkey.Modifier, 0)
	for _, keyName := range keyNames {
		if keymap.IsModifier(keyName) {
			m = append(m, keymap.KeyNameModMap[keyName])
			continue
		}

		var code glfw.Key
		code, ok = keymap.KeyNameGLFWCodeMap[keyName]
		if !ok {
			return
		}

		if helpers.IsDarwin {
			k = hotkey.Key(glfw.GetKeyScancode(code))
		} else {
			k = hotkey.Key(code)
		}

		return
	}

	return
}
