local actors = {}

local manual = require "utils.manual"
table.insert(actors, manual)

local mod = {}
mod.__index = mod

function mod.getDeviceName()
    return manual.getDeviceName()
end

function mod.getDeviceOS()
    return manual.getDeviceOS()
end




local binarySearch = {}
binarySearch.__index = binarySearch

function binarySearch:create(lower, upper)
    local self = setmetatable({}, binarySearch)
    self.lowerLimit = lower
    self.upperLimit = upper
    return self
end
setmetatable(binarySearch, { __call = binarySearch.create })

function binarySearch:init(lower, upper)
    self.lowerLimit = lower
    self.upperLimit = upper
end

function binarySearch:next(curr, top, threshold)
    if top then
        if curr == self.upperLimit then
            return curr, true
        else
            self.lowerLimit = curr
        end
    else
        if curr == lowerLimit then            
            return curr, true
        else
            self.upperLimit = curr
        end
    end
    local nextVal = math.ceil((self.lowerLimit + self.upperLimit) / 2)
    if math.abs(nextVal - curr) < threshold then
        return curr, true
    end
    return nextVal, false
end

mod.binarySearch = binarySearch


mod.modifier = {
    none = 0,
    randEth = 1,
    randIp = 2
}

function mod.getPktModifierFunction(modifier, baseIp, wrapIp, baseEth, wrapEth)
    local foo = function() end
    if modifier == mod.modifier.randEth then
        local ethCtr = 0
        foo = function(pkt)
            pkt.ip.dst:setNumber(baseEth + ethCtr)
            ethCtr = incAndWrap(ethCtr, wrapEth)
        end
    elseif modifier == mod.modifier.randIp then
        local ipCtr = 0
        foo = function(pkt)
            pkt.ip.dst:set(baseIP + ipCtr)
            ipCtr = incAndWrap(ipCtr, wrapIp)
        end
    end
    return foo
end
--[[
bit faster then macAddr:setNumber or macAddr:set
and faster then macAddr:setString
but still not fast enough for one single slave and 10GbE @64b pkts
set destination MAC address
ffi.copy(macAddr, pkt.eth.dst.uint8, 6)
macAddr[0] = (macAddr[0] + 1) % macWraparound
--]]




return mod


