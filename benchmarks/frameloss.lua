package.path = package.path .. "rfc2544/?.lua"

local standalone = false
if master == nil then
        standalone = true
        master = "dummy"
end

local moongen   = require "moongen"
local dpdk      = require "dpdk"
local memory    = require "memory"
local device    = require "device"
local ts        = require "timestamping"
local filter    = require "filter"
local ffi       = require "ffi"
local barrier   = require "barrier"
local timer     = require "timer"
local stats     = require "stats"
local utils     = require "utils.utils"
local tikz      = require "utils.tikz"


local UDP_PORT = 42

local benchmark = {}
benchmark.__index = benchmark

function benchmark.create()
    local self = setmetatable({}, benchmark)
    self.initialized = false
    return self
end
setmetatable(benchmark, {__call = benchmark.create})

function benchmark:init(arg)
    self.duration = arg.duration or 10
    self.granularity = arg.granularity or 0.5
    
    self.rxQueues = arg.rxQueues
    self.txQueues = arg.txQueues
    
    self.skipConf = arg.skipConf
    self.dut = arg.dut
    
    self.initialized = true
end

function benchmark:config()
end

function benchmark:undoConfig()
end

function benchmark:getCSVHeader()
    local str = "percent of link rate,frame size,duration,received packets,sent packets,frameloss in %"
    return str
end

function benchmark:resultToCSV(result)
    local str = ""
    for k,v in ipairs(result) do
        str = str .. v.multi .. "," .. v.size .. "," .. self.duration .. "," .. v.rpkts .. "," .. v.spkts .. "," .. (v.spkts - v.rpkts) / (v.spkts) * 100
        if result[k+1] then
            str = str .. "\n"
        end
    end
    return str
end

function benchmark:toTikz(filename, ...)
    local fl = tikz.new(filename .. "_percent" .. ".tikz", [[xlabel={link rate [\%]}, ylabel={frameloss [\%]}, grid=both, ymin=0, xmin=0, xmax=100,scaled ticks=false, width=9cm, height=4cm, cycle list name=exotic,legend style={at={(1.04,1)},anchor=north west}]])
    local th = tikz.new(filename .. "_throughput" .. ".tikz", [[xlabel={offered load [mpps]}, ylabel={throughput [mpps]}, grid=both, ymin=0, xmin=0, scaled ticks=false, width=9cm, height=4cm, cycle list name=exotic,legend style={at={(1.02,1)},anchor=north west}]])
    
    local numResults = select("#", ...)
    for i=1, numResults do
        local result = select(i, ...)
        
        fl:startPlot()
        th:startPlot()
        
        local frameSize
        for _, p in ipairs(result) do
            frameSize = p.size
            
            fl:addPoint(p.multi * 100, (p.spkts - p.rpkts) / p.spkts * 100)
            
            local offeredLoad = p.spkts / 10^6 / self.duration
            local throughput = p.rpkts / 10^6 / self.duration
            th:addPoint(offeredLoad, throughput)
        end
        fl:addPoint(0, 0)
        fl:endPlot(frameSize .. " bytes")
        
        th:addPoint(0, 0)
        th:endPlot(frameSize .. " bytes")
        
    end
    fl:finalize()
    th:finalize()
end

function benchmark:bench(frameSize, maxLossRate)
    if not self.initialized then
        return error("benchmark not initialized");
    elseif frameSize == nil then
        return error("benchmark got invalid frameSize");
    end

    if not self.skipConf then
        self:config()
    end

    local maxLinkRate = self.txQueues[1].dev:getLinkStatus().speed
    local rateMulti = 1
    local bar = barrier.new(2,2)
    local results = {}
    local port = UDP_PORT
    local lastNoLostFrame = false
    
    -- loop until no packetloss
    while moongen.running() and rateMulti >= 0.05 do
        -- set rate
        local rate = maxLinkRate * rateMulti
        
        -- workaround for rate bug
        local numQueues = rate > (64 * 64) / (84 * 84) * maxLinkRate and rate < maxLinkRate and 2 or 1 --was and 3 or 1
	printf("numQueues: %i",numQueues)
	local qrate = maxLinkRate
        bar:reinit(numQueues + 1)
        if rate < maxLinkRate then
            -- not maxLinkRate
            -- eventual multiple slaves
            -- set rate is payload rate not wire rate
            for i=1, numQueues do
		qrate = rate * frameSize / (frameSize + 20) / numQueues			
                printf("set queue %i to rate %d (maxLinkRate %d)", i, qrate, maxLinkRate)
                self.txQueues[i]:setRate(qrate)
            end
        else
            -- maxLinkRate
            self.txQueues[1]:setRate(rate)
        end
	--check if rate goes above link rate
        if(qrate > maxLinkRate) then
		printf("WARNING: no more options for framerate to reduce packet loss, quitting at rate %d", qrate)
		break	
	end
        local loadTasks = {}
        -- traffic generator
        for i=1, numQueues do
            table.insert(loadTasks, moongen.startTask("framelossLoadSlave", self.txQueues[i], port, frameSize, self.duration, mod, bar))
        end
        
        -- count the incoming packets
        local ctrTask = moongen.startTask("framelossCounterSlave", self.rxQueues[1], port, frameSize, self.duration, bar)
        
        -- wait until all slaves are finished
        local spkts = 0
        for i, loadTask in ipairs(loadTasks) do
            spkts = spkts + loadTask:wait()
        end
        local rpkts = ctrTask:wait()
        
        
        local elem = {}
        elem.multi = rateMulti
        elem.size = frameSize
        elem.spkts = spkts
        elem.rpkts = rpkts
        table.insert(results, elem)
        print("rate="..rate..", totalReceived="..rpkts..", totalSent="..spkts..", frameLoss="..(spkts-rpkts)/spkts)
        
        local noLostFrame = spkts == rpkts
        if noLostFrame and lastNoLostFrame then
            break
        end
        lastNoLostFrame = noLostFrame
        rateMulti = rateMulti - self.granularity
        port = port + 1
        
        -- TODO: maybe wait for resettlement of DUT (RFC2544)
        
    end

    if not self.skipConf then
        self:undoConfig()
    end

    return results
end

function framelossLoadSlave(queue, port, frameSize, duration, modifier, bar)
    --wait for counter slave
    bar:wait()

    -- gen payload template suggested by RFC2544
    local udpPayloadLen = frameSize - 46
    local udpPayload = ffi.new("uint8_t[?]", udpPayloadLen)
    for i = 0, udpPayloadLen - 1 do
        udpPayload[i] = bit.band(i, 0xf)
    end

    local mem = memory.createMemPool(function(buf)
        local pkt = buf:getUdpPacket()
        pkt:fill{
            pktLength = frameSize - 4, -- self sets all length headers fields in all used protocols, -4 for FCS
            ethSrc = queue, -- get the src mac from the device
            ethDst = ethDst,
            -- if ipDest is dynamical created it is overwritten
            -- does not affect performance, as self fill is done before any packet is sent
            ip4Src = "198.18.1.2",
            ip4Dst = "198.19.1.2",
            udpSrc = UDP_PORT,
            -- udpSrc will be set later as it varies
        }
        -- fill udp payload with prepared udp payload
        ffi.copy(pkt.payload, udpPayload, udpPayloadLen)
    end)

    local bufs = mem:bufArray()
    --local modifierFoo = function () end--utils.getPktModifierFunction(modifier, baseIp, wrapIp, baseEth, wrapEth)


    local sendBufs = function(bufs, port) 
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(port)
            -- apply modifier like ip or mac randomisation to packet
            --modifierFoo(pkt)
        end
        -- send packets
        bufs:offloadUdpChecksums()
        return queue:send(bufs)
    end


    -- warmup phase to wake up card
    local timer = timer:new(0.1)
    while timer:running() do
        sendBufs(bufs, port - 1)
    end
    
    -- benchmark phase
    timer:reset(duration)
    local total = 0
    while timer:running() do
        total = total + sendBufs(bufs, port)
    end
    print("idk why it hangs here if frameSize = 1518 and i dont print something")
    return total
end

function framelossCounterSlave(queue, port, frameSize, duration, bar)
    local bufs = memory.bufArray()
    local ctrs = {}
    bar:wait()
    
    local timer = timer:new(duration + 3)
--    local stats = require "stats"
--    local rxCtr = stats:newDevRxCounter(queue.dev, "plain")
    while timer:running() do
        local rx = queue:tryRecv(bufs, 100)
        for i = 1, rx do
            local buf = bufs[i]
            local pkt = buf:getUdpPacket()
            local port = pkt.udp:getDstPort()
            ctrs[port] = (ctrs[port] or 0) + 1
            
        end
--        rxCtr:update()
        bufs:freeAll()
    end
--    rxCtr:finalize()
    return ctrs[port] or 0
end

--for standalone benchmark
if standalone then
    function configure(parser)
        parser:description("measure frameloss.")
        parser:argument("txport", "Device to transmit to."):default(1):convert(tonumber)
        parser:argument("rxport", "Device to receive from."):default(1):convert(tonumber)
        parser:argument("duration", "length of test"):default(10):convert(tonumber)
        parser:argument("granularity", "granularity"):default(10):convert(tonumber)
    end
    function master(args)
        local txPort, rxPort = args.txport, args.rxport
        if not txPort or not rxPort then
            return print("usage: --txport <txport> --rxport <rxport> --duration <duration> --granularity <granularity>")
        end
        
        local rxDev, txDev
        if txPort == rxPort then
            -- sending and receiving from the same port
            txDev = device.config({port = txPort, rxQueues = 2, txQueues = 4})
            rxDev = txDev
        else
            -- two different ports, different configuration
            txDev = device.config({port = txPort, rxQueues = 2, txQueues = 4})
            rxDev = device.config({port = rxPort, rxQueues = 2, txQueues = 3})
        end
        device.waitForLinks()
        
        local bench = benchmark()
        bench:init({
            txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3)}, 
            rxQueues = {rxDev:getRxQueue(0)},
            duration = args.duration,
            granularity = args.granularity,
            skipConf = true,
        })
        
        print(bench:getCSVHeader())
        local results = {}        
        local FRAME_SIZES   = {64, 128, 256, 512, 1024, 1280, 1518}
        for _, frameSize in ipairs(FRAME_SIZES) do
            local result = bench:bench(frameSize)
            -- save and report results
            table.insert(results, result)
            print(bench:resultToCSV(result))
        end
        bench:toTikz("frameloss", unpack(results))
    end
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
