package settings

import (
	"fmt"
	"sort"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/data/binding"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/fyneh"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
)

const (
	WindowName = "Settings"
)

func Show() {
	err := Load()
	if err != nil {
		fmt.Println(err.Error())
	}

	s := make(map[string]*shortcut)
	prefs.Range(func(k, v interface{}) bool {
		s[k.(string)] = v.(*shortcut)
		return true
	})

	sortKey := make([]string, 0)
	sortNames := make([]string, 0)
	for _, v := range s {
		if v.Command != nil {
			sortNames = append(sortNames, v.ID())
		} else {
			sortKey = append(sortKey, v.DisplayKeyNames)
		}
	}
	sort.Strings(sortNames)
	sort.Strings(sortKey)

	w, _ := global.NewWindow(WindowName, false)
	w.CenterOnScreen()

	execList := container.NewVBox()
	for _, k := range sortKey {
		for _, v := range s {
			if v.DisplayKeyNames == k && v.ExecInfo != nil {
				addListItem(w, execList, v, true, false)
			}
		}
	}

	addButton := widget.NewButtonWithIcon("Add New", theme.ContentAddIcon(), func() { addShortcutView(w, execList) })

	execListC := container.NewVScroll(execList)
	execListC.SetMinSize(fyne.NewSize(500, 0))

	commandList := container.NewVBox()
	for _, k := range sortNames {
		for _, v := range s {
			if v.ID() == k {
				addListItem(w, commandList, v, true, true)
			}
		}
	}
	commandListC := container.NewVScroll(commandList)
	commandListC.SetMinSize(fyne.NewSize(500, 0))

	w.SetContent(container.
		NewBorder(
			nil,
			addButton,
			container.NewVSplit(commandListC, execListC),
			nil,
		),
	)
	w.Resize(fyne.Size{Width: 0, Height: 500})
	w.Show()
}

func addShortcutView(w fyne.Window, listContainer *fyne.Container) {
	in := &fyneh.InputEntry{}
	in.ExtendBaseWidget(in)
	in.SetPlaceHolder("Enter app name...")

	out := widget.NewLabel("")
	r := binding.NewString()
	out.Bind(r)

	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(fyneh.NewIconLayout(), i)
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
		defer w.Canvas().Overlays().Remove(p)

		v := shortcut{
			ExecInfo:        &execInfo,
			KeyNames:        keysInput.keyNames,
			DisplayKeyNames: keysInput.KeyNames(),
		}

		prefs.Store(v.ID(), &v)
		err := Save()
		if err != nil {
			fmt.Println(err.Error())
		}

		addListItem(w, listContainer, &v, false, false)
	}
}

func editShortcutView(w fyne.Window, v *shortcut, b binding.ExternalString) {
	keysInput := &keysEntry{}
	keysInput.SetPlaceHolder("Enter key combination...")
	keysInput.ExtendBaseWidget(keysInput)
	c := container.NewMax(keysInput)

	p := widget.NewModalPopUp(c, w.Canvas())
	p.Resize(fyne.NewSize(200, 0))
	p.Show()
	p.Canvas.Focus(keysInput)

	keysInput.OnSubmitted = func(s string) {
		defer w.Canvas().Overlays().Remove(p)

		v.KeyNames = keysInput.keyNames
		v.DisplayKeyNames = keysInput.KeyNames()
		b.Reload()

		err := Save()
		if err != nil {
			fmt.Println(err.Error())
		}

		if v.unregister != nil {
			v.unregister()
		}

		if m, k, ok := ToHotkey(v.KeyNames); ok {
			v.unregister = register(v.Name(), m, k, v.Run)
		} else if v.Name() == CommandRunnerName {
			global.IsRunnerCommandRegistered.Set(false)
		}
	}
}

func addListItem(w fyne.Window, c *fyne.Container, v *shortcut, registered bool, readonly bool) {
	name := v.Name()
	if len(name) > maxNameLen {
		name = name[:int(maxNameLen)] + "..."
	}

	label := widget.NewLabel(name)
	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(fyneh.NewIconLayout(), i)
	iconContainer.Hide()
	nameWithIcon := container.NewHBox(iconContainer, label)

	icon := v.Icon()
	if icon != nil {
		i.SetResource(fyne.NewStaticResource(v.Name(), icon))
		iconContainer.Show()
	}

	var item *fyne.Container

	keysBinding := binding.BindString(&v.DisplayKeyNames)

	edit := widget.NewButtonWithIcon("", theme.DocumentCreateIcon(), func() {
		editShortcutView(w, v, keysBinding)
	})
	remove := widget.NewButtonWithIcon("", theme.DeleteIcon(), func() {
		prefs.Delete(v.ID())
		Save()
		c.Remove(item)
		if v.unregister != nil {
			v.unregister()
		}
	})

	if readonly {
		remove.Disable()
	}

	item = container.NewBorder(nil, nil, nil,
		container.NewHBox(edit, remove),
		container.NewGridWithColumns(2, nameWithIcon, widget.NewLabelWithData(keysBinding)),
	)

	c.Add(item)

	if v.unregister == nil {
		if m, k, ok := ToHotkey(v.KeyNames); ok {
			v.unregister = register(v.Name(), m, k, v.Run)
		}
	}
}
