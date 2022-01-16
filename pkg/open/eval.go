package open

import (
	"fmt"
	"strings"

	"github.com/sahilm/fuzzy"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers/exec"
	"github.com/ventsislav-georgiev/prosper/pkg/open/apps"
)

var (
	appsList = apps.NewAppsList()
)

func Eval(expr string) (s string, icon []byte, onEnter func(), err error) {
	if !strings.HasPrefix(expr, "o ") {
		return "", nil, nil, helpers.ErrSkip
	}

	if len(expr) == 2 {
		appsList.Reinit()
		return "", nil, nil, helpers.ErrEmpty
	}

	name := strings.ToLower(expr[2:])

	app, err := FindApp(name)
	if err != nil {
		return app.DisplayName, nil, onEnter, helpers.ErrEmpty
	}

	return EvalApp(app)
}

func FindApp(name string) (a exec.Info, err error) {
	if appsList.Len() == 0 {
		appsList.Set(apps.Find())
	}

	if appsList.Len() == 0 {
		return exec.Info{}, helpers.ErrEmpty
	}

	matches := fuzzy.FindFrom(name, appsList.Fuzzy())
	if len(matches) == 0 {
		return exec.Info{}, helpers.ErrEmpty
	}

	app := appsList.Get(matches[0].Index)

	return app, nil
}

func EvalApp(app exec.Info) (s string, icon []byte, onEnter func(), err error) {
	onEnter = func() {
		app.Exec()
	}

	icon, err = apps.ExtractIcon(app)

	if err != nil {
		fmt.Println(err.Error())
		err = nil
	}

	return app.DisplayName, icon, onEnter, err
}
