package osh

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/settings"
	"golang.design/x/hotkey"
)

func Initialize() {
	hotkey.XSetErrorHandler(func(e hotkey.XErrorEvent) {
		sh := settings.RunnerShortcut
		sh.KeyNames = []fyne.KeyName{desktop.KeyControlLeft, fyne.KeySpace}
		sh.DisplayKeyNames = "Ctrl+Space"
		settings.RegisterShortcut(sh)
		settings.Prefs.Store(sh.ID(), sh)

		hotkey.XSetErrorHandler(func(e hotkey.XErrorEvent) {
			global.App.SendNotification(fyne.NewNotification(
				"Unavailable keys",
				"Choose different key combination."))
		})
	})
}
