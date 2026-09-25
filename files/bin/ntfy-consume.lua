-- Listens on an ntfy topic forever (reconnecting if dropped). Each
-- notification's message body names a song to play once from the
-- configured music folder -- e.g. a notification body of "mysong"
-- plays "<music_path>/mysong.dfpwm". Goes back to listening after
-- each song finishes.
--
-- Configure with the built-in `set` program:
--   set ntfy_play.topic mytopic           -- required
--   set ntfy_play.music_path downloads    -- optional, defaults to "downloads"
--
-- Trigger it with e.g.: curl -d "mysong" ntfy.sh/<topic>

settings.define("ntfy_play.topic", {
	description = "ntfy topic to listen on (make it unguessable, topics are public)",
	default = "",
	type = "string",
})

settings.define("ntfy_play.music_path", {
	description = "Folder to look for <name>.dfpwm files in",
	default = "downloads",
	type = "string",
})

settings.load()

local topic = settings.get("ntfy_play.topic")
local musicPath = settings.get("ntfy_play.music_path")

if topic == nil or topic == "" then
	error("No topic configured. Run: set ntfy_play.topic <topic>", 0)
end

local speaker = peripheral.find("speaker")
if not speaker then
	error("No speaker attached.", 0)
end

local url = "wss://ntfy.sh/" .. topic .. "/ws"

local function sanitizeName(name)
	name = name:gsub("^%s+", ""):gsub("%s+$", "")
	name = name:gsub("[^%w %-_]", "")  -- strip anything but letters/digits/space/-/_
	return name
end

local function playFile(path)
	local decoder = require("cc.audio.dfpwm").make_decoder()
	local file = fs.open(path, "rb")
	local chunkSize = 16 * 1024

	while true do
		local chunk = file.read(chunkSize)
		if not chunk then break end

		local buffer = decoder(chunk)
		while not speaker.playAudio(buffer) do
			os.pullEvent("speaker_audio_empty")
		end
	end

	file.close()
end

local function handleMessage(msg)
	if not (msg and msg.event == "message" and msg.message) then
		return
	end

	local name = sanitizeName(msg.message)
	if name == "" then
		print("Ignoring notification with no song name.")
		return
	end

	local path = fs.combine(musicPath, name .. ".dfpwm")
	if not fs.exists(path) or fs.isDir(path) then
		print("No such song: " .. path)
		return
	end

	print("Playing " .. path)
	playFile(path)
	print("Listening on '" .. topic .. "'...")
end

print("Listening on '" .. topic .. "'...")

while true do
	local ws, err = http.websocket(url)
	if not ws then
		print("connect failed: " .. tostring(err))
		sleep(5)
	else
		while true do
			local ok, raw = pcall(ws.receive)
			if not ok or not raw then break end  -- dropped, reconnect

			handleMessage(textutils.unserialiseJSON(raw))
		end

		pcall(ws.close)
		sleep(1)
	end
end