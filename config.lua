local ns = require "namespaces"


local mod = {}
mod.__index = mod

local config = ns.get()

function mod.getHost()
    return config.host or DEFAULT_SSH_HOST
end

function mod.setHost(host)
    config.host = host
end

return mod
