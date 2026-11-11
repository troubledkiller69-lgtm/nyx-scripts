-- Hypershot — NYX loader
-- Paste with Hypershot open. Rayfield panel: K; panic: DELETE.

local SOURCE = "https://raw.githubusercontent.com/troubledkiller69-lgtm/nyx-scripts/main/hypershot.luau"

local ok, body = pcall(function()
	return game:HttpGet(SOURCE)
end)

if not ok or type(body) ~= "string" or #body < 500 then
	warn("[nyx] could not fetch " .. SOURCE)
	return
end

local chunk, err = loadstring(body, "nyx-hypershot")
if not chunk then
	warn("[nyx] compile failed: " .. tostring(err))
	return
end

local ran, runtimeError = pcall(chunk)
if not ran then
	warn("[nyx] runtime error: " .. tostring(runtimeError))
end
