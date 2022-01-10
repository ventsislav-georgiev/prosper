package global

import (
	"sync"

	"fyne.io/fyne/v2"
	"github.com/go-gl/glfw/v3.3/glfw"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

var (
	App                       fyne.App
	RunnerWindow              fyne.GLFWWindow
	ShowRunner                func()
	Quit                      func()
	OnClose                   = helpers.NewConcurrentSliceWithFuncs()
	IsRunnerCommandRegistered = &helpers.AtomicBool{}
	IgnoreNextFocus           = &helpers.AtomicBool{}

	openWindows = &sync.Map{}
)

type openWindow struct {
	Window  fyne.GLFWWindow
	Focused *helpers.AtomicBool
}

func NewWindow(windowName string, showRunner bool) (w fyne.GLFWWindow, onClose func()) {
	onClose = func() {
		openWindows.Delete(windowName)
		if showRunner {
			go ShowRunner()
		} else if helpers.IsDarwin && IsRunnerCommandRegistered.Get() {
			IgnoreNextFocus.Set(true)
		}
	}

	v, ok := openWindows.Load(windowName)
	if ok {
		w := v.(openWindow)
		if w.Focused.Get() {
			onClose()
			w.Window.Close()
		} else {
			w.Window.Show()
		}
		return nil, nil
	}

	w = App.NewWindow(windowName).(fyne.GLFWWindow)
	shouldClose := &helpers.AtomicBool{Val: 1}

	w.RunOnMainWhenCreated(func() {
		w.ViewPort().SetFocusCallback(func(w *glfw.Window, focused bool) { shouldClose.Set(focused) })
	})

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

	openWindows.Store(windowName, openWindow{Window: w, Focused: shouldClose})
	return
}
