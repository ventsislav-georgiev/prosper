-- Menu Bar Management is a fully NATIVE feature (MenuBarManager.swift): the
-- chevron divider items, hide/reveal, spacing, and reorder are all driven from
-- Swift over the private CGS window list. This extension exists only to provide
-- the enable/disable gate (system extension) and the declarative Settings page.
--
-- There is intentionally no Lua command or handler — interaction is the chevron
-- in the menu bar plus the rebindable "reveal hidden section" global shortcut.
return {}
