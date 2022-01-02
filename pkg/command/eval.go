package command

import (
	"strings"

	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/shortcuts"
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
		return "Quit", nil, func() { global.Quit() }, nil
	case ":s":
		return "Shortcuts", nil, func() { go shortcuts.Edit() }, nil
	}

	return "", nil, nil, nil
}
