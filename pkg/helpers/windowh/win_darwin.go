package windowh

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Cocoa -framework Carbon
void hideApp();
*/
import "C"

func HideApp() {
	C.hideApp()
}
