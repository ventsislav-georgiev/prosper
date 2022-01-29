<img align="left" width="115px" height="115px" src="icon.png">

# Prosper

<br/>

## Description
Command runner with translation, calc, currency and unit conversion.

Also includes:
* [Global Shortcuts](#global-shortcuts)
* [Clipboard History](#clipboard-history)
* [Base64 Encode/Decode](#base64-encodedecode)
* [Numi Integration](#numi-integration-macos-only)
* [Automatic Updates](#automatic-updates)

Supports: Mac, Windows and Linux

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
* `Shift+Alt+A` - toggle
* `1, 2, 3 .. to 0 keys` - select a clip
* Filter clip by fuzzy search and press `Enter` to select the top clip
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

### Automatic Updates

`Prosper` will periodically check for new releases via the Github API. They will be silently downloaded and the app will restart.

#### Turn Off
In order to disable the automatic updates, create an empty file in the user dir `touch ~/.prosper-no-updates` and restart `Prosper`

<br/>

## License

MIT

## Icon

`Vulkan Salute` by Webalys ([Webalys](https://www.webalys.com))
