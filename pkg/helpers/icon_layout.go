package helpers

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/theme"
)

type iconLayout struct{}

func (l *iconLayout) Layout(objects []fyne.CanvasObject, size fyne.Size) {
	pos := fyne.NewPos(theme.Padding(), 0)
	siz := fyne.NewSize(size.Width, size.Height)
	for _, child := range objects {
		child.Resize(siz)
		child.Move(pos)
	}
}

func (l *iconLayout) MinSize(objects []fyne.CanvasObject) (min fyne.Size) {
	for _, child := range objects {
		if !child.Visible() {
			continue
		}

		min = min.Max(child.MinSize())
	}
	min = min.Add(fyne.NewSize(2*theme.Padding(), 2*theme.Padding()))
	return
}

func NewIconLayout() fyne.Layout {
	return &iconLayout{}
}
