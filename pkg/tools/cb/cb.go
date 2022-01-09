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
	"github.com/sahilm/fuzzy"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/fyneh"
	"golang.design/x/clipboard"
)

const (
	WindowName    = "Clipboard History"
	histViewCount = 10
	linesPerClip  = 1
	maxHistory    = 1000
)

var (
	lruCache    *lru.Cache
	cell        *canvas.Text
	numbersSize fyne.Size
	clipSize    fyne.Size
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

	if cell == nil {
		cell = canvas.NewText("M", color.White)
		cell.TextStyle.Monospace = true
		height := cell.MinSize().Height*linesPerClip + 3
		numbersSize = fyne.Size{Width: 0, Height: height}
		clipSize = fyne.Size{Width: 400, Height: height}
	}

	var cbHistory clipHistory
	if lruCache != nil {
		cbHistory = lruCache.Keys()
		for i, j := 0, len(cbHistory)-1; i < j; i, j = i+1, j-1 {
			cbHistory[i], cbHistory[j] = cbHistory[j], cbHistory[i]
		}
	} else {
		cbHistory = make([]interface{}, 0)
	}

	close := func() {
		onClose()
		w.Close()
	}

	var results []string
	copyAndClose := func(i int) bool {
		if i >= len(results) || results[i] == "" {
			return false
		}

		go close()
		h := results[i]
		clipboard.Write(clipboard.FmtText, []byte(h))
		return true
	}

	onTypedKey := func(k *fyne.KeyEvent) bool {
		if k.Name == fyne.KeyEscape {
			go close()
			return true
		}

		i, err := strconv.Atoi(string(k.Name))
		if err != nil {
			return false
		}
		i--
		if i == -1 {
			i = 9
		}
		return copyAndClose(i)
	}

	w.Canvas().SetOnTypedKey(func(ke *fyne.KeyEvent) { onTypedKey(ke) })
	w.SetCloseIntercept(func() {
		onClose()
		w.Close()
	})

	filter := &fyneh.InputEntry{}
	filter.ExtendBaseWidget(filter)
	filter.SetPlaceHolder("Filter...")
	filter.OnEsc = close
	filter.OnSubmitted = func(s string) {
		filter.SetText("")
	}

	list := container.NewVBox()
	history := cbHistory
	if len(cbHistory) > histViewCount {
		history = cbHistory[:histViewCount-1]
	}

	lruResults := make([]string, histViewCount)
	for i := range lruResults {
		if i < len(history) {
			lruResults[i] = history[i].(string)
		} else {
			lruResults[i] = ""
		}
	}
	results = lruResults
	populateList(lruResults, list, copyAndClose)

	filter.OnChanged = func(s string) {
		matches := fuzzy.Find(s, cbHistory.Strings(histViewCount))
		if len(matches) == 0 {
			results = lruResults
		} else {
			results = make([]string, histViewCount)
			for i := range results {
				if i < len(matches) {
					results[i] = matches[i].Str
				} else {
					results[i] = ""
				}
			}
		}

		objectsCopy := make([]fyne.CanvasObject, len(list.Objects))
		objectsCopy = append(objectsCopy, list.Objects...)
		for _, v := range objectsCopy {
			list.Remove(v)
		}

		populateList(results, list, copyAndClose)
	}

	w.SetContent(container.NewBorder(nil, filter, nil, nil, list))
	w.Resize(fyne.Size{Width: 0, Height: clipSize.Height * 13})
	w.Show()
	w.SetFixedSize(true)
}

func populateList(history []string, list *fyne.Container, copyAndClose func(i int) bool) {
	newLabel := func(t string) *widget.Label {
		w := widget.NewLabel(t)
		w.TextStyle.Monospace = true
		w.Wrapping = fyne.TextWrapBreak
		return w
	}

	for i, v := range history {
		n := ""
		if i < histViewCount {
			if i < histViewCount-1 {
				n = strconv.Itoa(i + 1)
			} else {
				n = "0"
			}
		}

		indexContainer := container.New(fyneh.NewFixedLayout(numbersSize, -9, -9), newLabel(n))

		var clip string
		if v != "" {
			clip = strings.TrimLeft(dedent.Dedent(v), "\n")
		}

		clipContainer := fyneh.NewFixedContainer(newLabel(clip), 10, -7)
		clipContainer.SetMinSize(clipSize)
		clipContainer.OnTapped = func(i int) func() {
			return func() {
				copyAndClose(i)
			}
		}(i)

		item := container.NewBorder(nil, nil,
			indexContainer,
			nil,
			clipContainer,
		)

		list.Add(item)
	}
}

type clipHistory []interface{}

func (h *clipHistory) Strings(l int) []string {
	f := make([]string, 0, l)
	for i, v := range *h {
		if i == l {
			break
		}
		f = append(f, v.(string))
	}
	return f
}
