package global

import (
	"sync"

	"fyne.io/fyne/v2"
	"github.com/go-gl/glfw/v3.3/glfw"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/windowh"
)

var (
	App                       fyne.App
	ShowRunner                func()
	Quit                      func()
	OnClose                   = helpers.NewConcurrentSliceWithFuncs()
	IsRunnerCommandRegistered = &helpers.AtomicBool{}

	openWindows = &sync.Map{}
)

type openWindow struct {
	Window  fyne.GLFWWindow
	Focused *helpers.AtomicBool
}

func NewWindow(windowName string, createWin func() fyne.GLFWWindow) (w fyne.GLFWWindow, onClose func(), onFocus func(focused bool)) {
	onClose = func() {
		openWindows.Delete(windowName)
		go windowh.HideApp()
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
		return nil, nil, nil
	}

	if createWin != nil {
		w = createWin()
	} else {
		w = App.NewWindow(windowName).(fyne.GLFWWindow)
	}

	w.SetBeforeShowed(func() {
		center(w.ViewPort())
	})

	shouldClose := &helpers.AtomicBool{Val: 1}
	onFocus = func(focused bool) { shouldClose.Set(focused) }

	w.RunOnMainWhenCreated(func() {
		w.ViewPort().SetFocusCallback(func(w *glfw.Window, focused bool) { onFocus(focused) })
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

func center(w *glfw.Window) {
	monitor := getMonitorTheCursorIsOn(w)
	if monitor == nil {
		monitor = glfw.GetPrimaryMonitor()
	}

	viewWidth, viewHeight := w.GetSize()
	if viewHeight < 120 {
		viewHeight = 120
	}

	yshift := 0
	if viewHeight == 120 {
		yshift = 60
	}

	monMode := monitor.GetVideoMode()
	monX, monY := monitor.GetPos()
	newX := (monMode.Width / 2) - (viewWidth / 2) + monX
	newY := ((monMode.Height / 2) - (viewHeight / 2) + monY) - yshift

	w.SetPos(newX, newY)
}

func getMonitorTheCursorIsOn(w *glfw.Window) *glfw.Monitor {
	cx, cy := w.GetCursorPos()
	wx, wy := w.GetPos()

	// cursor position is relative to window
	cx += float64(wx)
	cy += float64(wy)

	monitors := glfw.GetMonitors()
	for _, monitor := range monitors {
		monMode := monitor.GetVideoMode()
		mx, my := monitor.GetPos()

		left, top := float64(mx), float64(my)
		right := left + float64(monMode.Width)
		bottom := top + float64(monMode.Height)

		if cx > left && cx < right && cy > top && cy < bottom {
			return monitor
		}
	}

	return nil
}
