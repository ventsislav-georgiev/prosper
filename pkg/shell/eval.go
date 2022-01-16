package shell

import (
	"strings"

	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/exec"
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	if !strings.HasPrefix(expr, "$ ") {
		return "", nil, nil, helpers.ErrSkip
	}

	e := exec.Info{Command: expr[2:]}
	return "Execute command in shell", nil, e.Exec, nil
}
