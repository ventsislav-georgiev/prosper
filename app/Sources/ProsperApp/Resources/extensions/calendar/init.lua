-- Calendar is a fully NATIVE feature (CalendarBar/CalendarBarController.swift):
-- the menu-bar day badge, the popup month grid and the agenda list are all
-- driven from Swift over EventKit. This extension exists only to provide the
-- enable/disable gate (system extension) and the declarative Settings page.
--
-- There is intentionally no Lua command or handler — interaction is the
-- menu-bar icon plus the rebindable "toggle calendar" global shortcut.
return {}
