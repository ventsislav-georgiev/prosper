package windowh

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Cocoa -framework Carbon
#include <stdint.h>
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
void hideApp();
*/
import "C"

func HideApp() {
	C.hideApp()
}
