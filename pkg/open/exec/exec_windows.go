package exec

import (
	"os/exec"
	"syscall"
)

func setAttr(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}
