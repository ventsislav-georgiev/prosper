package cb

import (
	"context"
	"fmt"
	"image/color"
	"strconv"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	lru "github.com/hashicorp/golang-lru"
	"github.com/lithammer/dedent"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/fyneh"
	"golang.design/x/clipboard"
)

const (
	WindowName   = "Clipboard History"
	linesPerClip = 1
	maxHistory   = 1000
)

var (
	lruCache *lru.Cache
)

func init() {
	var err error
	lruCache, err = lru.New(maxHistory)
	if err != nil {
		fmt.Println(err.Error())
		return
	}

	go func() {
		ch := clipboard.Watch(context.Background(), clipboard.FmtText)
		for data := range ch {
			if string(data) == "" {
				continue
			}
			lruCache.Add(string(data), nil)
		}
	}()
}

func Show() {
	w, onClose := global.NewWindow(WindowName, false)
	w.CenterOnScreen()

	var cbHistory []interface{}
	if lruCache != nil {
		cbHistory = lruCache.Keys()
		for i, j := 0, len(cbHistory)-1; i < j; i, j = i+1, j-1 {
			cbHistory[i], cbHistory[j] = cbHistory[j], cbHistory[i]
		}
	} else {
		cbHistory = make([]interface{}, 0)
	}

	cell := canvas.NewText("M", color.White)
	cell.TextStyle.Monospace = true
	height := cell.MinSize().Height*linesPerClip + 3
	numbersSize := fyne.Size{Width: 0, Height: height}
	clipSize := fyne.Size{Width: 400, Height: height}

	newLabel := func() *widget.Label {
		w := widget.NewLabel("")
		w.TextStyle.Monospace = true
		w.Wrapping = fyne.TextWrapBreak
		return w
	}

	list := widget.NewList(
		func() int { return 10 },
		func() fyne.CanvasObject {
			f := fyneh.NewFixedContainer(newLabel(), 10, -7)
			f.SetMinSize(clipSize)
			return container.NewBorder(nil, nil,
				container.New(fyneh.NewFixedLayout(numbersSize, -9, -9), newLabel()),
				nil,
				f,
			)
		},
		func(i int, co fyne.CanvasObject) {
			c1 := co.(*fyne.Container)
			c2 := c1.Objects[1].(*fyne.Container)
			label := c2.Objects[0].(*widget.Label)
			if i < 10 {
				if i < 9 {
					label.SetText(strconv.Itoa(i + 1))
				} else {
					label.SetText("0")
				}
			}

			if i >= len(cbHistory) {
				return
			}

			h := cbHistory[i].(string)
			c3 := c1.Objects[0].(*fyneh.FixedContainer)
			label = c3.Content.(*widget.Label)
			label.SetText(strings.TrimLeft(dedent.Dedent(h), "\n"))
		},
	)

	close := func() {
		onClose()
		w.Close()
	}

	copyAndClose := func(i int) {
		if i >= len(cbHistory) {
			return
		}

		go close()
		h := cbHistory[i].(string)
		clipboard.Write(clipboard.FmtText, []byte(h))
	}

	list.OnSelected = func(id widget.ListItemID) { copyAndClose(id) }

	w.Canvas().SetOnTypedKey(func(k *fyne.KeyEvent) {
		if k.Name == fyne.KeyEscape {
			go close()
			return
		}

		i, err := strconv.Atoi(string(k.Name))
		if err != nil {
			return
		}
		i--
		if i == -1 {
			i = 9
		}
		copyAndClose(i)
	})

	w.SetContent(container.NewVScroll(list))
	w.Resize(fyne.Size{Width: 0, Height: 300})
	w.Show()
}
