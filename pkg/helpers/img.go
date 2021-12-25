package helpers

import (
	"bytes"
	"image"
	"image/jpeg"

	"fyne.io/fyne/v2"
)

func EmptyIcon() fyne.Resource {
	img := image.NewGray(image.Rectangle{image.Point{0, 0}, image.Point{0, 0}})
	var buf bytes.Buffer
	jpeg.Encode(&buf, img, nil)
	return fyne.NewStaticResource("empty", buf.Bytes())
}
