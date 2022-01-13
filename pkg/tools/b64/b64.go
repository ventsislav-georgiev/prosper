package b64

import (
	"encoding/base64"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/fyneh"
)

const (
	WindowName = "Base64 Encode/Decode"
)

func Show() {
	w, onClose, _ := global.NewWindow(WindowName, nil)
	if w == nil {
		return
	}
	w.CenterOnScreen()

	close := func() {
		onClose()
		w.Close()
	}

	encode := fyneh.InputEntry{}
	encode.MultiLine = true
	encode.Wrapping = fyne.TextWrapBreak
	encode.OnEsc = close
	encode.ExtendBaseWidget(&encode)
	encodeC := container.NewHScroll(&encode)
	encodeC.SetMinSize(fyne.NewSize(0, 150))

	decode := fyneh.InputEntry{}
	decode.MultiLine = true
	decode.OnEsc = close
	decode.Wrapping = fyne.TextWrapBreak
	decode.ExtendBaseWidget(&decode)
	decodeC := container.NewHScroll(&decode)
	decodeC.SetMinSize(fyne.NewSize(0, 150))

	encode.OnChanged = getOnEncodeChanged(&decode)
	decode.OnChanged = getOnDecodeChanged(&encode)

	w.SetContent(container.NewHSplit(encodeC, decodeC))
	w.Resize(fyne.Size{Width: 650, Height: 150})
	w.Show()
}

func getOnEncodeChanged(decode *fyneh.InputEntry) func(s string) {
	return func(s string) {
		r := base64.StdEncoding.EncodeToString([]byte(s))
		h := decode.OnChanged
		decode.OnChanged = nil
		decode.SetText(r)
		decode.OnChanged = h
	}
}

func getOnDecodeChanged(encode *fyneh.InputEntry) func(s string) {
	return func(s string) {
		r, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			r = []byte(err.Error())
		}
		h := encode.OnChanged
		encode.OnChanged = nil
		encode.SetText(string(r))
		encode.OnChanged = h
	}
}
