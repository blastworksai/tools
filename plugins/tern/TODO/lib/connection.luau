-- Connection metadata is a suggestion, never authority to replay a shell command.
-- CodexBWAI; MIT.
local connection = {}
local function base(value)
    if type(value) ~= "string" then return "" end
    return (value:match("([^/\\]+)$") or value):lower():gsub("%.exe$", "")
end
local function hostLabel(host)
    local name = if type(host.address) == "string" and host.address ~= "" then host.address else host.name
    if type(name) ~= "string" or name == "" then name = "this session host" end
    return name:gsub("[%c]", "?"):sub(1, 160)
end
local function manual(reason, detected)
    return {kind="manual", reason=reason, detected=detected}
end
local function destination(value)
    if type(value) ~= "string" or #value > 320 then return false end
    local user, host = value:match("^([%w_.-]+)@([%w_.-]+)$")
    if not host then host = value end
    return host:match("^[%w][%w_.-]*$") ~= nil and (not user or user:match("^[%w][%w_.-]*$") ~= nil)
end
function connection.ssh(argv)
    if type(argv) ~= "table" or base(argv[1]) ~= "ssh" then return nil end
    local login, port, special = nil, nil, false
    local i = 2
    while i <= #argv do
        local word = argv[i]
        if type(word) ~= "string" or #word > 4096 then return manual("SSH connection metadata is incomplete.", "SSH") end
        if word == "--" then i += 1; break end
        if word:sub(1,1) ~= "-" then break end
        local flag, value = word:sub(1,2), word:sub(3)
        if flag == "-p" or flag == "-l" then
            if value == "" then i += 1; value = argv[i] end
            if type(value) ~= "string" then return manual("SSH connection metadata is incomplete.", "SSH") end
            if flag == "-p" then
                if port or not value:match("^%d+$") then return manual("Choose a reviewed alias for these SSH options.", "SSH") end
                port = tonumber(value)
                if not port or port < 1 or port > 65535 then return manual("SSH port is invalid.", "SSH") end
            else
                if login then return manual("Choose a reviewed alias for these SSH options.", "SSH") end
                login = value
            end
        elseif word:match("^%-[46AaCKkMqsTtvXxYy]+$") then
            -- Source reads retain their own no-forwarding/no-sharing policy.
        elseif flag:match("^%-[iFJSbBcmeELRDWOQw]$") or flag == "-o" then
            special = true
            if value == "" then i += 1; if type(argv[i]) ~= "string" then return manual("SSH options are incomplete.", "SSH") end end
        else
            return manual("Choose a reviewed file-reading alias for these SSH options.", "SSH")
        end
        i += 1
    end
    local target = argv[i]
    if not destination(target) then return manual("The SSH destination could not be identified safely.", "SSH") end
    if login then
        if target:find("@",1,true) then return manual("Choose a reviewed alias for the SSH login override.", target) end
        target = login .. "@" .. target
        if not destination(target) then return manual("The SSH login is invalid.", "SSH") end
    end
    local label = target .. (if port then ":" .. tostring(port) else "")
    local host = (target:match("@(.+)$") or target):lower()
    local forced = host:sub(1,5) == "seat-"
    return {kind="ssh", ssh=target, label=label, needs_alias=special or forced or port ~= nil,
        reason=if forced then "This is an agent-launch alias; choose an ordinary file-reading SSH alias."
            elseif special or port ~= nil then "Choose a reviewed SSH alias that preserves this connection's options."
            else "Confirm that this destination accepts ordinary file-reading commands, not forced agent launches."}
end
function connection.fingerprint(process)
    local function pid(value) return type(value)=="number" and value>0 and value%1==0 end
    if type(process) ~= "table" or type(process.child) ~= "table" or not pid(process.child.pid) then return nil end
    local foreground = process.foreground
    if foreground ~= nil and (type(foreground)~="table" or not pid(foreground.pid)) then return nil end
    return tostring(process.child.pid) .. ":" .. (if type(foreground)=="table" then tostring(foreground.pid) else "none")
end
function connection.detect(host, pane, process)
    if type(host) ~= "table" or host.state ~= "connected" then return manual("The panel's host is not connected.") end
    -- This is the execution host, not the connecting desktop's identity hop.
    -- Native remote blocks read their own host filesystem; no second SSH login.
    if host.kind == "remote" then
        local line = if type(pane.running)=="table" then pane.running.line else nil
        if base(pane.program)=="ssh" or (type(line)=="string" and line:match("^%s*ssh%s")) then
            return manual("An SSH terminal inside the remote host needs an ordinary file-reading destination.", "SSH inside " .. hostLabel(host))
        end
        return {kind="host", label="Remote Tern host " .. hostLabel(host)}
    end
    if host.kind ~= "local" or type(process) ~= "table" then return manual("Connection metadata is unavailable. Choose the plan source explicitly.") end
    for _, field in {"foreground", "child"} do
        local p = process[field]
        if type(p)=="table" then
            local ssh = connection.ssh(p.argv)
            if ssh then return ssh end
        end
    end
    local p = process.foreground or process.child
    if type(p) ~= "table" or type(p.argv) ~= "table" or not connection.fingerprint(process) then return manual("Connection metadata is incomplete.") end
    local program = base(p.argv[1])
    local opaque = {mosh=true, plink=true, wsl=true, docker=true, podman=true}
    if opaque[program] then return manual("This transport needs an explicit plan source.", program) end
    if program=="powershell" or program=="pwsh" or program=="cmd" or program=="bash" or program=="sh" or program=="zsh" then
        for i=2,#p.argv do
            if p.argv[i] ~= "-l" and p.argv[i] ~= "--login" and p.argv[i] ~= "-i" then return manual("A shell wrapper hides the connection; choose the source explicitly.") end
        end
    end
    return {kind="host", label="Local session host " .. hostLabel(host)}
end
return connection
