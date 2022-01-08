package main

import (
	_ "embed"
	"flag"
	"os"

	"github.com/pkg/profile"
	"github.com/ventsislav-georgiev/prosper/pkg/core"
)

//go:embed icon.png
var icon []byte

func main() {
	if prof := profileIfRequested(); prof != nil {
		defer prof()
	}

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
