package open

import (
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/sahilm/fuzzy"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/open/exec"
)

var (
	homeDir string
	apps    = newAppsList()
)

func init() {
	homeDir, _ = os.UserHomeDir()
}

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	if !strings.HasPrefix(expr, "o ") {
		return "", nil, nil, helpers.ErrSkip
	}

	if len(expr) == 2 {
		apps.reinit()
		return "", nil, nil, helpers.ErrEmpty
	}

	name := strings.ToLower(expr[2:])

	app, err := FindApp(name)
	if err != nil {
		return app.DisplayName, nil, onEnter, nil
	}

	return EvalApp(app)
}

func FindApp(name string) (a exec.Info, err error) {
	if apps.len() == 0 {
		switch runtime.GOOS {
		case "darwin":
			apps.set(findAppsDarwin())
		case "windows":
			apps.set(findAppsWindows())
		}
	}

	if apps.len() == 0 {
		return exec.Info{}, helpers.ErrEmpty
	}

	matches := fuzzy.FindFrom(name, apps.fuzzy())
	if len(matches) == 0 {
		return exec.Info{}, helpers.ErrEmpty
	}

	app := apps.get(matches[0].Index)

	return app, nil
}

func EvalApp(app exec.Info) (s string, icon []byte, onEnter func(), err error) {
	onEnter = func() {
		app.Exec()
	}

	switch runtime.GOOS {
	case "darwin":
		icon, err = extractIconDarwin(app)
	case "windows":
		icon, err = extractIconWindows(app)
	}

	if err != nil {
		fmt.Println(err.Error())
		err = nil
	}

	return app.DisplayName, icon, onEnter, err
}
