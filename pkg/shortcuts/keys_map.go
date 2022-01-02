package shortcuts

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"github.com/go-gl/glfw/v3.3/glfw"
	"github.com/ventsislav-georgiev/prosper/pkg/helpers"
	"golang.design/x/hotkey"
)

var (
	mod = modifiers{desktop.KeyAltLeft, desktop.KeyAltRight, desktop.KeyShiftLeft, desktop.KeyShiftRight, desktop.KeyControlLeft, desktop.KeyControlRight, desktop.KeySuperLeft, desktop.KeySuperRight}
)

type modifiers []fyne.KeyName

func (m *modifiers) contains(key fyne.KeyName) bool {
	for _, v := range *m {
		if v == key {
			return true
		}
	}

	return false
}

var keyNameModMap = map[fyne.KeyName]hotkey.Modifier{
	desktop.KeyAltLeft:      helpers.ModOption,
	desktop.KeyAltRight:     helpers.ModOption,
	desktop.KeyShiftLeft:    hotkey.ModShift,
	desktop.KeyShiftRight:   hotkey.ModShift,
	desktop.KeyControlLeft:  hotkey.ModCtrl,
	desktop.KeyControlRight: hotkey.ModCtrl,
	desktop.KeySuperLeft:    helpers.ModCmd,
	desktop.KeySuperRight:   helpers.ModCmd,
}

var keyNameGLFWCodeMap = map[fyne.KeyName]glfw.Key{
	// non-printable
	fyne.KeyEscape:    glfw.KeyEscape,
	fyne.KeyReturn:    glfw.KeyEnter,
	fyne.KeyTab:       glfw.KeyTab,
	fyne.KeyBackspace: glfw.KeyBackspace,
	fyne.KeyInsert:    glfw.KeyInsert,
	fyne.KeyDelete:    glfw.KeyDelete,
	fyne.KeyRight:     glfw.KeyRight,
	fyne.KeyLeft:      glfw.KeyLeft,
	fyne.KeyDown:      glfw.KeyDown,
	fyne.KeyUp:        glfw.KeyUp,
	fyne.KeyPageUp:    glfw.KeyPageUp,
	fyne.KeyPageDown:  glfw.KeyPageDown,
	fyne.KeyHome:      glfw.KeyHome,
	fyne.KeyEnd:       glfw.KeyEnd,

	fyne.KeySpace: glfw.KeySpace,
	fyne.KeyEnter: glfw.KeyKPEnter,

	// functions
	fyne.KeyF1:  glfw.KeyF1,
	fyne.KeyF2:  glfw.KeyF2,
	fyne.KeyF3:  glfw.KeyF3,
	fyne.KeyF4:  glfw.KeyF4,
	fyne.KeyF5:  glfw.KeyF5,
	fyne.KeyF6:  glfw.KeyF6,
	fyne.KeyF7:  glfw.KeyF7,
	fyne.KeyF8:  glfw.KeyF8,
	fyne.KeyF9:  glfw.KeyF9,
	fyne.KeyF10: glfw.KeyF10,
	fyne.KeyF11: glfw.KeyF11,
	fyne.KeyF12: glfw.KeyF12,

	fyne.Key0: glfw.Key0,
	fyne.Key1: glfw.Key1,
	fyne.Key2: glfw.Key2,
	fyne.Key3: glfw.Key3,
	fyne.Key4: glfw.Key4,
	fyne.Key5: glfw.Key5,
	fyne.Key6: glfw.Key6,
	fyne.Key7: glfw.Key7,
	fyne.Key8: glfw.Key8,
	fyne.Key9: glfw.Key9,

	// desktop
	desktop.KeyPrintScreen: glfw.KeyPrintScreen,
	desktop.KeyCapsLock:    glfw.KeyCapsLock,

	fyne.KeyApostrophe: glfw.KeyApostrophe,
	fyne.KeyComma:      glfw.KeyComma,
	fyne.KeyMinus:      glfw.KeyMinus,
	fyne.KeyPeriod:     glfw.KeyPeriod,
	fyne.KeySlash:      glfw.KeySlash,
	fyne.KeyAsterisk:   glfw.Key8,
	fyne.KeyBackTick:   glfw.KeyGraveAccent,

	fyne.KeySemicolon: glfw.KeySemicolon,
	fyne.KeyPlus:      glfw.KeyEqual,
	fyne.KeyEqual:     glfw.KeyEqual,

	fyne.KeyA: glfw.KeyA,
	fyne.KeyB: glfw.KeyB,
	fyne.KeyC: glfw.KeyC,
	fyne.KeyD: glfw.KeyD,
	fyne.KeyE: glfw.KeyE,
	fyne.KeyF: glfw.KeyF,
	fyne.KeyG: glfw.KeyG,
	fyne.KeyH: glfw.KeyH,
	fyne.KeyI: glfw.KeyI,
	fyne.KeyJ: glfw.KeyJ,
	fyne.KeyK: glfw.KeyK,
	fyne.KeyL: glfw.KeyL,
	fyne.KeyM: glfw.KeyM,
	fyne.KeyN: glfw.KeyN,
	fyne.KeyO: glfw.KeyO,
	fyne.KeyP: glfw.KeyP,
	fyne.KeyQ: glfw.KeyQ,
	fyne.KeyR: glfw.KeyR,
	fyne.KeyS: glfw.KeyS,
	fyne.KeyT: glfw.KeyT,
	fyne.KeyU: glfw.KeyU,
	fyne.KeyV: glfw.KeyV,
	fyne.KeyW: glfw.KeyW,
	fyne.KeyX: glfw.KeyX,
	fyne.KeyY: glfw.KeyY,
	fyne.KeyZ: glfw.KeyZ,

	fyne.KeyLeftBracket:  glfw.KeyLeftBracket,
	fyne.KeyBackslash:    glfw.KeyBackslash,
	fyne.KeyRightBracket: glfw.KeyRightBracket,
}

var keyNameWindowVKCodeMap = map[fyne.KeyName]glfw.Key{
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
	fyne.KeyP: 0x51,
	fyne.KeyQ: 0x52,
	fyne.KeyR: 0x53,
	fyne.KeyS: 0x54,
	fyne.KeyT: 0x55,
	fyne.KeyU: 0x56,
	fyne.KeyV: 0x57,
	fyne.KeyW: 0x58,
	fyne.KeyX: 0x59,
	fyne.KeyY: 0x5A,
	fyne.KeyZ: 0x5B,

	fyne.KeyLeftBracket:  0xDB,
	fyne.KeyBackslash:    0xDC,
	fyne.KeyRightBracket: 0xDD,
}
