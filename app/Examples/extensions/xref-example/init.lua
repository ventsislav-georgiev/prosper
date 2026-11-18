-- xref-example (#1569): a fake ticket card. Real extensions would look the ticket up; this one makes it up.
local tickets = {
  ["12"] = { title = "Login retries", status = "In progress", owner = "acme/api" },
}

function xref_card(a)
  if type(a.parts) ~= "table" then return { error = "no ticket number" } end
  local n = tostring(a.parts[1])
  local t = tickets[n]
  if t == nil then return nil end
  return {
    title = t.title,
    subtitle = "ACME-" .. n .. " \u{00B7} " .. t.status,
    body = "Owner: " .. t.owner .. "\nSeen in session " .. tostring(a.session),
    actions = {
      { label = "Open", url = "https://example.com/acme/tickets/" .. n },
      { label = "Copy id", copy = "ACME-" .. n },
    },
  }
end
