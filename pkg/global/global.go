package global

import (
	"fyne.io/fyne/v2"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

var AppInstance fyne.App
var AppWindow fyne.GLFWWindow
var Quit func()
var OnClose = helpers.NewConcurrentSliceWithFuncs()
var NewWindow = func(windowName string) fyne.GLFWWindow {
	w := AppInstance.NewWindow(windowName).(fyne.GLFWWindow)
	w.Canvas().SetOnTypedKey(func(k *fyne.KeyEvent) {
		if k.Name == fyne.KeyEscape {
			w.Close()
			AppWindow.Show()
		}
	})
	return w
}
