package core

import (
	"os"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/data/binding"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/widget"
	"github.com/go-gl/glfw/v3.3/glfw"
	"github.com/ventsislav-georgiev/prosper/pkg/command"
	"github.com/ventsislav-georgiev/prosper/pkg/currency"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/mathexpr"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
	"github.com/ventsislav-georgiev/prosper/pkg/shortcuts"
	"github.com/ventsislav-georgiev/prosper/pkg/translate"
	"github.com/ventsislav-georgiev/prosper/pkg/units"
	"golang.design/x/hotkey"
)

func Run() {
	os.Setenv("FYNE_THEME", "dark")
	os.Setenv("FYNE_SCALE", "1.5")

	app := app.NewWithID("com.ventsislav-georgiev.prosper")
	global.AppInstance = app

	drv, ok := app.Driver().(desktop.Driver)
	if !ok {
		w := app.NewWindow("Unsupported Platform")
		w.SetContent(widget.NewLabel("Only desktop environments are supported"))
		w.ShowAndRun()
		return
	}

	win := drv.CreateSplashWindow().(fyne.GLFWWindow)
	global.AppWindow = win

	win.Resize(fyne.Size{Width: 400})
	win.SetBeforeShowed(func() {
		center(win.ViewPort())
	})

	out := widget.NewLabel("")
	r := binding.NewString()
	out.Bind(r)

	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(newIconLayout(), i)
	iconContainer.Hide()

	in := widget.NewEntry()
	in.SetPlaceHolder("Enter expression here...")

	onEnter := &struct{ fn func() }{}
	in.OnChanged = getOnChanged(r, i, iconContainer, onEnter)

	reset := func() {
		in.SetText("")
		r.Set("")
		iconContainer.Hide()
	}

	in.OnSubmitted = func(_ string) {
		if onEnter.fn != nil {
			onEnter.fn()
			reset()
			win.ViewPort().Hide()
		}
	}

	results := container.NewHBox(iconContainer, out)
	win.SetContent(container.NewVBox(in, results))
	win.Canvas().Focus(in)
	win.Show()

	onClose := &struct{ fn func() }{}
	global.Quit = func() {
		for fn := range global.OnClose.Iter() {
			fn()
		}
		app.Quit()
	}

	optKey := []hotkey.Modifier{hotkey.ModOption}
	spaceKey := hotkey.Key(49)
	shortcuts.Register(optKey, spaceKey, func() {
		global.AppWindow.Show()
		win.Canvas().Focus(in)
	})

	win.RunOnMainWhenCreated(func() {
		setupWinHooks(win, reset, onClose)
	})

	app.Run()
}

func center(w *glfw.Window) {
	monitor := w.GetMonitor()
	if monitor == nil {
		monitor = glfw.GetPrimaryMonitor()
	}

	viewWidth, viewHeight := w.GetSize()
	if 120 > viewHeight {
		viewHeight = 120
	}

	monMode := monitor.GetVideoMode()
	monX, monY := monitor.GetPos()
	newX := (monMode.Width / 2) - (viewWidth / 2) + monX
	newY := ((monMode.Height / 2) - (viewHeight / 2) + monY) - 50

	w.SetPos(newX, newY)
}

func setupWinHooks(w fyne.GLFWWindow, onHide func(), onClose *struct{ fn func() }) {
	w.ViewPort().SetFocusCallback(func(w *glfw.Window, focused bool) {
		if !focused {
			w.Hide()
			onHide()
		}
	})

	w.SetCloseIntercept(func() { global.Quit() })
}

// type mainLoopListener struct {
// 	ch <-chan struct{}
// 	fn func()
// }

// func (l *mainLoopListener) Ch() <-chan struct{} {
// 	return l.ch
// }

// func (l *mainLoopListener) Fn() {
// 	l.fn()
// }

func getOnChanged(r binding.String, i *widget.Icon, iconContainer *fyne.Container, onEnter *struct{ fn func() }) func(expr string) {
	evals := []func(string) (string, []byte, func(), error){
		command.Eval,
		mathexpr.Eval,
		currency.Eval,
		translate.Eval,
		units.Eval,
		open.Eval,
	}

	inflight := false
	drop := false

	return func(expr string) {
		defer func() { recover() }()

		if inflight {
			drop = true
		}

		inflight = true

		if len(expr) < 2 {
			inflight = false
			drop = false
			iconContainer.Hide()
			r.Set("")
			return
		}

		for _, fn := range evals {
			res, icon, enterFn, err := fn(expr)

			if drop {
				drop = false
				return
			}

			onEnter.fn = enterFn

			if err == nil {
				inflight = false
				if icon != nil {
					i.SetResource(fyne.NewStaticResource(res, icon))
					iconContainer.Show()
				} else {
					iconContainer.Hide()
				}
				r.Set(res)
				return
			}
		}

		inflight = false
		iconContainer.Hide()
		r.Set("")
	}
}
