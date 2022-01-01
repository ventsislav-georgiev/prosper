package core

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/widget"
)

type exprEntry struct {
	widget.Entry
	OnEsc func()
}

func (e *exprEntry) TypedKey(key *fyne.KeyEvent) {
	if key.Name == fyne.KeyEscape && e.OnEsc != nil {
		e.OnEsc()
		return
	}

	e.Entry.TypedKey(key)
}
