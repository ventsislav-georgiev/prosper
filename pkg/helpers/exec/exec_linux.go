package exec

import (
	"fmt"
	"os/exec"

	"fyne.io/fyne/v2"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
)

var (
	gnome    = "gtk-launch"
	kde      = "kioclient"
	hasGnome = false
	hasKDE   = false
	checked  = false
)

func init() {
	checkForLauncher()
}

func procAttr(c *exec.Cmd) {
}

func preExec(c *exec.Cmd, e *Info) bool {
	if !checked {
		checkForLauncher()
	}

	if !hasGnome && !hasKDE {
		global.App.SendNotification(fyne.NewNotification(
			"Missing app laucher",
			fmt.Sprintf("Either %s or %s is required for running apps.", gnome, kde)))
		checked = false
		return false
	}

	if hasGnome {
		c.Path = gnome
		c.Args = []string{gnome, e.Filename}
	} else {
		c.Path = kde
		c.Args = []string{kde, "exec", e.Filepath()}
	}

	lp, err := exec.LookPath(c.Path)
	if err == nil {
		c.Path = lp
	}

	return true
}

func checkForLauncher() {
	_, err := exec.Command(gnome, "--help").Output()
	if err == nil {
		hasGnome = true
		checked = true
		return
	}

	_, err = exec.Command(kde).Output()
	if err == nil {
		hasKDE = true
		checked = true
		return
	}
}
