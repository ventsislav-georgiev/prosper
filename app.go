package main

import (
	_ "embed"
	"flag"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/jpillora/overseer"
	"github.com/jpillora/overseer/fetcher"
	"github.com/pkg/profile"
	"github.com/ventsislav-georgiev/prosper/pkg/core"
	"github.com/ventsislav-georgiev/prosper/pkg/global"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
)

//go:embed icon.png
var icon []byte

func main() {
	overseer.Run(overseer.Config{
		Program: app,
		Address: "localhost:13003",
		Fetcher: &fetcher.Github{
			User:     "ventsislav-georgiev",
			Repo:     "prosper",
			Interval: 15 * time.Minute,
			Asset: func(filename string) bool {
				binName := "bin-" + runtime.GOOS
				if helpers.IsDarwin {
					binName += "-" + runtime.GOARCH
				}
				return strings.HasPrefix(filename, binName)
			},
		},
	})
}

func app(state overseer.State) {
	if prof := profileIfRequested(); prof != nil {
		defer prof()
	}

	go func() {
		<-state.GracefulShutdown
		global.Quit()
	}()

	core.Run(icon)
}

func profileIfRequested() func() {
	prof := flag.String("profile", "", "enable profiling (cpu, mem, trace)")
	flag.CommandLine.Parse(os.Args[1:])

	var profileFunc func(p *profile.Profile) = nil
	switch *prof {
	case "cpu":
		profileFunc = profile.CPUProfile
	case "mem":
		profileFunc = profile.MemProfileRate(1)
	case "trace":
		profileFunc = profile.TraceProfile
	}

	if profileFunc == nil {
		return nil
	}

	return profile.Start(profileFunc, profile.ProfilePath(".")).Stop
}
