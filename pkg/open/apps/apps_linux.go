package apps

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"

	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
)

func init() {
	homeDir, _ := os.UserHomeDir()
	if homeDir != "" {
		linuxUserAppsPath = filepath.Join(homeDir, ".local/share/applications/")
	}
}

const (
	linuxSysAppsPath  = "/usr/share/applications/"
	linuxSysAppsPath2 = "/usr/local/share/applications/"
)

var (
	linuxUserAppsPath string
)

func Find() FuzzySource {
	apps := findRecursive(linuxSysAppsPath, 0)
	apps = append(apps, findRecursive(linuxSysAppsPath2, 0)...)
	if linuxUserAppsPath != "" {
		apps = append(apps, findRecursive(linuxUserAppsPath, 0)...)
	}
	return apps
}

func findRecursive(dir string, level int) FuzzySource {
	apps := make(FuzzySource, 0)

	entries, err := os.ReadDir(dir)
	if err != nil {
		return apps
	}

	for _, f := range entries {
		if filepath.Ext(f.Name()) == ".desktop" {
			e := exec.Info{
				DisplayName: f.Name(),
				Path:        dir,
				Filename:    f.Name(),
			}
			resolveDisplayName(&e)
			apps = append(apps, e)
		} else if level < 1 && f.IsDir() {
			apps = append(apps, findRecursive(filepath.Join(dir, f.Name()), level+1)...)
		}
	}

	return apps
}

func resolveDisplayName(e *exec.Info) {
	file, err := os.Open(e.Filepath())
	if err != nil {
		return
	}

	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		text := scanner.Text()
		if strings.HasPrefix(text, "Name=") {
			e.DisplayName = text[5:]
			return
		}
	}
}

func ExtractIcon(app exec.Info) (icon []byte, err error) {
	return
}
