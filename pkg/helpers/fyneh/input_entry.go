package fyneh

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/widget"
)

type InputEntry struct {
	widget.Entry
	OnEsc      func()
	OnTypedKey func(ke *fyne.KeyEvent) bool
}

func (e *InputEntry) TypedKey(key *fyne.KeyEvent) {
	if key.Name == fyne.KeyEscape && e.OnEsc != nil {
		e.OnEsc()
		return
	}

	if e.OnTypedKey != nil && e.OnTypedKey(key) {
		return
	}

	e.Entry.TypedKey(key)
}
