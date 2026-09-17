-- Based on https://github.com/Konijima/cc-git-clone
local expect = dofile("rom/modules/main/cc/expect.lua").expect

-- Marker file dropped in the repo root by `clone`, so `pull` later knows
-- which provider/user/repo/branch to re-fetch without being told again.
local GIT_MARKER_FILE = '.git'

-- Case-insensitive header lookup (CC doesn't normalize header casing for us,
-- and GitLab's pagination headers show up as "X-Next-Page" etc.)
local function getHeader(headers, name)
    name = name:lower()
    for k, v in pairs(headers or {}) do
        if k:lower() == name then
            return v
        end
    end
    return nil
end

-- GitLab's project-id path param wants "/" encoded as "%2F"
local function urlEncodeSlashes(path)
    return path:gsub('/', '%%2F')
end

-- Provider "kinds": one factory per REST API shape (GitHub-, GitLab-, and
-- Forgejo/Gitea-style), each taking the host it should talk to and
-- returning {host, getFiles, getDefaultBranch}. An "instance" below picks
-- a kind and a host; this is what actually builds the api/raw URLs.
local kinds = {}

kinds.github = function(host)
    -- github.com's API and raw-content domains are irregular (api.github.com
    -- and raw.githubusercontent.com, not subdomains of github.com), so
    -- that's special-cased. Any other host is assumed to be a GitHub
    -- Enterprise Server instance without subdomain isolation, which uses
    -- HOST/api/v3 and HOST/raw — see GHES docs if isolation is enabled on
    -- your instance, since that moves raw content to raw.HOST instead.
    local apiBase = (host == 'github.com') and 'api.github.com' or (host .. '/api/v3')
    local rawBase = (host == 'github.com') and 'raw.githubusercontent.com' or (host .. '/raw')

    return {
        host = host,

        getFiles = function(user, repo, branch)
            local treeUrl = ('https://%s/repos/%s/%s/git/trees/%s?recursive=1')
                :format(apiBase, user, repo, branch)

            local res, reason = http.get(treeUrl)
            if not res then
                return nil, reason
            end
            local tree = textutils.unserialiseJSON(res.readAll())
            res.close()
            if not tree or not tree.tree then
                return nil, 'Failed to parse repository tree for ' .. user .. '/' .. repo
            end

            local files = {}
            for _, entry in pairs(tree.tree) do
                if entry.type ~= 'tree' and entry.type ~= 'commit' then
                    local url = ('https://%s/%s/%s/%s/%s')
                        :format(rawBase, user, repo, branch, entry.path)
                    table.insert(files, { path = entry.path, url = url, binary = entry.type == 'blob', size = entry.size })
                end
            end
            return files
        end,

        getDefaultBranch = function(user, repo)
            local res, reason = http.get(('https://%s/repos/%s/%s'):format(apiBase, user, repo))
            if not res then
                return nil, reason
            end
            local info = textutils.unserialiseJSON(res.readAll())
            res.close()
            if not info or not info.default_branch then
                return nil, 'Repository info did not include a default branch'
            end
            return info.default_branch
        end,
    }
end

kinds.gitlab = function(host)
    -- Self-hosted GitLab uses the exact same URL shape as gitlab.com, just
    -- under a different host, so no special-casing is needed here.
    return {
        host = host,

        getFiles = function(user, repo, branch)
            local projectId = urlEncodeSlashes(user .. '/' .. repo)
            local files = {}
            local page = 1

            while true do
                local treeUrl = ('https://%s/api/v4/projects/%s/repository/tree?recursive=true&per_page=100&page=%d&ref=%s')
                    :format(host, projectId, page, branch)

                local res, reason = http.get(treeUrl)
                if not res then
                    return nil, reason
                end
                local entries = textutils.unserialiseJSON(res.readAll())
                local nextPage = getHeader(res.getResponseHeaders(), 'x-next-page')
                res.close()

                if not entries or #entries == 0 then
                    break
                end

                for _, entry in ipairs(entries) do
                    if entry.type ~= 'tree' and entry.type ~= 'commit' then
                        local url = ('https://%s/%s/%s/-/raw/%s/%s'):format(host, user, repo, branch, entry.path)
                        -- NOTE: GitLab's tree API doesn't return file size
                        -- (unlike GitHub's), so the existing-file skip check
                        -- in clone() can't apply here — gitlab-sourced files
                        -- are always re-downloaded even if a same-named
                        -- local file exists.
                        table.insert(files, { path = entry.path, url = url, binary = entry.type == 'blob', size = nil })
                    end
                end

                if not nextPage or nextPage == '' then
                    break
                end
                page = page + 1
            end

            return files
        end,

        getDefaultBranch = function(user, repo)
            local projectId = urlEncodeSlashes(user .. '/' .. repo)
            local res, reason = http.get(('https://%s/api/v4/projects/%s'):format(host, projectId))
            if not res then
                return nil, reason
            end
            local info = textutils.unserialiseJSON(res.readAll())
            res.close()
            if not info or not info.default_branch then
                return nil, 'Repository info did not include a default branch'
            end
            return info.default_branch
        end,
    }
end

kinds.forgejo = function(host)
    return {
        host = host,

        getFiles = function(user, repo, branch)
            local files = {}
            local page = 1

            while true do
                local treeUrl = ('https://%s/api/v1/repos/%s/%s/git/trees/%s?recursive=true&per_page=1000&page=%d')
                    :format(host, user, repo, branch, page)

                local res, reason = http.get(treeUrl)
                if not res then
                    return nil, reason
                end
                local body = textutils.unserialiseJSON(res.readAll())
                res.close()

                if not body or not body.tree then
                    return nil, 'Failed to parse repository tree for ' .. user .. '/' .. repo
                end

                for _, entry in ipairs(body.tree) do
                    if entry.type ~= 'tree' and entry.type ~= 'commit' then
                        local url = ('https://%s/%s/%s/raw/branch/%s/%s'):format(host, user, repo, branch, entry.path)
                        table.insert(files, { path = entry.path, url = url, binary = entry.type == 'blob', size = entry.size })
                    end
                end

                if not body.truncated then
                    break
                end
                page = page + 1
            end

            return files
        end,

        getDefaultBranch = function(user, repo)
            local res, reason = http.get(('https://%s/api/v1/repos/%s/%s'):format(host, user, repo))
            if not res then
                return nil, reason
            end
            local info = textutils.unserialiseJSON(res.readAll())
            res.close()
            if not info or not info.default_branch then
                return nil, 'Repository info did not include a default branch'
            end
            return info.default_branch
        end,
    }
end

-- The single place to add, remove, or repoint a hosted instance. `kind`
-- selects which URL shape to build (a key in `kinds` above), `host` is the
-- instance's hostname. The table key is what a repo spec's provider prefix
-- matches against (e.g. "codeberg:user/repo" or "git.gay:user/repo") — it
-- doesn't have to equal `host`, which is what lets the short "codeberg"
-- stand in for the longer "codeberg.org".
local instances = {
    github = { kind = 'github', host = 'github.com' },
    gitlab = { kind = 'gitlab', host = 'gitlab.com' },
    codeberg = { kind = 'forgejo', host = 'codeberg.org' },
    ['git.gay'] = { kind = 'forgejo', host = 'git.gay' },
}

-- Per-provider logic: each provider knows how to list a repo's files
-- (as {path, url, binary, size}) and how to look up its default branch.
-- Built from `instances` + `kinds` above, keyed the same way as `instances`.
local providers = {}
for name, instance in pairs(instances) do
    providers[name] = kinds[instance.kind](instance.host)
end

-- Accepts "gitlab:user/repo/branch", "github:user/repo/branch", or bare
-- "user/repo[/branch]" (provider defaults to github, branch defaults to
-- main). This is also the exact format stored in the .git marker file, so
-- it doubles as that format's parser.
local function knownProviderNames()
    local names = {}
    for name in pairs(providers) do
        table.insert(names, name)
    end
    table.sort(names)
    return table.concat(names, ', ')
end

local function parseRepoSpec(spec)
    local provider, rest = spec:match('^([%w.%-]+):(.+)$')
    if provider then
        provider = provider:lower()
        if not providers[provider] then
            return nil, nil, nil, nil, 'Unknown provider "' .. provider .. '" (expected one of: ' .. knownProviderNames() .. ')'
        end
    else
        provider = 'github'
        rest = spec
    end

    local parts = {}
    for part in rest:gmatch('[^/]+') do
        table.insert(parts, part)
    end

    if #parts < 2 or #parts > 3 then
        return nil, nil, nil, nil, 'Could not parse "user/repo[/branch]" from "' .. rest .. '"'
    end

    local user, repo, branch = parts[1], parts[2], parts[3] or 'main'

    return provider, user, repo, branch
end

-- Matches a submodule's git host against each provider's configured host
-- (exact match, not a fuzzy substring check — a host that merely contains
-- "gitlab" shouldn't be assumed to speak GitLab's API). Falls back to
-- github for anything unrecognized, since that's by far the most common case.
local function detectProviderFromHost(host)
    for name, p in pairs(providers) do
        if p.host == host then
            return name
        end
    end
    return 'github'
end

-- Same idea as parseRepoSpec, but for .gitmodules URLs (https://host/user/repo(.git)
-- or git@host:user/repo(.git)) rather than a "provider:user/repo/branch"
-- spec. .gitmodules never specifies a branch, so callers fall back to
-- providers[x].getDefaultBranch() for these.
local function parseSubmoduleUrl(url)
    local host, path = url:match('^https?://([^/]+)/(.+)$')
    if not host then
        host, path = url:match('^git@([^:]+):(.+)$')
    end
    if not host then
        return nil, nil, nil, 'Could not parse submodule URL: ' .. url
    end

    path = path:gsub('%.git$', '')

    local provider = detectProviderFromHost(host)

    local user, repo = path:match('^(.+)/([^/]+)$')
    if not user or not repo then
        return nil, nil, nil, 'Could not parse user/repo from: ' .. path
    end

    return provider, user, repo
end

local function writeGitMarker(repoPath, provider, user, repo, branch)
    local marker = fs.open(fs.combine(repoPath, GIT_MARKER_FILE), 'w')
    marker.write(('%s:%s/%s/%s'):format(provider, user, repo, branch))
    marker.close()
end

local function readGitMarker(repoPath)
    local markerPath = fs.combine(repoPath, GIT_MARKER_FILE)
    if not fs.exists(markerPath) then
        return nil, 'No ' .. GIT_MARKER_FILE .. ' marker found in "' .. repoPath .. '" (was this cloned with this tool?)'
    end

    local file = fs.open(markerPath, 'r')
    local content = file.readAll()
    file.close()

    return content
end

local function clone(repoPath, files)
    local processes = {}
    local x, y = term.getCursorPos()

    local downloadedCount = 0

    local function step_progress(leading_text)
        term.setCursorPos(x, y)
        term.clearLine()
        downloadedCount = downloadedCount + 1
        local progressText = leading_text .. ': ' .. (downloadedCount / #files * 100) .. '% (' .. downloadedCount .. '/' .. #files .. ')'
        if downloadedCount ~= #files then
            term.write(progressText)
        else
            print(progressText)
        end
    end

    for i=1, #files do
        local function download()
            local filePath = fs.combine(repoPath, files[i].path)

            if fs.exists(filePath) then
                if fs.getSize(filePath) == files[i].size then
                    step_progress('Checking files')
                    return
                end
            end

            local request = http.get(files[i].url, nil, files[i].binary)
            local content = request.readAll()
            request.close()

            local mode = 'w'
            if files[i].binary then
                mode = 'wb'
            end

            local writer = fs.open(filePath, mode)
            writer.write(content or '')
            writer.close()
            step_progress('Receiving files')
        end
        table.insert(processes, download)
    end
    parallel.waitForAll(table.unpack(processes))
end

local function parseGitModules(repoPath)
    local gitModulesPath = fs.combine(repoPath, '.gitmodules')
    if not fs.exists(gitModulesPath) then
        return {}
    end

    local file = fs.open(gitModulesPath, 'r')
    local content = file.readAll()
    file.close()

    local modules = {}
    for module, path, url in content:gmatch('%[submodule "(.-)"%]%s*path = ([^\n]+)%s*url = ([^\n]+)') do
        table.insert(modules, {path = path, url = url})
    end

    return modules
end

local function cloneSubmodule(repoPath, module)
    local submodulePath = fs.combine(repoPath, module.path)
    local submodule_name = fs.getName(module.path)

    -- Check if submodule already exists
    if fs.exists(submodulePath) then
        --print('Submodule ' .. submodule_name .. ' already exists, skipping.')
        return
    end

    local subProvider, subUser, subRepo, urlErr = parseSubmoduleUrl(module.url)
    if not subProvider then
        printError(urlErr)
        return
    end

    local subBranch, branchErr = providers[subProvider].getDefaultBranch(subUser, subRepo)
    if not subBranch then
        printError('Failed to fetch repository info: ' .. (branchErr or 'Unknown error'))
        return
    end

    local files, filesErr = providers[subProvider].getFiles(subUser, subRepo, subBranch)
    if not files then
        printError(filesErr)
        return
    end

    for _, f in ipairs(files) do
        f.path = module.path .. '/' .. f.path
    end

    print('Cloning submodule ' .. submodule_name .. '...')
    clone(repoPath, files)
end

local function cloneSubmodules(repoPath, modules)
    for _, module in ipairs(modules) do
        cloneSubmodule(repoPath, module)
    end
end

local function resolveTargetPath(explicitPath, fallbackName)
    if explicitPath then
        -- Resolved against the current shell directory when relative, and
        -- used as the clone destination itself — no reponame subfolder
        -- gets appended on top of it.
        return shell.resolve(explicitPath)
    end
    return fs.combine(shell.dir(), fallbackName)
end

local function cmdClone(cmdArgs)
    expect(1, cmdArgs[1], 'string')
    expect(2, cmdArgs[2], 'string', 'nil')

    local repoSpec = cmdArgs[1]
    local explicitPath = cmdArgs[2]

    local provider, user, repo, branch, parseErr = parseRepoSpec(repoSpec)
    if not provider then
        printError(parseErr)
        return
    end

    local repoPath = resolveTargetPath(explicitPath, repo)

    local files, filesErr = providers[provider].getFiles(user, repo, branch)
    if not files then
        printError(filesErr)
        return
    end

    print('Cloning into ' .. repo .. '...')
    clone(repoPath, files)
    writeGitMarker(repoPath, provider, user, repo, branch)

    local modules = parseGitModules(repoPath)
    cloneSubmodules(repoPath, modules)
end

local function cmdPull(cmdArgs)
    expect(1, cmdArgs[1], 'string', 'nil')

    local explicitPath = cmdArgs[1]
    local repoPath = explicitPath and shell.resolve(explicitPath) or shell.dir()

    local marker, markerErr = readGitMarker(repoPath)
    if not marker then
        printError(markerErr)
        return
    end

    local provider, user, repo, branch, parseErr = parseRepoSpec(marker)
    if not provider then
        printError('Malformed ' .. GIT_MARKER_FILE .. ' marker file: ' .. parseErr)
        return
    end

    local files, filesErr = providers[provider].getFiles(user, repo, branch)
    if not files then
        printError(filesErr)
        return
    end

    print('Pulling ' .. repo .. '...')
    clone(repoPath, files)

    local modules = parseGitModules(repoPath)
    cloneSubmodules(repoPath, modules)
end

local COMMANDS = {
    clone = cmdClone,
    pull = cmdPull,
}

local args = {...}
local subcommand = table.remove(args, 1)
local handler = subcommand and COMMANDS[subcommand]

if not handler then
    if subcommand then
        printError('Unknown subcommand: ' .. subcommand)
    end
    print('Usage:')
    print('  git clone <[provider:]user/repo[/branch]> [path]')
    print('  git pull [path]')
    return
end

handler(args)