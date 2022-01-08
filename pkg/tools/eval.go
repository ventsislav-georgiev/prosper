package tools

import (
	"strings"

	"fyne.io/fyne/v2/theme"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/tools/b64"
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	if !strings.HasPrefix(expr, "t ") {
		return "", nil, nil, helpers.ErrSkip
	}

	expr = strings.TrimSpace(expr[2:])
	switch strings.ToLower(expr) {
	case "base64":
		return "Base64 Encode/Decode", theme.StorageIcon().Content(), func() { b64.Show() }, nil
	}

	return "", nil, nil, nil
}
