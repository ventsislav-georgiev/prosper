package exec

import (
	"os/exec"
)

func preExec(c *exec.Cmd, e *Info) bool {
	return true
}
