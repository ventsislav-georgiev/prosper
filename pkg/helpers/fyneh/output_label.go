package fyneh

import (
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/data/binding"
	"fyne.io/fyne/v2/widget"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
)

type OutputLabel struct {
	widget.Label
	FullText string
	binder   basicBinder
}

func (l *OutputLabel) TappedSecondary(*fyne.PointEvent) {
	global.AppWindow.Clipboard().SetContent(l.FullText)
}

func (l *OutputLabel) Bind(data binding.String) {
	l.binder.SetCallback(l.updateFromData)
	l.binder.Bind(data)
}

func (l *OutputLabel) Unbind() {
	l.binder.Unbind()
}

func (l *OutputLabel) updateFromData(data binding.DataItem) {
	if data == nil {
		return
	}
	textSource, ok := data.(binding.String)
	if !ok {
		return
	}
	val, err := textSource.Get()
	if err != nil {
		fyne.LogError("Error getting current data value", err)
		return
	}
	l.FullText = val
	if len(val) > maxLen {
		val = val[:int(maxLen)] + "..."
	}
	l.SetText(strings.ReplaceAll(val, "\n", "\\n"))
}
