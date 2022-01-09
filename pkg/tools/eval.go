package tools

import (
	"strings"

	"fyne.io/fyne/v2/theme"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/tools/b64"
	"github.com/ventsislav-georgiev/prosper/pkg/tools/cb"
)

var (
	toolsIcon = func() []byte { return theme.StorageIcon().Content() }
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	if !strings.HasPrefix(expr, "t ") {
		return "", nil, nil, helpers.ErrSkip
	}

	expr = strings.TrimSpace(expr[2:])
	switch strings.ToLower(expr) {
	case "base64":
		return b64.WindowName, toolsIcon(), b64.Show, nil
	case "clipboard":
		return cb.WindowName, toolsIcon(), cb.Show, nil
	}

	return "", nil, nil, nil
}
