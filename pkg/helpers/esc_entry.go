package helpers

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/widget"
)

type EscEntry struct {
	widget.Entry
	OnEsc func()
}

func (e *EscEntry) TypedKey(key *fyne.KeyEvent) {
	if key.Name == fyne.KeyEscape && e.OnEsc != nil {
		e.OnEsc()
		return
	}

	e.Entry.TypedKey(key)
}
