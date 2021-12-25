package global

import (
	"fyne.io/fyne/v2"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

var AppInstance fyne.App
var AppWindow fyne.GLFWWindow
var Quit func()
var OnClose = helpers.NewConcurrentSliceWithFuncs()
