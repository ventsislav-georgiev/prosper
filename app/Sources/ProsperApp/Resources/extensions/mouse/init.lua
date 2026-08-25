-- Mouse is a fully NATIVE feature: the scroll and button services are CGEvent
-- taps in Swift (EventTap.swift + Sources/ProsperApp/Mouse/). This extension
-- exists only to provide the enable/disable gate (system extension) and the
-- declarative Settings page.
--
-- There is intentionally no Lua command or handler — a tap callback runs on the
-- main run loop at scroll rate (60-120 Hz) and must not cross into the VM.
return {}
