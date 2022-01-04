package shortcuts

import (
	"fmt"

	"fyne.io/fyne/v2"
	"github.com/go-gl/glfw/v3.3/glfw"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/shortcuts/keymap"
	"golang.design/x/hotkey"
)

func RegisterDefined() {
	err := Load()
	if err != nil {
		fmt.Println(err)
		return
	}

	prefs.Range(func(k, value interface{}) bool {
		v := value.(*shortcut)
		if m, k, ok := ToHotkey(v.KeyNames); ok {
			v.unregister = Register(m, k, v.ExecInfo.Exec)
		}
		return true
	})
}

func Register(m []hotkey.Modifier, k hotkey.Key, fn func()) func() {
	hk := hotkey.New(m, k)

	err := hk.Register()
	if err != nil {
		fmt.Printf("failed to register hotkey: %v\n", err)
		return nil
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
