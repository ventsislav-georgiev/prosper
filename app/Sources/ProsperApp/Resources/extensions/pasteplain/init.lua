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
