package exec

import (
	"encoding/csv"
	"fmt"
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
		c = getExecCommand(e.Command)
		if c == nil {
			return
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

func getExecCommand(command string) *exec.Cmd {
	r := csv.NewReader(strings.NewReader(command))
	r.Comma = ' '
	commandArgs, err := r.Read()
	if err != nil {
		fmt.Println(err.Error())
		return nil
	}

	if len(commandArgs) > 1 {
		return exec.Command(commandArgs[0], commandArgs[1:]...)
	}

	return exec.Command(command)
}
