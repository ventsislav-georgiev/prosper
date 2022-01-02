package shortcuts

import (
	"fmt"

	"fyne.io/fyne/v2"
	"github.com/go-gl/glfw/v3.3/glfw"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
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

	var err error
	run := func(fn func()) { fn() }
	if helpers.IsDarwin {
		run = global.AppWindow.RunOnMain
	}

	unregister := make(chan struct{})

	go func() {
		run(func() { err = hk.Register() })
		if err != nil {
			fmt.Printf("failed to register hotkey: %v\n", err)
			return
		}

		for {
			select {
			case <-hk.Keydown():
				go fn()
			case <-unregister:
				run(func() { hk.Unregister() })
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
		if mod.contains(keyName) {
			m = append(m, keyNameModMap[keyName])
			continue
		}

		var code glfw.Key
		if helpers.IsWindows {
			code, ok = keyNameWindowVKCodeMap[keyName]
			if ok {
				k = hotkey.Key(code)
			}
		} else {
			code, ok = keyNameGLFWCodeMap[keyName]
			if ok {
				k = hotkey.Key(glfw.GetKeyScancode(code))
			}
		}
	}

	return
}
