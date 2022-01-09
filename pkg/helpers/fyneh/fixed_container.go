package fyneh

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/widget"
)

type BaseRenderer struct {
	objects []fyne.CanvasObject
}

func NewBaseRenderer(objects []fyne.CanvasObject) BaseRenderer {
	return BaseRenderer{objects}
}
func (r *BaseRenderer) Destroy() {
}
func (r *BaseRenderer) Objects() []fyne.CanvasObject {
	return r.objects
}
func (r *BaseRenderer) SetObjects(objects []fyne.CanvasObject) {
	r.objects = objects
}

type fixedContainerRenderer struct {
	BaseRenderer
	fixedContainer FixedContainer
	oldMinSize     fyne.Size
}

func (r *fixedContainerRenderer) Layout(size fyne.Size) {
	c := r.fixedContainer.Content
	c.Resize(c.MinSize().Max(size))
	r.updatePosition()
}

func (r *fixedContainerRenderer) MinSize() fyne.Size {
	return r.fixedContainer.MinSize()
}

func (r *fixedContainerRenderer) Refresh() {
	if len(r.BaseRenderer.Objects()) == 0 || r.BaseRenderer.Objects()[0] != r.fixedContainer.Content {
		r.BaseRenderer.Objects()[0] = r.fixedContainer.Content
	}
	if r.oldMinSize == r.fixedContainer.Content.MinSize() && r.oldMinSize == r.fixedContainer.Content.Size() &&
		(r.fixedContainer.Size().Width <= r.oldMinSize.Width && r.fixedContainer.Size().Height <= r.oldMinSize.Height) {
		r.updatePosition()
		return
	}

	r.oldMinSize = r.fixedContainer.Content.MinSize()
	r.Layout(r.fixedContainer.Size())
}

func (r *fixedContainerRenderer) updatePosition() {
	if r.fixedContainer.Content == nil {
		return
	}
	r.fixedContainer.Content.Move(fyne.NewPos(r.fixedContainer.offset.X, r.fixedContainer.offset.Y))
}

type FixedContainer struct {
	widget.BaseWidget
	minSize fyne.Size
	offset  fyne.Position

	Content  fyne.CanvasObject
	OnTapped func()
}

func NewFixedContainer(content fyne.CanvasObject, offsetX float32, offsetY float32) *FixedContainer {
	f := &FixedContainer{Content: content, offset: fyne.NewPos(offsetX, offsetY)}
	f.ExtendBaseWidget(f)
	return f
}

func (f *FixedContainer) CreateRenderer() fyne.WidgetRenderer {
	r := &fixedContainerRenderer{
		BaseRenderer:   NewBaseRenderer([]fyne.CanvasObject{f.Content}),
		fixedContainer: *f,
	}
	r.SetObjects(r.Objects())
	r.updatePosition()
	return r
}

func (*FixedContainer) Scrolled(ev *fyne.ScrollEvent) {}
func (*FixedContainer) DragEnd()                      {}
func (*FixedContainer) Dragged(e *fyne.DragEvent)     {}

func (f *FixedContainer) Tapped(*fyne.PointEvent) {
	if f.OnTapped != nil {
		f.OnTapped()
	}
}

func (f *FixedContainer) MinSize() fyne.Size {
	min := fyne.NewSize(float32(0), float32(0)).Max(f.minSize)
	min.Width = fyne.Max(min.Width, f.Content.MinSize().Width)
	return min
}

func (f *FixedContainer) SetMinSize(size fyne.Size) {
	f.minSize = size
}

func (f *FixedContainer) Refresh() {
	f.BaseWidget.Refresh()
}

func (f *FixedContainer) Resize(sz fyne.Size) {
	if sz == f.Size() {
		return
	}

	f.BaseWidget.Resize(sz)
	f.Refresh()
}
