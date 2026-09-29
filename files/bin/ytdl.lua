-- Download YouTube audio as dfpwm. Usable two ways:
--
--   command:  ytdl <url>
--             ytdl <url> mysong
--             ytdl <url> /disk/music/
--
--   library:  local ytdl = dofile("/app/bin/ytdl.lua")
--             local paths, failed = ytdl.get("https://youtu.be/...")
--             local path = ytdl.download(ytdl.resolve(url), "mysong.dfpwm")
--
-- The first argument is handed to the search API as-is, so a quoted search
-- phrase works wherever a url does; a playlist url downloads every track.
--
-- Conversion happens on a third-party service (the same one the `ipod`
-- program uses), which returns raw dfpwm bytes. Dependency-free on purpose,
-- so a role can ship this one file.

local M = {}

M.api       = "https://ipod-2to6magyna-uc.a.run.app/"
M.version   = "2.1"
M.extension = ".dfpwm"

-- Default output directory: the folder ntfy-consume plays from, so a
-- download is immediately playable by name. Falls back to its default.
function M.musicDir()
    local dir = settings.get("ntfy_play.music_path")
    if type(dir) ~= "string" or dir == "" then return "downloads" end
    return dir
end

function M.sanitize(name)
    name = tostring(name or "untitled")
    name = name:gsub('[<>:"/\\|?*%c]', "_")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 64 then name = name:sub(1, 64) end
    -- "" and ".."  are both names fs.combine would resolve to somewhere
    -- other than the directory we meant.
    if name == "" or name:match("^%.+$") then name = "untitled" end
    return name
end

-- A track's filename without the extension: "name - artist", or just the
-- name when there is no artist.
function M.title(item)
    local name = item.name or "untitled"
    if item.artist and item.artist ~= "" then
        return name .. " - " .. item.artist
    end
    return name
end

-- base .. ".dfpwm", numbered if that is taken. Only used for names this
-- script derives - an explicit path is taken literally.
local function unique(base)
    local path = base .. M.extension
    local n = 2
    while fs.exists(path) do
        path = ("%s (%d)%s"):format(base, n, M.extension)
        n = n + 1
    end
    return path
end

-- Where one track lands:
--   no path                    -> <music dir>/<title>.dfpwm, numbered if taken
--   existing dir, or ends "/"  -> that directory, named the same way
--   anything else              -> exactly that file, .dfpwm appended if it
--                                 has no extension, overwritten if it exists
function M.pathFor(item, path)
    if path == nil or path == "" then
        return unique(fs.combine(M.musicDir(), M.sanitize(M.title(item))))
    end
    if path:sub(-1) == "/" or fs.isDir(path) then
        return unique(fs.combine(path, M.sanitize(M.title(item))))
    end
    if not path:match("%.%w+$") then path = path .. M.extension end
    return path
end

local function request(url, binary)
    local handle, err = http.get({ url = url, binary = binary or false })
    if not handle then return nil, tostring(err or "request failed") end
    local body = handle.readAll()
    handle.close()
    return body
end

-- Search results as the API returns them: a list of items carrying at least
-- `id`, `name` and `artist`, plus `type == "playlist"` and `playlist_items`
-- for a playlist.
function M.search(query)
    if type(query) ~= "string" or query == "" then return nil, "no url given" end
    local url = ("%s?v=%s&search=%s"):format(M.api, M.version, textutils.urlEncode(query))
    local body, err = request(url)
    if not body then return nil, err end
    local results = textutils.unserialiseJSON(body)
    if type(results) ~= "table" then return nil, "could not read the search response" end
    return results
end

-- The first thing the API matches, which for a url is that url's video or
-- playlist.
function M.resolve(query)
    local results, err = M.search(query)
    if not results then return nil, err end
    if #results == 0 then return nil, "nothing found for '" .. query .. "'" end
    return results[1]
end

-- The tracks an item stands for: itself, or a playlist's contents.
function M.tracks(item)
    if type(item) ~= "table" then return {} end
    if item.type == "playlist" and type(item.playlist_items) == "table" then
        return item.playlist_items
    end
    return { item }
end

-- Fetches one track and writes it. The response is dfpwm, so it is read and
-- written as bytes: in text mode it arrives subtly altered and plays as
-- static, which is the same trap the controller's bundle format hit.
function M.download(item, path)
    if type(item) ~= "table" or not item.id then return nil, "no track to download" end
    local url = ("%s?v=%s&id=%s"):format(M.api, M.version, textutils.urlEncode(item.id))
    local body, err = request(url, true)
    if not body then return nil, err end

    local target = M.pathFor(item, path)
    local dir = fs.getDir(target)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end

    local file, ferr = fs.open(target, "wb")
    if not file then return nil, tostring(ferr or ("could not write " .. target)) end
    file.write(body)
    file.close()
    return target
end

-- Resolve a url and download everything it names. Returns the paths written
-- and a (possibly empty) list of { name, error } for tracks that failed, or
-- nil plus a reason if the url resolved to nothing at all. `onTrack` is an
-- optional callback, called as (track, path, error) once each one is done.
function M.get(url, path, onTrack)
    local item, err = M.resolve(url)
    if not item then return nil, err end

    local tracks = M.tracks(item)
    if #tracks == 0 then return nil, "playlist is empty" end

    -- More than one track can only mean a directory, whatever was asked for:
    -- a trailing slash is what pathFor reads as one.
    if #tracks > 1 and path and path ~= "" and path:sub(-1) ~= "/" then
        path = path .. "/"
    end

    local paths, failed = {}, {}
    for _, track in ipairs(tracks) do
        local written, terr = M.download(track, path)
        if written then
            paths[#paths + 1] = written
        else
            failed[#failed + 1] = { name = M.title(track), error = terr }
        end
        if onTrack then onTrack(track, written, terr) end
    end
    return paths, failed
end

-- Command line -------------------------------------------------------------

local args = { ... }
if #args == 0 then return M end

local function fail(message)
    printError("ytdl: " .. message)
    error("", 0)
end

if args[1] == "-h" or args[1] == "--help" then
    print("Usage: ytdl <url> [path]")
    print("  path may be a file, or a directory (existing, or ending in /).")
    print("  Defaults to " .. M.musicDir() .. "/<title>.dfpwm.")
    return
end

if #args > 2 then fail("expected a url and at most one path") end

-- Reported as each one lands, rather than in a summary at the end, since a
-- playlist can take a while and there is nothing else to look at.
local paths, failed = M.get(args[1], args[2], function(track, path, err)
    if path then
        print("saved " .. path)
    else
        printError(M.title(track) .. ": " .. err)
    end
end)

if not paths then fail(failed) end       -- resolving failed; `failed` is why
if #paths == 0 then fail("nothing downloaded") end
