package exec

import (
	"os/exec"
	"syscall"
)

func preExec(c *exec.Cmd, e *Info) bool {
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return true
}
