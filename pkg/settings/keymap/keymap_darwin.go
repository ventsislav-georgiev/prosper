package keymap

import (
	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/driver/desktop"
	"github.com/go-gl/glfw/v3.3/glfw"
)

var KeyNameGLFWCodeMap = map[fyne.KeyName]glfw.Key{
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
