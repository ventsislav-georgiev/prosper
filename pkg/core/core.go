package core

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

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
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/fyneh"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/osh"
	"github.com/ventsislav-georgiev/prosper/pkg/mathexpr"
	"github.com/ventsislav-georgiev/prosper/pkg/numi"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
	"github.com/ventsislav-georgiev/prosper/pkg/settings"
	"github.com/ventsislav-georgiev/prosper/pkg/shell"
	"github.com/ventsislav-georgiev/prosper/pkg/tools"
	"github.com/ventsislav-georgiev/prosper/pkg/translate"
	"github.com/ventsislav-georgiev/prosper/pkg/units"
)

var (
	initialized = &helpers.AtomicBool{}
)

func Run(icon []byte) {
	os.Setenv("FYNE_THEME", "dark")
	updateScale()

	app := app.NewWithID("com.ventsislav-georgiev.prosper")
	global.App = app
	app.SetIcon(fyne.NewStaticResource("Icon.png", icon))

	drv, ok := app.Driver().(desktop.Driver)
	if !ok {
		w := app.NewWindow("Unsupported Platform")
		w.SetContent(widget.NewLabel("Only desktop environments are supported"))
		w.ShowAndRun()
		return
	}

	global.ShowRunner = func() { createRunnerWindow(drv) }
	global.Quit = func() {
		for fn := range global.OnClose.Iter() {
			fn()
		}
		app.Quit()
	}

	global.ShowRunner()
	app.Run()
}

func createRunnerWindow(drv desktop.Driver) {
	win, onClose, onFocus, existing, _ := global.NewWindow("Command Runner", func() fyne.GLFWWindow {
		return drv.CreateSplashWindow().(fyne.GLFWWindow)
	}, true)

	if existing {
		return
	}

	out := &fyneh.OutputLabel{}
	out.ExtendBaseWidget(out)
	r := binding.NewString()
	out.Bind(r)

	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(fyneh.NewIconLayout(), i)
	iconContainer.Hide()

	in := &fyneh.InputEntry{}
	in.ExtendBaseWidget(in)
	in.SetPlaceHolder("Enter expression here..")

	onEnter := &struct{ fn func() }{}
	in.OnChanged = getOnChanged(r, i, iconContainer, onEnter)

	reset := func() {
		in.SetText("")
		r.Set("")
		iconContainer.Hide()
		win.Content().Refresh()
	}

	close := func() {
		onClose()
		go win.Close()
	}

	in.OnEsc = func() {
		reset()
		if global.IsRunnerCommandRegistered.Get() {
			close()
		}
	}

	in.OnSubmitted = func(string) {
		if onEnter.fn == nil {
			win.Clipboard().SetContent(out.FullText)
			reset()
			return
		}

		reset()
		onEnter.fn()
		if global.IsRunnerCommandRegistered.Get() {
			close()
		}
	}

	scrollIn := container.NewHScroll(in)
	scrollIn.SetMinSize(fyne.NewSize(320, 40))
	scrollOut := container.NewHScroll(container.NewHBox(iconContainer, out))
	scrollOut.SetMinSize(fyne.NewSize(320, 0))

	win.SetContent(container.NewVBox(
		scrollIn,
		scrollOut,
	))
	win.Canvas().Focus(in)
	win.Show()

	win.RunOnMainWhenCreated(func() {
		if !initialized.Get() {
			initialized.Set(true)
			go func() {
				if helpers.IsLinux {
					osh.Initialize()
					time.Sleep(100 * time.Millisecond)
				}
				settings.RegisterDefined()
			}()
		}

		win.ViewPort().SetFocusCallback(func(w *glfw.Window, focused bool) {
			onFocus(focused)
			if !focused && global.IsRunnerCommandRegistered.Get() {
				close()
			}
		})
	})
}

func updateScale() {
	if helpers.IsDarwin {
		os.Setenv("FYNE_SCALE", "1.3")
		return
	}

	if helpers.IsLinux {
		homeDir, _ := os.UserHomeDir()
		if homeDir == "" {
			return
		}
		file, err := os.Open(filepath.Join(homeDir, ".config/monitors.xml"))
		if err != nil {
			return
		}

		defer file.Close()

		scanner := bufio.NewScanner(file)
		scaleRegEx := regexp.MustCompile(`.*?scale\>(?P<scale>.*?)\<.*`)
		primaryRegEx := regexp.MustCompile(`.*?primary\>(?P<primary>.*?)\<.*`)

		var scale string
		var primary bool
		for scanner.Scan() {
			text := scanner.Text()
			scaleMatch := scaleRegEx.FindStringSubmatch(text)
			if len(scaleMatch) == 2 {
				scale = scaleMatch[1]
			}
			primaryMatch := primaryRegEx.FindStringSubmatch(text)
			if len(primaryMatch) == 2 && primaryMatch[1] == "yes" {
				primary = true
			}
			if scale != "" && primary {
				break
			}
			if strings.Contains(text, "</logicalmonitor>") {
				scale = ""
			}
		}

		if scale == "" {
			scale = "1"
		}

		os.Setenv("FYNE_SCALE", scale)
	}
}

func getOnChanged(r binding.String, i *widget.Icon, iconContainer *fyne.Container, onEnter *struct{ fn func() }) func(expr string) {
	evals := []func(string) (string, []byte, func(), error){
		command.Eval,
		tools.Eval,
		open.Eval,
		shell.Eval,
		numi.Eval,
		mathexpr.Eval,
		currency.Eval,
		units.Eval,
		translate.Eval,
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
