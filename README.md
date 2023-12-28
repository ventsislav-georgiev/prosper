<img align="left" width="115px" height="115px" src="Icon.png">

# Prosper

<br/>

## Description
Command runner with translation, calc, currency and unit conversion.

Also includes:
* [Global Shortcuts](#global-shortcuts)
* [Clipboard History](#clipboard-history)
* [Base64 Encode/Decode](#base64-encodedecode)
* [Numi Integration](#numi-integration-macos-only)

Supports: Mac, Windows and Linux

<br/>

## Install

### Download pre-built binary (unsigned)
Check releases and download the appropriate `Prosper-$OS-$ARCH` archive for your platfrom.

### macOS ARM

```
wget https://github.com/ventsislav-georgiev/prosper/releases/latest/download/Prosper-darwin-arm64.zip && ditto -x -k Prosper-darwin-arm64.zip ./ && cp -rf Prosper.app /Applications/ && rm -rf Prosper-darwin-arm64.zip; rm -rf Prosper.app
```

### macOS x86

```
wget https://github.com/ventsislav-georgiev/prosper/releases/latest/download/Prosper-darwin-amd64.zip && ditto -x -k Prosper-darwin-amd64.zip ./ && cp -rf Prosper.app /Applications/ && rm -rf Prosper-darwin-amd64.zip; rm -rf Prosper.app
```

### Manual from sources
The app is based on [fyne](https://github.com/fyne-io/fyne).

Follow prerequisites here: https://developer.fyne.io/started/#prerequisites (for Windows I recommend using TDM-GCC)

Then you can install directly from the source code using the Fyne command as follows:
```
go install fyne.io/fyne/v2/cmd/fyne@latest
fyne get github.com/ventsislav-georgiev/prosper
```

<br/>

## Preview
<img width="567" alt="image" src="https://user-images.githubusercontent.com/5616486/147394501-8d2f5a72-b3b7-44c0-bbea-7537fdece378.gif">

Tips:
* Clicking `Enter` in the command runner copies the output to the clipboard
* Using the same shortcut again works as toggle i.e. `Alt+Space` to show runner, again to hide it
* `:s` to see shortcuts and change them
* `:q` Quit the app

<br/>

Example expressions:
* translation `hello world in de` => `hallo welt`

* math `128*24` => `3072`

* currency `32 usd to eur` => `28.02 €`

* unit `1 year to minutes` => `525960 minutes`

* apps `o iTerm` => opens iTerm

* shell `> say "hello world"` => executes command (`say` will read the text aloud on macOS)

<br/>

## Features

### Global Shortcuts
<img width="467" alt="image" src="https://user-images.githubusercontent.com/5616486/149510337-ea9ab644-a194-4482-af80-2be84535eef9.png">

Usage:
* `Alt+\` - toggle
* `Esc` - close
* When adding a shortcut, either enter an app name or a shell command (`> open /Users/ventsislavg`)
<img width="469" alt="image" src="https://user-images.githubusercontent.com/5616486/151606628-5ccd37ad-00f3-405d-9693-8d27bb63d4d4.png">

### Clipboard History
<img width="467" alt="image" src="https://user-images.githubusercontent.com/5616486/149509926-b787e092-e4a0-4af1-8050-9052c12fce32.png">

Usage:
* `Shift+Alt+A` - show window and switch selection
* `Enter` to select the highlighted clip
* `1, 2, 3 .. to 0 keys` - select a clip
* Filter clip by fuzzy search
* `Esc` - close

### Base64 Encode/Decode
<img width="667" alt="image" src="https://user-images.githubusercontent.com/5616486/149510933-a33984b5-e684-4167-bb7d-adc4ef8c4410.png">

Usage:
* `Alt+/` - toggle
* `Esc` - close

### Numi Integration (MacOS only)

If you have [Numi](https://numi.app) installed, running and have enabled the integration API in Numi's setttings:

<img width="220" alt="image" src="https://user-images.githubusercontent.com/5616486/151655468-b72e68d6-4d28-4cbe-81dc-044662fdfd78.png">

<br/>

then `Numi` expressions can be used:

<img width="300" alt="image" src="https://user-images.githubusercontent.com/5616486/151655485-aa186981-5a0b-447d-91aa-08808e928ad1.png">

<img width="300" alt="image" src="https://user-images.githubusercontent.com/5616486/151655512-611f8f46-0782-4144-8d6f-f9ad13db31b7.png">

<br/>

## License

MIT

## Icon

`Vulkan Salute` by Webalys ([Webalys](https://www.webalys.com))
