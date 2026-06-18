# Electron snippet harness

A minimal Electron (Chromium) app with three text inputs — `<input>`,
`<textarea>`, and a `contenteditable` div — for verifying Prosper's inline
snippet expansion in the **Electron / lazy-AX** insertion site, which differs
from the in-process WKWebView fields covered by
`SnippetExpansionIntegrationTests`.

## Run it

```sh
cd app/Tests/Fixtures/electron-snippet-harness
npm install
npm start
```

## Verify expansion

There are two ways to verify, both requiring a logged-in GUI session with
Accessibility access granted to whatever process injects keystrokes.

### Manual (visual)

1. Run Prosper (the real app) so its snippet expander tap is live, with
   **Snippets → Auto-expand** enabled and a snippet whose keyword is `;;sig`.
2. Launch this harness (`npm start`) and click into one of its fields.
3. Type `;;sig`. It should expand in place to the snippet body.
4. Repeat for `<input>`, `<textarea>`, and the `contenteditable` div, and for
   any placeholder snippets (`{date}`, `{clipboard}`, `{cursor}`).

### Assisted (automated assertion)

`SnippetExpansionElectronTests` drives the keystrokes and reads the result back
through the system-wide AX focused element:

1. `npm start`, then click into a field so the caret is there.
2. From `app/`:

   ```sh
   PROSPER_ELECTRON_E2E=1 swift test --filter SnippetExpansionElectronTests
   ```

   On first run, grant the test runner Accessibility access in
   System Settings → Privacy & Security → Accessibility.

The test seeds a `;;sig → "Best regards"` snippet, types `;;sig` into the
frontmost (Electron) app, and asserts the focused element's AX value became
`Best regards`. AX read-back from Chromium can be flaky for some element types;
if the assertion can't observe the value, fall back to the manual check above.

> Note: this fixture is intentionally outside any SwiftPM target, so it is not
> built by `swift build` / `swift test`.
