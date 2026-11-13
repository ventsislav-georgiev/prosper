-- The Claude Account Pool is a fully NATIVE feature (CCPool/): the loopback
-- proxy, the account store and the Keychain tokens all live in Swift. This
-- extension exists only to provide the enable/disable gate (system extension)
-- and the declarative Settings page.
--
-- There is intentionally no Lua command or handler, and no Lua access to tokens.
return {}
