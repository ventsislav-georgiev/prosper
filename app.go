package main

import (
	_ "embed"

	"github.com/ventsislav-georgiev/prosper/pkg/core"
)

//go:embed icon.png
var icon []byte

func main() {
	core.Run(icon)
}
