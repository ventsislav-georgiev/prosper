package hotkeyh

import "golang.design/x/hotkey"

const (
	ModOption = hotkey.Mod1
	ModCmd    = hotkey.Mod4
)

func init() {
	hotkey.XSetErrorHandler(func(e hotkey.XErrorEvent) {})
}
