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
)

func Run(icon []byte) {
	os.Setenv("FYNE_THEME", "dark")
	if helpers.IsDarwin {
		os.Setenv("FYNE_SCALE", "1.3")
	}

	app := app.NewWithID("com.ventsislav-georgiev.prosper")
	global.AppInstance = app
	app.SetIcon(fyne.NewStaticResource("icon.png", icon))

	drv, ok := app.Driver().(desktop.Driver)
	if !ok {
		w := app.NewWindow("Unsupported Platform")
		w.SetContent(widget.NewLabel("Only desktop environments are supported"))
		w.ShowAndRun()
		return
	}

	win := drv.CreateSplashWindow().(fyne.GLFWWindow)
	global.AppWindow = win

	win.SetBeforeShowed(func() {
		center(win.ViewPort())
	})

	out := widget.NewLabel("")
	r := binding.NewString()
	out.Bind(r)

	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(helpers.NewIconLayout(), i)
	iconContainer.Hide()

	in := &helpers.EscEntry{}
	in.ExtendBaseWidget(in)
	in.SetPlaceHolder("Enter expression here...                                        ")

	onEnter := &struct{ fn func() }{}
	in.OnChanged = getOnChanged(r, i, iconContainer, onEnter)

	reset := func() {
		in.SetText("")
		r.Set("")
		iconContainer.Hide()
	}

	in.OnEsc = func() {
		reset()
		win.ViewPort().Hide()
	}

	in.OnSubmitted = func(_ string) {
		reset()
		if onEnter.fn != nil {
			win.ViewPort().Hide()
			onEnter.fn()
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

	win.RunOnMainWhenCreated(func() {
		setupWinHooks(win, reset, onClose)
	})

	go func() {
		if m, k, ok := shortcuts.ToHotkey([]fyne.KeyName{desktop.KeyAltLeft, fyne.KeySpace}); ok {
			shortcuts.Register(m, k, func() {
				win.Canvas().Focus(in)
				global.AppWindow.Show()
			})
		}

		shortcuts.RegisterDefined()
	}()

	app.Run()
}

func center(w *glfw.Window) {
	monitor := w.GetMonitor()
	if monitor == nil {
		monitor = glfw.GetPrimaryMonitor()
	}

	viewWidth, viewHeight := w.GetSize()
	if viewHeight < 120 {
		viewHeight = 120
	}

	monMode := monitor.GetVideoMode()
	monX, monY := monitor.GetPos()
	newX := (monMode.Width / 2) - (viewWidth / 2) + monX
	newY := ((monMode.Height / 2) - (viewHeight / 2) + monY) - (viewHeight / 2)

	w.SetPos(newX, newY)
}

func setupWinHooks(win fyne.GLFWWindow, onHide func(), onClose *struct{ fn func() }) {
	win.ViewPort().SetFocusCallback(func(w *glfw.Window, focused bool) {
		if !focused {
			go win.Hide()
			onHide()
		}
	})

	win.SetCloseIntercept(func() { global.Quit() })
}

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

	fn := func(expr string) {
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

	return func(expr string) { go fn(expr) }
}
