-- Paste as Plain Text.
--
-- host.clipboard.read() returns the pasteboard's *string* representation; writing it
-- straight back leaves a text-only pasteboard, so the following ⌘V pastes unstyled.
--
-- Invoked from the global hotkey the runner never opens (AppDelegate.swift:798-816),
-- so the frontmost app still has focus when the stroke is synthesized.

-- ponytail: the rich content is replaced, not restored — there is no
-- host.clipboard.snapshot()/restore(). Add one if round-tripping RTF/HTML matters.

local function paste()
    -- Synthesizing a keystroke needs Accessibility; without it host.keys.stroke is a
    -- silent no-op and the user just sees nothing happen. Say so instead.
    if not host.perms.has("accessibility") then
        host.alert.show("Paste as Plain Text needs Accessibility permission.\n"
            .. "Grant it in System Settings › Privacy & Security › Accessibility.")
        return nil
    end

    local text = host.clipboard.read()
    if text == nil or text == "" then return nil end  -- nothing textual to paste

    host.clipboard.write(text)  -- must precede the stroke: ⌘V reads the pasteboard
    host.keys.stroke("cmd+v")
    return nil                  -- mode = "no-view": no UI, focus stays put
end

-- Command ids map to globals with non-alphanumerics replaced by `_`.
pasteplain_paste = paste

-- ── The ⌘V / ⇧⌘V pair (opt-in) ───────────────────────────────────────────────
--
-- The classic arrangement: one of the two paste chords strips formatting, the
-- other pastes the clipboard as it is. Off by default — taking ⌘V away from every
-- app on the Mac is the user's call, never a default.
--
-- The chosen chords are registered as native key rules (ExtensionKeyRules), which
-- the shared event tap evaluates without running any Lua on the keystroke path.
-- The rule swallows the chord and re-invokes `pasteplain_chord` on this
-- extension's own lane, which rewrites the pasteboard (or not) and synthesizes ⌘V.
--
-- Recursion guard: KeyInjector stamps every synthesized event with the tap's
-- synthetic marker, and the tap callback returns such events untouched before it
-- looks at any rule (Autocomplete/AutocompleteEngine.swift, first check inside the
-- callback). So the ⌘V posted here can never re-enter the rule that produced it.

local P_MODE     = "mode"
local MODE_OFF   = "off"
local MODE_CMD   = "cmd_v_plain"        -- ⌘V plain, ⇧⌘V pastes the original
local MODE_SHIFT = "shift_cmd_v_plain"  -- ⇧⌘V plain, ⌘V left alone

local function mode()
    local v = host.prefs.get(P_MODE)
    if v == MODE_CMD or v == MODE_SHIFT then return v end
    return MODE_OFF
end

-- Compile the current mode into the rule set. Pure (no host calls) so the whole
-- mode → chords decision is testable on its own.
local function rules_for(m)
    if m == MODE_CMD then
        return {
            -- Finder is excluded on purpose: there ⌘V pastes files, and the
            -- pasteboard's string form is the file path — rewriting it would paste
            -- the path as text. It is also where the built-in Finder cut/paste move
            -- lives, which reads the same chord.
            { from = "cmd+v", invoke = "pasteplain_chord", arg = "plain",
              not_apps = { "com.apple.finder" } },
            { from = "cmd+shift+v", invoke = "pasteplain_chord", arg = "rich" },
        }
    elseif m == MODE_SHIFT then
        -- No rule for ⌘V at all, so an ordinary paste never even reaches us.
        return {
            { from = "cmd+shift+v", invoke = "pasteplain_chord", arg = "plain" },
        }
    end
    return {}   -- off: clears whatever was registered before
end

-- Idempotent: called at launch and after every settings change, so a new mode
-- takes effect immediately with no relaunch.
local function apply_rules() host.keys.set_rules(rules_for(mode())) end

function on_launch() apply_rules() end

-- An intercepted chord. The real keystroke was swallowed by the tap, so EVERY path
-- through here has to end in a synthesized ⌘V — otherwise the user's paste simply
-- vanishes. Only `arg == "plain"` rewrites the pasteboard first; a clipboard with
-- no text form (an image, a copied file) is pasted exactly as it is.
--
-- ponytail: the plain rewrite REPLACES the styled original, same ceiling as the
-- command above. In ⌘V-plain mode that applies to every paste, which is what the
-- settings footer says out loud.
function pasteplain_chord(arg)
    if arg == "plain" then
        local text = host.clipboard.read()
        if text ~= nil and text ~= "" then host.clipboard.write(text) end
    end
    host.keys.stroke("cmd+v")
end

-- ── Settings (Tier B) ────────────────────────────────────────────────────────
-- Dynamic rather than static controls because picking a mode has to re-register
-- the key rules right away; a static control only writes the pref.

local MODE_VALUES = { MODE_OFF, MODE_CMD, MODE_SHIFT }
local MODE_LABELS = {
    "Off",
    "⌘V pastes plain text, ⇧⌘V pastes the original",
    "⇧⌘V pastes plain text, ⌘V stays normal",
}

function settings_render(section_id, state)
    local s = host.ui.settings
    return s.render(s.ui{
        title = "Paste as Plain Text",
        subtitle = "Paste the clipboard with all formatting stripped",
        sections = {
            s.section{
                id = "chords", title = "Paste shortcuts",
                footer = "Off by default: taking over ⌘V affects every app on the Mac. "
                    .. "Whichever chord strips formatting, it does so by replacing the "
                    .. "clipboard with its plain text — the styled original is not "
                    .. "restored afterwards, and clipboard history gains a plain entry. "
                    .. "Finder is always left alone so pasting files keeps working.",
                rows = {
                    s.row{ kind = "enum", key = P_MODE, title = "Plain-text paste shortcut",
                           subtitle = "Which of the two paste chords strips formatting",
                           value = mode(), options = MODE_VALUES, optionLabels = MODE_LABELS },
                    s.row{ kind = "info", title = "Command shortcut",
                           subtitle = "⌘⌥⇧V by default — see, rebind or turn it off in "
                               .. "Settings › Shortcuts › Extension Commands." },
                },
            },
            s.section{
                id = "permission", title = "Permission",
                footer = "Pasting is done by synthesizing ⌘V, which macOS only allows "
                    .. "with Accessibility granted.",
                rows = {
                    s.row{ kind = "permission", name = "accessibility", title = "Accessibility",
                           subtitle = "Required to intercept the chord and to paste." },
                },
            },
        },
    })
end

function settings_action(section_id, action, value, form_json)
    local key = action:match("^set:(.+)$")
    if key then
        host.prefs.set(key, value or "")
        if key == P_MODE then apply_rules() end
    end
    return settings_render(section_id, "{}")
end
