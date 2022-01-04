package keymap

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/hotkeyh"
	"golang.design/x/hotkey"
)

var (
	mod = []fyne.KeyName{desktop.KeyAltLeft, desktop.KeyAltRight, desktop.KeyShiftLeft, desktop.KeyShiftRight, desktop.KeyControlLeft, desktop.KeyControlRight, desktop.KeySuperLeft, desktop.KeySuperRight}
)

func IsModifier(key fyne.KeyName) bool {
	for _, v := range mod {
		if v == key {
			return true
		}
	}

	return false
}

var KeyNameModMap = map[fyne.KeyName]hotkey.Modifier{
	desktop.KeyAltLeft:      hotkeyh.ModOption,
	desktop.KeyAltRight:     hotkeyh.ModOption,
	desktop.KeyShiftLeft:    hotkey.ModShift,
	desktop.KeyShiftRight:   hotkey.ModShift,
	desktop.KeyControlLeft:  hotkey.ModCtrl,
	desktop.KeyControlRight: hotkey.ModCtrl,
	desktop.KeySuperLeft:    hotkeyh.ModCmd,
	desktop.KeySuperRight:   hotkeyh.ModCmd,
}
