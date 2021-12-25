package shortcuts

import (
	"context"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"golang.design/x/hotkey"
)

var (
	win fyne.Window
)

func Open() {
	w := getOrCreate()
	w.CenterOnScreen()
	w.SetContent(container.NewVBox(widget.NewButton("Test", func() {})))
	w.Show()
}

func getOrCreate() fyne.Window {
	if win != nil {
		return win
	}

	win := global.AppInstance.NewWindow("Shortcuts")
	return win
}

func Register(m []hotkey.Modifier, k hotkey.Key, fn func()) bool {
	hk, err := hotkey.Register(m, k, global.AppWindow.RunOnMain, true)
	if err != nil {
		return false
	}

	global.OnClose.Append(func() { hotkey.Unregister(hk) })

	scheduleOnMain := func(fn func()) {
		go global.AppWindow.RunOnMain(fn)
	}

	triggered := hk.Listen(context.Background(), scheduleOnMain)

	go func() {
		for range triggered {
			fn()
		}
	}()

	return true
}
