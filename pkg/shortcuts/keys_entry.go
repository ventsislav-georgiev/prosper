package shortcuts

import (
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/widget"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

type keysEntry struct {
	widget.Entry
	keyNames []fyne.KeyName
}

func (e *keysEntry) KeyNames() string {
	keyNames := make([]string, 0)
	for _, k := range e.keyNames {
		keyName := string(k)
		if mod.contains(k) {
			keyName = strings.ReplaceAll(keyName, "Left", "")
			keyName = strings.ReplaceAll(keyName, "Right", "")
			keyName = strings.ReplaceAll(keyName, "Super", "Cmd")
		}

		if helpers.IsDarwin {
			keyName = strings.ReplaceAll(keyName, "Alt", "Option")
		}

		keyNames = append(keyNames, keyName)
	}
	return strings.Join(keyNames, "+")
}

func (e *keysEntry) TypedKey(key *fyne.KeyEvent) {
	ismod := mod.contains(key.Name)

	if key.Name == fyne.KeyReturn {
		e.Entry.TypedKey(key)
		return
	}

	if key.Name == fyne.KeyBackspace || len(e.keyNames) == 3 {
		e.SetText("")
		e.keyNames = make([]fyne.KeyName, 0)
		return
	}

	if len(e.keyNames) == 2 && ismod {
		e.SetText("")
		e.keyNames = make([]fyne.KeyName, 0)
	}

	if len(e.keyNames) == 0 && !ismod {
		return
	}

	if !ismod {
		if helpers.IsWindows {
			if _, ok := keyNameWindowVKCodeMap[key.Name]; !ok {
				return
			}
		} else {
			if _, ok := keyNameGLFWCodeMap[key.Name]; !ok {
				return
			}
		}
	}

	e.keyNames = append(e.keyNames, key.Name)

	e.SetText(e.KeyNames())
}

func (e *keysEntry) TypedRune(r rune)                     {}
func (e *keysEntry) TypedShortcut(shortcut fyne.Shortcut) {}
