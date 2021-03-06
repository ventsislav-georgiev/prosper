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
	Bag     map[string]interface{}
}

func hideApp(targetWindow fyne.GLFWWindow) {
	for _, w := range App.Driver().AllWindows() {
		if w != targetWindow && w.Content().Visible() {
			return
		}
	}

	go targetWindow.RunOnMain(windowh.HideApp)
}

func NewWindow(windowName string, createWin func() fyne.GLFWWindow, closeOnFocused bool) (w fyne.GLFWWindow, onClose func(), onFocus func(focused bool), existing bool, bag map[string]interface{}) {
	_onClose := func(w fyne.GLFWWindow) {
		openWindows.Delete(windowName)
		hideApp(w)
	}

	v, ok := openWindows.Load(windowName)
	if ok {
		w := v.(openWindow)
		if w.Focused.Get() && closeOnFocused {
			_onClose(w.Window)
			w.Window.Close()
		} else {
			w.Window.Show()
		}
		return w.Window, nil, nil, true, w.Bag
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

	onClose = func() { _onClose(w) }
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

	bag = make(map[string]interface{})
	openWindows.Store(windowName, openWindow{Window: w, Focused: shouldClose, Bag: bag})
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
