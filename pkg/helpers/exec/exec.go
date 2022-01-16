package exec

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

type Info struct {
	DisplayName string
	Filename    string
	Path        string
	IconName    string
	Command     string
}

func (e *Info) Exec() {
	var c *exec.Cmd
	if e.Command != "" {
		parts := strings.Split(e.Command, " ")
		if len(parts) > 1 {
			c = exec.Command(parts[0], parts[1:]...)
		} else {
			c = exec.Command(e.Command)
		}
		procAttr(c)
		c.Start()
		return
	}

	switch runtime.GOOS {
	case "darwin":
		c = exec.Command("open", e.Filepath())
	case "windows":
		c = exec.Command("cmd", "/c", e.Filepath())
	case "linux":
		c = &exec.Cmd{}
	}

	if c == nil {
		return
	}

	if !preExec(c, e) {
		return
	}

	procAttr(c)
	c.Start()
}

func (e *Info) Filepath() string {
	return filepath.Join(e.Path, e.Filename)
}
