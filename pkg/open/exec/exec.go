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
	switch runtime.GOOS {
	case "darwin":
		c := exec.Command("open", e.Filepath())
		setAttr(c)
		c.Start()
	case "windows":
		c := exec.Command("cmd", "/c", e.Filepath())
		setAttr(c)
		c.Start()
	}
}

func (e *Info) Filepath() string {
	return filepath.Join(e.Path, e.Filename)
}
