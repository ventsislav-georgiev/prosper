package shortcuts

import (
	"fmt"
	"sort"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/data/binding"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"github.com/go-gl/glfw/v3.3/glfw"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
)

func Edit() {
	err := Load()
	if err != nil {
		fmt.Println(err.Error())
	}

	w := global.AppInstance.NewWindow("Shortcuts").(fyne.GLFWWindow)
	w.CenterOnScreen()

	listContainer := container.NewVBox()

	s := make(map[string]*shortcut)
	prefs.Range(func(k, v interface{}) bool {
		s[k.(string)] = v.(*shortcut)
		return true
	})

	sortKey := make([]string, 0, len(s))
	for _, v := range s {
		sortKey = append(sortKey, v.DisplayKeyNames)
	}
	sort.Strings(sortKey)

	for _, k := range sortKey {
		for _, v := range s {
			if v.DisplayKeyNames == k {
				addListItem(listContainer, v, true)
			}
		}
	}

	addButton := widget.NewButton("Add New", func() {
		addShortcutView(w, listContainer)
	})

	list := container.NewVScroll(listContainer)
	list.SetMinSize(fyne.NewSize(400, 200))

	w.SetContent(container.
		NewBorder(
			addButton,
			nil,
			list,
			nil,
		),
	)
	w.Show()

	w.RunOnMainWhenCreated(func() {
		w.ViewPort().SetFocusCallback(func(w *glfw.Window, focused bool) {
			if !focused {
				w.SetShouldClose(true)
			}
		})
	})
}

func addShortcutView(w fyne.Window, listContainer *fyne.Container) {
	in := &helpers.EscEntry{}
	in.ExtendBaseWidget(in)
	in.SetPlaceHolder("Enter app name...")

	out := widget.NewLabel("")
	r := binding.NewString()
	out.Bind(r)

	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(helpers.NewIconLayout(), i)
	iconContainer.Hide()
	results := container.NewHBox(iconContainer, out)

	in.OnChanged = func(s string) {
		app, err := open.FindApp(s)
		if err != nil {
			r.Set(err.Error())
			return
		}
		res, icon, _, err := open.EvalApp(app)
		if err != nil {
			r.Set(err.Error())
			return
		}
		if icon != nil {
			i.SetResource(fyne.NewStaticResource(res, icon))
			iconContainer.Show()
		} else {
			iconContainer.Hide()
		}
		r.Set(res)
	}

	c1 := container.NewVBox(container.NewMax(in), container.NewMax(results))

	keysInput := &keysEntry{}
	keysInput.SetPlaceHolder("Enter key combination...")
	keysInput.ExtendBaseWidget(keysInput)
	c2 := container.NewMax(keysInput)
	c2.Hide()

	p := widget.NewModalPopUp(container.NewVBox(c1, c2), w.Canvas())
	p.Resize(fyne.NewSize(200, 0))
	p.Show()
	p.Canvas.Focus(in)

	var execInfo exec.Info
	in.OnSubmitted = func(s string) {
		app, err := open.FindApp(s)
		if err != nil {
			w.Canvas().Overlays().Remove(p)
			return
		}

		execInfo = app

		c1.Hide()
		c2.Show()
		p.Canvas.Focus(keysInput)
	}

	in.OnEsc = func() {
		w.Canvas().Overlays().Remove(p)
	}

	keysInput.OnSubmitted = func(s string) {
		v := shortcut{
			ExecInfo:        execInfo,
			KeyNames:        keysInput.keyNames,
			DisplayKeyNames: keysInput.KeyNames(),
		}
		prefs.Store(execInfo.Filepath(), &v)
		addListItem(listContainer, &v, false)
		w.Canvas().Overlays().Remove(p)
	}
}

func addListItem(c *fyne.Container, v *shortcut, registered bool) {
	name := widget.NewLabel(v.ExecInfo.DisplayName)
	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(helpers.NewIconLayout(), i)
	iconContainer.Hide()
	nameWithIcon := container.NewHBox(iconContainer, name)

	_, icon, _, _ := open.EvalApp(v.ExecInfo)
	if icon != nil {
		i.SetResource(fyne.NewStaticResource(v.ExecInfo.DisplayName, icon))
		iconContainer.Show()
	}

	var item *fyne.Container
	item = container.NewAdaptiveGrid(3,
		nameWithIcon,
		widget.NewLabel(v.DisplayKeyNames),
		widget.NewButtonWithIcon("Remove", theme.ContentClearIcon(), func() {
			prefs.Delete(v.ExecInfo.Filepath())
			Save()
			c.Remove(item)
			if v.unregister != nil {
				v.unregister()
			}
		}),
	)

	c.Add(item)

	if v.unregister == nil {
		if m, k, ok := ToHotkey(v.KeyNames); ok {
			v.unregister = Register(m, k, v.ExecInfo.Exec)
		}
	}

	err := Save()
	if err != nil {
		fmt.Println(err.Error())
	}
}
