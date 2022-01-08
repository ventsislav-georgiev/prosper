package command

import (
	"strings"

	"fyne.io/fyne/v2/theme"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/settings"
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	if !strings.HasPrefix(expr, ":") {
		return "", nil, nil, helpers.ErrSkip
	}

	expr = strings.TrimSpace(expr)
	if len(expr) > 2 {
		return "", nil, nil, nil
	}

	switch strings.ToLower(expr) {
	case ":q":
		return "Quit", theme.LogoutIcon().Content(), func() { global.Quit() }, nil
	case ":s":
		return "Settings", theme.SettingsIcon().Content(), func() { settings.Show() }, nil
	}

	return "", nil, nil, nil
}
