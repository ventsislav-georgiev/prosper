package helpers

import "runtime"

var IsDarwin = runtime.GOOS == "darwin"
var IsWindows = runtime.GOOS == "windows"
var IsLinux = runtime.GOOS == "linux"
