-- Tiny companion to ntfy_play.lua: posts a notification to the
-- configured topic on a fixed real-world schedule, telling any
-- listening ntfy_play.lua computers which song to play.
--
-- Configure with the built-in `set` program:
--   set ntfy_notify.topic runar-cc   -- required, must match the listener's topic
--   set ntfy_notify.sound mysong     -- required, name of the .dfpwm to trigger (no extension)
--   set ntfy_notify.minutes 22       -- optional, defaults to 22

settings.define("ntfy_notify.topic", {
	description = "ntfy topic to publish to (must match the listener's topic)",
	default = "",
	type = "string",
})

settings.define("ntfy_notify.sound", {
	description = "Name of the song to trigger (matches a <music_path>/<name>.dfpwm on the listener)",
	default = "",
	type = "string",
})

settings.define("ntfy_notify.minutes", {
	description = "Real-world minutes between notifications",
	default = 22,
	type = "number",
})

settings.load()

local topic = settings.get("ntfy_notify.topic")
local sound = settings.get("ntfy_notify.sound")
local minutes = settings.get("ntfy_notify.minutes")

if topic == nil or topic == "" then
	error("No topic configured. Run: set ntfy_notify.topic <topic>", 0)
end
if sound == nil or sound == "" then
	error("No sound configured. Run: set ntfy_notify.sound <name>", 0)
end

local url = "https://ntfy.sh/" .. topic
local interval = minutes * 60

print(("Notifying '%s' with '%s' every %d minute(s)."):format(topic, sound, minutes))

while true do
	local response, err = http.post(url, sound)
	if response then
		response.close()
		print("Sent.")
	else
		print("Send failed: " .. tostring(err))
	end

	sleep(interval)
end