package exec

import (
	"os/exec"
)

func procAttr(c *exec.Cmd) {
}

func preExec(c *exec.Cmd, e *Info) bool {
	return true
}
