package exec

import (
	"os/exec"
	"syscall"
)

func procAttr(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}

func preExec(c *exec.Cmd, e *Info) bool {
	return true
}
