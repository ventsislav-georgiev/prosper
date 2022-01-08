package b64

import (
	"encoding/base64"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
)

const (
	WindowName = "Base64 Encode/Decode"
)

func Show() {
	w := global.AppInstance.NewWindow(WindowName).(fyne.GLFWWindow)
	w.CenterOnScreen()

	encode := widget.NewMultiLineEntry()
	encode.Wrapping = fyne.TextWrapBreak
	encodeC := container.NewHScroll(encode)
	encodeC.SetMinSize(fyne.NewSize(300, 150))

	decode := widget.NewMultiLineEntry()
	decode.Wrapping = fyne.TextWrapBreak
	decodeC := container.NewHScroll(decode)
	decodeC.SetMinSize(fyne.NewSize(300, 150))

	encode.OnChanged = getOnEncodeChanged(decode)
	decode.OnChanged = getOnDecodeChanged(encode)

	w.SetContent(container.NewHSplit(encodeC, decodeC))
	w.Show()
	w.SetCloseIntercept(func() {
		w.Close()
		global.AppWindow.Show()
	})
}

func getOnEncodeChanged(decode *widget.Entry) func(s string) {
	return func(s string) {
		r := base64.StdEncoding.EncodeToString([]byte(s))
		h := decode.OnChanged
		decode.OnChanged = nil
		decode.SetText(r)
		decode.OnChanged = h
	}
}

func getOnDecodeChanged(encode *widget.Entry) func(s string) {
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
