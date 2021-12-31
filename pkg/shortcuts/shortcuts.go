package shortcuts

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/data/binding"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/open"
	"golang.design/x/hotkey"
)

type shortcut struct {
	ExecInfo        open.ExecInfo
	KeyNames        []fyne.KeyName
	DisplayKeyNames string
	unregister      func()
}

const shortcutsStore = "shortcuts.json"

var shortcuts = make(map[string]*shortcut)

func RegisterDefined() {
	err := Load()
	if err != nil {
		fmt.Println(err)
		return
	}

	for _, v := range shortcuts {
		m, k := toHotkey(v.KeyNames)
		ok, unregister := Register(m, k, v.ExecInfo.Exec)
		if ok {
			v.unregister = unregister
		}
	}
}

func Load() error {
	r, err := global.AppInstance.Storage().Open(shortcutsStore)
	if err != nil {
		return err
	}

	defer r.Close()

	e := json.NewDecoder(r)
	err = e.Decode(&shortcuts)
	if err != nil {
		return err
	}

	return nil
}

func Save() error {
	w, err := global.AppInstance.Storage().Create(shortcutsStore)
	if err != nil {
		w, err = global.AppInstance.Storage().Save(shortcutsStore)
	}
	if err != nil {
		return err
	}

	defer w.Close()

	e := json.NewEncoder(w)
	err = e.Encode(shortcuts)
	if err != nil {
		return err
	}

	return nil
}

func Edit() {
	err := Load()
	if err != nil {
		fmt.Println(err.Error())
	}

	w := global.AppInstance.NewWindow("Shortcuts")
	w.CenterOnScreen()
	w.Resize(fyne.NewSize(600, 500))

	listContainer := container.NewVBox()

	sortKey := make([]string, 0, len(shortcuts))
	for _, v := range shortcuts {
		sortKey = append(sortKey, v.DisplayKeyNames)
	}
	sort.Strings(sortKey)

	for _, k := range sortKey {
		for _, v := range shortcuts {
			if v.DisplayKeyNames == k {
				addListItem(listContainer, v, true)
			}
		}
	}

	addButton := widget.NewButton("Add New", func() {
		addShortcutView(w, shortcuts, listContainer)
	})

	w.SetContent(container.
		NewBorder(
			addButton,
			widget.NewLabel("* - requires restart"),
			container.NewVScroll(listContainer),
			nil,
		),
	)
	w.Show()
}

func Register(m []hotkey.Modifier, k hotkey.Key, fn func()) (ok bool, unregister func()) {
	hk, err := hotkey.Register(m, k, global.AppWindow.RunOnMain, true)
	if err != nil {
		return false, nil
	}

	// global.OnClose.Append(func() { hotkey.Unregister(hk) })

	scheduleOnMain := func(fn func()) {
		go global.AppWindow.RunOnMain(fn)
	}

	triggered := hk.Listen(context.Background(), scheduleOnMain)

	go func() {
		for range triggered {
			fn()
		}
	}()

	return true, nil
}

func addShortcutView(w fyne.Window, shortcuts map[string]*shortcut, listContainer *fyne.Container) {
	in := widget.NewEntry()
	in.SetPlaceHolder("Enter app name...")
	in.ExtendBaseWidget(in)

	out := widget.NewLabel("")
	r := binding.NewString()
	out.Bind(r)

	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(helpers.NewIconLayout(), i)
	iconContainer.Hide()
	results := container.NewHBox(iconContainer, out)

	in.OnChanged = func(s string) {
		app, err := open.EvalWithoutIcon(s)
		if err != nil {
			r.Set(err.Error())
			return
		}
		res, icon, _, err := open.EvalWithIcon(app)
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

	var execInfo open.ExecInfo
	in.OnSubmitted = func(s string) {
		app, err := open.EvalWithoutIcon(s)
		if err != nil {
			w.Canvas().Overlays().Remove(p)
			return
		}

		execInfo = app

		c1.Hide()
		c2.Show()
		p.Canvas.Focus(keysInput)
	}

	keysInput.OnSubmitted = func(s string) {
		v := shortcut{
			ExecInfo:        execInfo,
			KeyNames:        keysInput.keyNames,
			DisplayKeyNames: keysInput.KeyNames(),
		}
		shortcuts[execInfo.Filepath()] = &v
		addListItem(listContainer, &v, false)
		w.Canvas().Overlays().Remove(p)
	}
}

func addListItem(c *fyne.Container, v *shortcut, registered bool) {
	itemName := v.ExecInfo.DisplayName
	if !registered {
		itemName += "*"
	}

	name := widget.NewLabel(itemName)
	i := widget.NewIcon(helpers.EmptyIcon())
	iconContainer := container.New(helpers.NewIconLayout(), i)
	iconContainer.Hide()
	nameWithIcon := container.NewHBox(iconContainer, name)

	_, icon, _, _ := open.EvalWithIcon(v.ExecInfo)
	if icon != nil {
		i.SetResource(fyne.NewStaticResource(v.ExecInfo.DisplayName, icon))
		iconContainer.Show()
	}

	var item *fyne.Container
	item = container.NewGridWithColumns(3,
		nameWithIcon,
		widget.NewLabel(v.DisplayKeyNames),
		widget.NewButtonWithIcon("Remove", theme.ContentClearIcon(), func() {
			c.Remove(item)
			delete(shortcuts, v.ExecInfo.Filepath())
			if v.unregister != nil {
				v.unregister()
			}
			Save()
		}),
	)

	c.Add(item)

	err := Save()
	if err != nil {
		fmt.Println(err.Error())
	}
}
