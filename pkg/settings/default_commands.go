package settings

import (
	"strconv"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/theme"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/tools/b64"
)

const maxNameLen = 15

var (
	defaultCommands map[string]*shortcut
)

func init() {
	optionKey := "Alt"
	if helpers.IsDarwin {
		optionKey = "Option"
	}

	commandRunner := "Command Runner"
	commands := []*shortcut{
		{
			Command: &Command{
				ID:   commandRunner,
				Name: commandRunner,
				icon: func() []byte { return theme.RadioButtonCheckedIcon().Content() },
				run:  func() { global.AppWindow.Show() },
			},
			KeyNames:        []fyne.KeyName{desktop.KeyAltLeft, fyne.KeySpace},
			DisplayKeyNames: optionKey + "+Space",
		},
		{
			Command: &Command{
				ID:   "Open " + WindowName,
				Name: "Open " + WindowName,
				icon: func() []byte { return theme.SettingsIcon().Content() },
				run:  func() { Show() },
			},
		},
		{
			Command: &Command{
				ID:   b64.WindowName,
				Name: b64.WindowName,
				icon: func() []byte { return theme.StorageIcon().Content() },
				run:  func() { b64.Show() },
			},
		},
	}

	defaultCommands = make(map[string]*shortcut, len(commands))
	for i, v := range commands {
		v.Command.ID = strconv.Itoa(i) + ". " + v.Command.ID

		if len(v.Command.Name) > maxNameLen {
			v.Command.Name = v.Command.Name[:int(maxNameLen)] + "..."
		}

		defaultCommands[v.Command.ID] = v
	}
}
