package archh

import (
	"runtime"
	"syscall"
)

var Arch = runtime.GOARCH

func init() {
	r, err := syscall.Sysctl("sysctl.proc_translated")
	if err != nil {
		return
	}

	if r == "\x00\x00\x00" {
		return
	}

	if r == "\x01\x00\x00" {
		Arch = "arm64"
	}
}
