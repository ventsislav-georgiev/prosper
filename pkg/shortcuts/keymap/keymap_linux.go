package keymap

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"github.com/go-gl/glfw/v3.3/glfw"
)

var KeyNameGLFWCodeMap = map[fyne.KeyName]glfw.Key{
	// non-printable
	fyne.KeyEscape:    0xFF1B,
	fyne.KeyReturn:    0xFF0D,
	fyne.KeyTab:       0xFF09,
	fyne.KeyBackspace: 0xFF08,
	fyne.KeyInsert:    0xFF63,
	fyne.KeyDelete:    0xFFFF,
	fyne.KeyRight:     0xFF53,
	fyne.KeyLeft:      0xFF51,
	fyne.KeyDown:      0xFF54,
	fyne.KeyUp:        0xFF52,
	fyne.KeyPageUp:    0xFF55,
	fyne.KeyPageDown:  0xFF56,
	fyne.KeyHome:      0xFF50,
	fyne.KeyEnd:       0xFF57,

	fyne.KeySpace: 0x020,
	fyne.KeyEnter: 0xFF0D,

	// functions
	fyne.KeyF1:  0xFFBE,
	fyne.KeyF2:  0xFFBF,
	fyne.KeyF3:  0xFFC0,
	fyne.KeyF4:  0xFFC1,
	fyne.KeyF5:  0xFFC2,
	fyne.KeyF6:  0xFFC3,
	fyne.KeyF7:  0xFFC4,
	fyne.KeyF8:  0xFFC5,
	fyne.KeyF9:  0xFFC6,
	fyne.KeyF10: 0xFFC7,
	fyne.KeyF11: 0xFFC8,
	fyne.KeyF12: 0xFFC9,

	fyne.Key0: 0x030,
	fyne.Key1: 0x031,
	fyne.Key2: 0x032,
	fyne.Key3: 0x033,
	fyne.Key4: 0x034,
	fyne.Key5: 0x035,
	fyne.Key6: 0x036,
	fyne.Key7: 0x037,
	fyne.Key8: 0x038,
	fyne.Key9: 0x039,

	// desktop
	desktop.KeyPrintScreen: 0xFF61,
	desktop.KeyCapsLock:    0xFFE5,

	fyne.KeyApostrophe: 0x027,
	fyne.KeyComma:      0x02C,
	fyne.KeyMinus:      0x02D,
	fyne.KeyPeriod:     0x02E,
	fyne.KeySlash:      0x02F,
	fyne.KeyAsterisk:   0x02A,
	fyne.KeyBackTick:   0x07E,

	fyne.KeySemicolon: 0x03B,
	fyne.KeyPlus:      0x02B,
	fyne.KeyEqual:     0x02B,

	fyne.KeyA: 0x041,
	fyne.KeyB: 0x042,
	fyne.KeyC: 0x043,
	fyne.KeyD: 0x044,
	fyne.KeyE: 0x045,
	fyne.KeyF: 0x046,
	fyne.KeyG: 0x047,
	fyne.KeyH: 0x048,
	fyne.KeyI: 0x049,
	fyne.KeyJ: 0x04A,
	fyne.KeyK: 0x04B,
	fyne.KeyL: 0x04C,
	fyne.KeyM: 0x04D,
	fyne.KeyN: 0x04E,
	fyne.KeyO: 0x04F,
	fyne.KeyP: 0x050,
	fyne.KeyQ: 0x051,
	fyne.KeyR: 0x052,
	fyne.KeyS: 0x053,
	fyne.KeyT: 0x054,
	fyne.KeyU: 0x055,
	fyne.KeyV: 0x056,
	fyne.KeyW: 0x057,
	fyne.KeyX: 0x058,
	fyne.KeyY: 0x059,
	fyne.KeyZ: 0x05A,

	fyne.KeyLeftBracket:  0x05B,
	fyne.KeyBackslash:    0x05C,
	fyne.KeyRightBracket: 0x05D,
}
