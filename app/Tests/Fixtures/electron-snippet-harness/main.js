// Minimal Electron harness: a single window with three text inputs (input,
// textarea, contenteditable) for manually verifying Prosper inline snippet
// expansion in Chromium/Electron fields (the lazy-AX insertion site).
const { app, BrowserWindow } = require('electron')
const path = require('path')

function createWindow() {
  const win = new BrowserWindow({
    width: 480,
    height: 360,
    title: 'Prosper Snippet Harness (Electron)',
    webPreferences: { contextIsolation: true },
  })
  win.loadFile(path.join(__dirname, 'index.html'))
}

app.whenReady().then(() => {
  createWindow()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
