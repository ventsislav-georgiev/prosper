package cb

import (
	"context"
	"fmt"
	"image/color"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	lru "github.com/hashicorp/golang-lru"
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
			if strings.TrimSpace(string(data)) == "" {
				continue
			}
			lruCache.Add(string(data), nil)
		}
	}()
}

func Show() {
	w, onClose, _, existing, bag := global.NewWindow(WindowName, nil, false)
	if existing {
		bag["updateSelection"].(func(int))(1)
		return
	}
	w.CenterOnScreen()

	if cell == nil {
		cell = canvas.NewText("M", color.White)
		cell.TextStyle.Monospace = true
		height := cell.MinSize().Height * linesPerClip
		numbersSize = fyne.Size{Width: 0, Height: height}
		clipSize = fyne.Size{Width: 450, Height: height}
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

	quit := make(chan struct{})
	close := func() {
		quit <- struct{}{}
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

	onTypedKey := func(k *fyne.KeyEvent, i int) bool {
		if k == nil || k.Name != fyne.KeyEscape {
			return false
		}

		go close()
		return true
	}

	w.Canvas().SetOnTypedKey(func(ke *fyne.KeyEvent) { onTypedKey(ke, 0) })
	w.SetCloseIntercept(close)

	list := container.NewVBox()
	selection := 0
	updateSelection := func(direction int) {
		selection += direction
		if selection == 10 {
			selection = 0
		}
		if selection < 0 {
			lastIndex := len(results) - 1
			for i := lastIndex; i >= 0; i-- {
				selection = i
				if results[selection] != "" {
					break
				}
			}
		}
		if results[selection] == "" {
			selection = 0
		}
		list.Objects = make([]fyne.CanvasObject, 0, histViewCount)
		populateList(results, list, copyAndClose, selection)
	}
	bag["updateSelection"] = updateSelection

	filter := &fyneh.InputEntry{}
	filter.ExtendBaseWidget(filter)
	filter.SetPlaceHolder("Filter...")
	filter.OnEsc = close
	filter.OnSubmitted = func(s string) {
		copyAndClose(selection)
	}
	filter.OnTypedKey = func(ke *fyne.KeyEvent) bool {
		if ke.Name == fyne.KeyUp {
			updateSelection(-1)
			return true
		}
		if ke.Name == fyne.KeyDown {
			updateSelection(1)
			return true
		}
		return false
	}

	history := cbHistory
	if len(cbHistory) > histViewCount {
		history = cbHistory[:histViewCount]
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
	populateList(lruResults, list, copyAndClose, selection)

	onChanged := func(s string) {
		selection = 0
		if s == "" {
			results = lruResults
		} else if len(s) == 1 && s[0] >= 48 && s[0] <= 57 && onTypedKey(nil, int(s[0]-48)) {
			return
		} else {
			matches := fuzzy.Find(s, cbHistory.Strings(len(cbHistory)))
			results = make([]string, histViewCount)
			for i := range results {
				if i < len(matches) {
					results[i] = matches[i].Str
				} else {
					results[i] = ""
				}
			}
		}

		list.Objects = make([]fyne.CanvasObject, 0, histViewCount)
		populateList(results, list, copyAndClose, selection)
	}

	changeCh := make(chan string)
	filter.OnChanged = func(s string) { changeCh <- s }
	go func() {
		for {
			select {
			case s := <-changeCh:
				onChanged(s)
			case <-quit:
				return
			}
		}
	}()

	w.SetContent(container.NewBorder(nil, filter, nil, nil, list))
	w.Resize(fyne.Size{Width: 0, Height: clipSize.Height * 13})
	w.Show()
	w.Canvas().Focus(filter)
	w.SetFixedSize(true)
}

var (
	clipStyle = widget.RichTextStyle{
		ColorName: theme.ColorNamePlaceHolder,
		Inline:    false,
		SizeName:  theme.SizeNameCaptionText,
		TextStyle: fyne.TextStyle{Monospace: true},
	}
	selectedClipStyle = widget.RichTextStyle{
		ColorName: theme.ColorNameForeground,
		Inline:    false,
		SizeName:  theme.SizeNameCaptionText,
		TextStyle: fyne.TextStyle{Monospace: true},
	}
)

func populateList(history []string, list *fyne.Container, copyAndClose func(i int) bool, selection int) {
	newLabel := func(t string, style widget.RichTextStyle) *widget.RichText {
		w := widget.NewRichText(&widget.TextSegment{
			Text:  t,
			Style: style,
		})
		w.Wrapping = fyne.TextTruncate
		return w
	}

	var elementsOffset float32 = -9

	for i, v := range history {
		cstyle := clipStyle
		if i == selection {
			cstyle = selectedClipStyle
		}

		var clip string
		if v != "" {
			lines := strings.Split(v, "\n")
			for i, l := range lines {
				lines[i] = strings.TrimSpace(l)
			}
			clip = strings.Join(lines, "↵")
		}

		clipContainer := fyneh.NewFixedContainer(newLabel(clip, cstyle), 0, elementsOffset)
		clipContainer.SetMinSize(clipSize)
		clipContainer.OnTapped = func(i int) func() {
			return func() {
				copyAndClose(i)
			}
		}(i)

		list.Add(clipContainer)
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
