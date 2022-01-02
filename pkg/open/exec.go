package open

import (
	"os/exec"
	"path/filepath"
	"runtime"
)

type ExecInfo struct {
	DisplayName string
	Filename    string
	Path        string
}

func (e *ExecInfo) Exec() {
	switch runtime.GOOS {
	case "darwin":
		exec.Command("open", e.Filepath()).Start()
	case "windows":
		exec.Command("cmd", "/c", e.Filepath()).Start()
	}
}

func (e *ExecInfo) Filepath() string {
	return filepath.Join(e.Path, e.Filename)
}
