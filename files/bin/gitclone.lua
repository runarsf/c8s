-- Based on https://github.com/Konijima/cc-git-clone

local expect = dofile("rom/modules/main/cc/expect.lua").expect

local args = {...}

expect(1, args[1], 'string')
expect(2, args[2], 'string')
expect(3, args[3], 'string', 'nil')

local repoSpec = args[1]
local branch = args[2]
local localPath = args[3] or shell.dir()

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

-- Per-provider logic: each provider knows how to list a repo's files
-- (as {path, url, binary, size}) and how to look up its default branch.
local providers = {}

providers.github = {
    getFiles = function(user, repo, branch)
        local treeUrl = ('https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1')
            :format(user, repo, branch)

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
                local url = ('https://raw.githubusercontent.com/%s/%s/%s/%s')
                    :format(user, repo, branch, entry.path)
                table.insert(files, { path = entry.path, url = url, binary = entry.type == 'blob', size = entry.size })
            end
        end
        return files
    end,

    getDefaultBranch = function(user, repo)
        local res, reason = http.get(('https://api.github.com/repos/%s/%s'):format(user, repo))
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

providers.gitlab = {
    getFiles = function(user, repo, branch)
        local projectId = urlEncodeSlashes(user .. '/' .. repo)
        local files = {}
        local page = 1

        while true do
            local treeUrl = ('https://gitlab.com/api/v4/projects/%s/repository/tree?recursive=true&per_page=100&page=%d&ref=%s')
                :format(projectId, page, branch)

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
                    local url = ('https://gitlab.com/%s/%s/-/raw/%s/%s'):format(user, repo, branch, entry.path)
                    -- NOTE: GitLab's tree API doesn't return file size (unlike
                    -- GitHub's), so the existing-file skip check in clone()
                    -- can't apply here — gitlab-sourced files are always
                    -- re-downloaded even if a same-named local file exists.
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
        local res, reason = http.get(('https://gitlab.com/api/v4/projects/%s'):format(projectId))
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

-- Accepts "gitlab:user/repo", "github:user/repo", or bare "user/repo"
-- (defaults to github). The "user" part may itself contain slashes, to
-- support GitLab's nested groups/subgroups.
local function parseRepoSpec(spec)
    local provider, rest = spec:match('^(%a+):(.+)$')
    if provider then
        provider = provider:lower()
        if not providers[provider] then
            return nil, nil, nil, 'Unknown provider "' .. provider .. '" (expected github or gitlab)'
        end
    else
        provider = 'github'
        rest = spec
    end

    local user, repo = rest:match('^(.+)/([^/]+)$')
    if not user or not repo then
        return nil, nil, nil, 'Could not parse "user/repo" from "' .. rest .. '"'
    end

    return provider, user, repo
end

-- Same idea, but for .gitmodules URLs (https://host/user/repo(.git) or
-- git@host:user/repo(.git)) rather than a "provider:user/repo" spec.
local function parseSubmoduleUrl(url)
    local host, path = url:match('^https?://([^/]+)/(.+)$')
    if not host then
        host, path = url:match('^git@([^:]+):(.+)$')
    end
    if not host then
        return nil, nil, nil, 'Could not parse submodule URL: ' .. url
    end

    path = path:gsub('%.git$', '')

    local provider = host:find('gitlab') and 'gitlab' or 'github'

    local user, repo = path:match('^(.+)/([^/]+)$')
    if not user or not repo then
        return nil, nil, nil, 'Could not parse user/repo from: ' .. path
    end

    return provider, user, repo
end

local provider, user, repo, parseErr = parseRepoSpec(repoSpec)
if not provider then
    printError(parseErr)
    return
end

local localRepoPath = fs.combine(localPath, repo)

local function clone(files)
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
            local filePath = fs.combine(localRepoPath, files[i].path)

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

local function parseGitModules()
    local gitModulesPath = fs.combine(localPath, repo, '.gitmodules')
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

local function cloneSubmodule(module)
    local submodulePath = fs.combine(localPath, repo, module.path)
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
    clone(files)
end

local function cloneSubmodules(modules)
    for _, module in ipairs(modules) do
        cloneSubmodule(module)
    end
end

local files, filesErr = providers[provider].getFiles(user, repo, branch)
if files then
    print('Cloning into ' .. repo .. '...')
    clone(files)

    -- Handle submodules
    local modules = parseGitModules()
    cloneSubmodules(modules)
else
    printError(filesErr)
end