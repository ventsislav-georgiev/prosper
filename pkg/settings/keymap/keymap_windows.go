package keymap

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"github.com/go-gl/glfw/v3.3/glfw"
)

var KeyNameGLFWCodeMap = map[fyne.KeyName]glfw.Key{
	// non-printable
	fyne.KeyEscape:    0x18,
	fyne.KeyReturn:    0x0D,
	fyne.KeyTab:       0x09,
	fyne.KeyBackspace: 0x08,
	fyne.KeyInsert:    0x2D,
	fyne.KeyDelete:    0x2E,
	fyne.KeyRight:     0x27,
	fyne.KeyLeft:      0x25,
	fyne.KeyDown:      0x28,
	fyne.KeyUp:        0x26,
	fyne.KeyPageUp:    0x21,
	fyne.KeyPageDown:  0x22,
	fyne.KeyHome:      0x24,
	fyne.KeyEnd:       0x23,

	fyne.KeySpace: 0x20,
	fyne.KeyEnter: 0x0D,

	// functions
	fyne.KeyF1:  0x70,
	fyne.KeyF2:  0x71,
	fyne.KeyF3:  0x72,
	fyne.KeyF4:  0x73,
	fyne.KeyF5:  0x74,
	fyne.KeyF6:  0x75,
	fyne.KeyF7:  0x76,
	fyne.KeyF8:  0x77,
	fyne.KeyF9:  0x78,
	fyne.KeyF10: 0x79,
	fyne.KeyF11: 0x7A,
	fyne.KeyF12: 0x7B,

	fyne.Key0: 0x30,
	fyne.Key1: 0x31,
	fyne.Key2: 0x32,
	fyne.Key3: 0x33,
	fyne.Key4: 0x34,
	fyne.Key5: 0x35,
	fyne.Key6: 0x36,
	fyne.Key7: 0x37,
	fyne.Key8: 0x38,
	fyne.Key9: 0x39,

	// desktop
	desktop.KeyPrintScreen: 0x2C,
	desktop.KeyCapsLock:    0x14,

	fyne.KeyApostrophe: 0xDE,
	fyne.KeyComma:      0xBC,
	fyne.KeyMinus:      0xBD,
	fyne.KeyPeriod:     0xBE,
	fyne.KeySlash:      0xBF,
	fyne.KeyAsterisk:   0x38,
	fyne.KeyBackTick:   0xC0,

	fyne.KeySemicolon: 0xBA,
	fyne.KeyPlus:      0xBB,
	fyne.KeyEqual:     0xBB,

	fyne.KeyA: 0x41,
	fyne.KeyB: 0x42,
	fyne.KeyC: 0x43,
	fyne.KeyD: 0x44,
	fyne.KeyE: 0x45,
	fyne.KeyF: 0x46,
	fyne.KeyG: 0x47,
	fyne.KeyH: 0x48,
	fyne.KeyI: 0x49,
	fyne.KeyJ: 0x4A,
	fyne.KeyK: 0x4B,
	fyne.KeyL: 0x4C,
	fyne.KeyM: 0x4D,
	fyne.KeyN: 0x4E,
	fyne.KeyO: 0x4F,
	fyne.KeyP: 0x50,
	fyne.KeyQ: 0x51,
	fyne.KeyR: 0x52,
	fyne.KeyS: 0x53,
	fyne.KeyT: 0x54,
	fyne.KeyU: 0x55,
	fyne.KeyV: 0x56,
	fyne.KeyW: 0x57,
	fyne.KeyX: 0x58,
	fyne.KeyY: 0x59,
	fyne.KeyZ: 0x5A,

	fyne.KeyLeftBracket:  0xDB,
	fyne.KeyBackslash:    0xDC,
	fyne.KeyRightBracket: 0xDD,
}
