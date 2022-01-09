package global

import (
	"sync"

	"fyne.io/fyne/v2"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

var (
	AppInstance               fyne.App
	AppWindow                 fyne.GLFWWindow
	Quit                      func()
	OnClose                   = helpers.NewConcurrentSliceWithFuncs()
	IsRunnerCommandRegistered = &helpers.AtomicBool{}
	IgnoreNextFocus           = &helpers.AtomicBool{}

	openWindows = &sync.Map{}
)

func NewWindow(windowName string, showRunner bool) (w fyne.GLFWWindow, onClose func()) {
	onClose = func() {
		openWindows.Delete(windowName)
		if showRunner {
			go AppWindow.Show()
		} else if helpers.IsDarwin && IsRunnerCommandRegistered.Get() {
			IgnoreNextFocus.Set(true)
		}
	}

	v, ok := openWindows.Load(windowName)
	if ok {
		return v.(fyne.GLFWWindow), onClose
	}

	w = AppInstance.NewWindow(windowName).(fyne.GLFWWindow)

	w.Canvas().SetOnTypedKey(func(k *fyne.KeyEvent) {
		if k.Name == fyne.KeyEscape {
			onClose()
			w.Close()
		}
	})

	w.SetCloseIntercept(func() {
		onClose()
		w.Close()
	})

	openWindows.Store(windowName, w)
	return
}
