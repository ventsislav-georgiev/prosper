package fyneh

import "fyne.io/fyne/v2"

type fixedLayout struct {
	minSize fyne.Size
	offsetX float32
	offsetY float32
}

func (c *fixedLayout) MinSize(objects []fyne.CanvasObject) fyne.Size {
	return c.minSize
}

func (c *fixedLayout) Layout(objects []fyne.CanvasObject, containerSize fyne.Size) {
	o := objects[0]
	o.Resize(c.minSize)
	o.Move(fyne.NewPos(c.offsetX, c.offsetY))
}

func NewFixedLayout(size fyne.Size, offsetX float32, offsetY float32) fyne.Layout {
	return &fixedLayout{size, offsetX, offsetY}
}
