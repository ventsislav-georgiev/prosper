package exec

import (
	"os/exec"
	"path/filepath"
	"runtime"
)

type Info struct {
	DisplayName string
	Filename    string
	Path        string
}

func (e *Info) Exec() {
	var c *exec.Cmd
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

	if preExec(c, e) {
		c.Start()
	}
}

func (e *Info) Filepath() string {
	return filepath.Join(e.Path, e.Filename)
}
