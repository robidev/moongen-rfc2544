package.path = package.path .. "rfc2544/?.lua"

local standalone = false
if master == nil then
        standalone = true
        master = "dummy"
end

local moongen       = require "moongen"
local dpdk          = require "dpdk"
local memory        = require "memory"
local device        = require "device"
local filter        = require "filter"
local ffi           = require "ffi"
local barrier       = require "barrier"
local timer         = require "timer"
local tikz          = require "utils.tikz"
local utils         = require "utils.utils"
local testreport    = require "utils.testreport"
--local limiter = require "software-ratecontrol"

function log(file, msg, linebreak)
    print(msg)
    file:write(msg)
    if linebreak then
        file:write("\n")
    end
end

local function Split(str,sep)
   local ret={}
   local n=1
   for w in str:gmatch("([^"..sep.."]*)") do
      ret[n] = ret[n] or w -- only set once (so the blank after a string is ignored)
      if w=="" then
         n = n + 1
      end -- step forwards on a blank but not a string
   end
   return ret
end

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
    self.duration = arg.duration
    self.rateThreshold = arg.rateThreshold
    self.maxLossRate = arg.maxLossRate

    self.rxQueues = arg.rxQueues
    self.txQueues = arg.txQueues

    self.numIterations = arg.numIterations
    
    self.skipConf = arg.skipConf
    self.dut = arg.dut

    self.rateType = arg.ratetype

    self.initialized = true
end

function benchmark:config()
end

function benchmark:undoConfig()
end

function benchmark:getCSVHeader()
    local str = "frame size(byte),duration(s),max loss rate(%),rate threshold(packets)"
    for i=1, self.numIterations do
        str = str .. "," .. "rate(mpps) iter" .. i .. ",spkts(byte) iter" .. i .. ",rpkts(byte) iter" .. i
    end
    return str
end

function benchmark:resultToCSV(result)
    local str = ""
    for i=1, self.numIterations do
        str = str .. result[i].frameSize .. "," .. self.duration .. "," .. self.maxLossRate * 100 .. "," .. self.rateThreshold .. "," .. result[i].mpps .. "," .. result[i].spkts .. "," .. result[i].rpkts
        if i < self.numIterations then
            str = str .. "\n"
        end
    end
    return str
end

function benchmark:toTikz(filename, ...)
    local values = {}
    
    local numResults = select("#", ...)
    for i=1, numResults do
        local result = select(i, ...)
        
        local avg = 0
        local numVals = 0
        local frameSize
        for _, v in ipairs(result) do
            frameSize = v.frameSize
            avg = avg + v.mpps
            numVals = numVals + 1
        end
        avg = avg / numVals
        
        table.insert(values, {k = frameSize, v = avg})
    end
    table.sort(values, function(e1, e2) return e1.k < e2.k end)
    
    
    local xtick = ""
    local t64 = false
    local last = -math.huge
    for k, p in ipairs(values) do
        if (p.k - last) >= 128 then
            xtick = xtick .. p.k            
            if values[k + 1] then
                xtick = xtick .. ","
            end
            last = p.k
        end
    end
    
    
    local imgMpps = tikz.new(filename .. "_mpps" .. ".tikz", [[ xlabel={packet size [byte]}, ylabel={rate [Mpps]}, grid=both, ymin=0, xmin=0, xtick={]] .. xtick .. [[},scaled ticks=false, width=9cm, height=4cm, cycle list name=exotic]])
    local imgMbps = tikz.new(filename .. "_mbps" .. ".tikz", [[ xlabel={packet size [byte]}, ylabel={rate [Gbit/s]}, grid=both, ymin=0, xmin=0, xtick={]] .. xtick .. [[},scaled ticks=false, width=9cm, height=4cm, cycle list name=exotic,legend style={at={(0.99,0.02)},anchor=south east}]])
    
    imgMpps:startPlot()
    imgMbps:startPlot()
    for _, p in ipairs(values) do
        imgMpps:addPoint(p.k, p.v)
        imgMbps:addPoint(p.k, p.v * (p.k + 20) * 8 / 1000)
    end
    local legend = "throughput at max " .. self.maxLossRate * 100 .. " \\% packet loss"
    imgMpps:endPlot(legend)
    imgMbps:endPlot(legend)
    
    imgMpps:startPlot()
    imgMbps:startPlot()
    for _, p in ipairs(values) do
        local linkRate = self.txQueues[1].dev:getLinkStatus().speed
        imgMpps:addPoint(p.k, linkRate / (p.k + 20) / 8)
        imgMbps:addPoint(p.k, linkRate / 1000)
    end
    imgMpps:finalize("link rate")
    imgMbps:finalize("link rate")
end

function benchmark:bench(frameSize)
    if not self.initialized then
        return print("benchmark not initialized");
    elseif frameSize == nil then
        return error("benchmark got invalid frameSize");
    end

    if not self.skipConf then
        self:config()
    end

    local binSearch = utils.binarySearch()
    local pktLost = true
    local maxLinkRate = self.txQueues[1].dev:getLinkStatus().speed
    local rate, lastRate
    local bar = barrier.new(2,2)
    local results = {}
    local rateSum = 0
    local finished = false

    --repeat the test for statistical purpose
    for iteration=1,self.numIterations do
        local port = UDP_PORT
        binSearch:init(0, maxLinkRate)
        rate = maxLinkRate -- start at maximum, so theres a chance at reaching maximum (otherwise only maximum - threshold can be reached)
        lastRate = rate

        printf("starting iteration %d for frameSize %d", iteration, frameSize)
        --init maximal transfer rate without packetloss of this iteration to zero
        results[iteration] = {spkts = 0, rpkts = 0, mpps = 0, frameSize = frameSize}
        -- loop until no packetloss
        while moongen.running() do
            -- workaround for rate bug
            local numQueues = 1 --rate > (64 * 64) / (84 * 84) * maxLinkRate and rate < maxLinkRate and 3 or 1
            bar:reinit(numQueues + 1)
	    if self.rateType == "hw" then
		    if rate < maxLinkRate then
		        -- not maxLinkRate
		        -- eventual multiple slaves
		        -- set rate is payload rate not wire rate
		        for i=1, numQueues do
		            printf("set queue %i to rate %d", i, rate * frameSize / (frameSize + 20) / numQueues)
		            self.txQueues[i]:setRate(rate * frameSize / (frameSize + 20) / numQueues)
		        end
		    else
		        -- maxLinkRate
		        self.txQueues[1]:setRate(rate)
		    end
            end
            
            local loadTasks = {}
            -- traffic generator
            for i=1, numQueues do
		if self.rateType == "hw" then
                    table.insert(loadTasks, moongen.startTask("throughputLoadSlave", self.txQueues[i], port, frameSize, self.duration, mod, bar))
		end
		if self.rateType == "cbr" then
                    table.insert(loadTasks, moongen.startTask("throughputLoadSlaveCBR", self.txQueues[i], port, frameSize, self.duration, mod, bar, rate))
		end
		if self.rateType == "poison" then
                    table.insert(loadTasks, moongen.startTask("throughputLoadSlavePoison", self.txQueues[i], port, frameSize, self.duration, mod, bar, rate))
		end
            end
            
            -- count the incoming packets
            local ctrTask = moongen.startTask("throughputCounterSlave", self.rxQueues[1], port, frameSize, self.duration, bar)
            
            -- wait until all slaves are finished
            local spkts = 0
            for i, loadTask in pairs(loadTasks) do
                spkts = spkts + loadTask:wait()
            end
            local rpkts = ctrTask:wait()

            local lossRate = (spkts - rpkts) / spkts
            local validRun = lossRate <= self.maxLossRate
            if validRun then
                -- theres a minimal gap between self.duration and the real measured duration, but that
                -- doesnt matter
                results[iteration] = { spkts = spkts, rpkts = rpkts, mpps = spkts / 10^6 / self.duration, frameSize = frameSize}
            end
            
            printf("sent %d packets, received %d", spkts, rpkts)
            printf("rate %f and packetloss %f => %d", rate, lossRate, validRun and 1 or 0)
            
            lastRate = rate
            rate, finished = binSearch:next(rate, validRun, self.rateThreshold)
            if finished then
                -- not setting rate in table as it is not guaranteed that last round all
                -- packets were received properly
                local mpps = results[iteration].mpps
                printf("maximal rate for packetsize %d: %0.2f Mpps, %0.2f MBit/s, %0.2f MBit/s wire rate", frameSize, mpps, mpps * frameSize * 8, mpps * (frameSize + 20) * 8)
                rateSum = rateSum + results[iteration].mpps
                break
            end

            printf("changing rate from %d MBit/s to %d MBit/s", lastRate, rate)
            -- TODO: maybe wait for resettlement of DUT (RFC2544)
            port = port + 1
	    moongen.sleepMillis(100)
        --device.reclaimTxBuffers()
        end
    end

    if not self.skipConf then
        self:undoConfig()
    end

    return results, rateSum / self.numIterations
end

function throughputLoadSlave(queue, port, frameSize, duration, modifier, bar)
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
            -- TODO: too slow with conditional -- eventual launch a second slave for self
            -- ethDst SHOULD be in 1% of the frames the hardware broadcast address
            -- for switches ethDst also SHOULD be randomized

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
    --local modifierFoo = utils.getPktModifierFunction(modifier, baseIp, wrapIp, baseEth, wrapEth)


    local sendBufs = function(bufs, port) 
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(port)
            -- apply modifier like ip or mac randomisation to packet
--          modifierFoo(pkt)
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
    local totalSent = 0
    while timer:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    return totalSent
end


function throughputLoadSlaveCBR(queue, port, frameSize, duration, modifier, bar, rate)
    --wait for counter slave
    bar:wait()
    local delay = (10^12 / 8 / (rate * 10^6)) - (frameSize + 24)
    if delay < 0 then
        delay = 0
    end
    print( delay )
    -- gen payload template suggested by RFC2544
    local udpPayloadLen = frameSize - 46
    local udpPayload = ffi.new("uint8_t[?]", udpPayloadLen)
    for i = 0, udpPayloadLen - 1 do
        udpPayload[i] = bit.band(i, 0xf)
    end

    local mem = memory.createMemPool(4096, function(buf)
        local pkt = buf:getUdpPacket()
        pkt:fill{
            pktLength = frameSize - 4, -- self sets all length headers fields in all used protocols, -4 for FCS
            ethSrc = queue, -- get the src mac from the device
            ethDst = ethDst,
            -- TODO: too slow with conditional -- eventual launch a second slave for self
            -- ethDst SHOULD be in 1% of the frames the hardware broadcast address
            -- for switches ethDst also SHOULD be randomized

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
    --local modifierFoo = utils.getPktModifierFunction(modifier, baseIp, wrapIp, baseEth, wrapEth)


    local sendBufs = function(bufs, port) 
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize)-- - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(port)
            buf:setDelay( delay )
        end
        -- send packets
        bufs:offloadUdpChecksums() --TODO is this needed?
        return queue:sendWithDelay(bufs)
    end
    -- warmup phase to wake up card
    local timer = timer:new(0.1)
    while timer:running() do
        sendBufs(bufs, port - 1)
    end

    -- benchmark phase    
    timer:reset(duration)
    local totalSent = 0
    while timer:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    return totalSent
end


function throughputLoadSlavePoison(queue, port, frameSize, duration, modifier, bar, rate)
    --wait for counter slave
    bar:wait()
    local delay = (10^12 / 8 / (rate * 10^6)) - (frameSize + 24)
    if delay < 0 then
        delay = 0
    end
    print( delay )
    -- gen payload template suggested by RFC2544
    local udpPayloadLen = frameSize - 46
    local udpPayload = ffi.new("uint8_t[?]", udpPayloadLen)
    for i = 0, udpPayloadLen - 1 do
        udpPayload[i] = bit.band(i, 0xf)
    end

    local mem = memory.createMemPool(4096, function(buf)
        local pkt = buf:getUdpPacket()
        pkt:fill{
            pktLength = frameSize - 4, -- self sets all length headers fields in all used protocols, -4 for FCS
            ethSrc = queue, -- get the src mac from the device
            ethDst = ethDst,
            -- TODO: too slow with conditional -- eventual launch a second slave for self
            -- ethDst SHOULD be in 1% of the frames the hardware broadcast address
            -- for switches ethDst also SHOULD be randomized

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
    --local modifierFoo = utils.getPktModifierFunction(modifier, baseIp, wrapIp, baseEth, wrapEth)


    local sendBufs = function(bufs, port) 
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize)-- - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(port)
            buf:setDelay(poissonDelay(delay))
	    
        end
        -- send packets
        bufs:offloadUdpChecksums() --TODO is this needed?
        return queue:sendWithDelay(bufs)
    end
    -- warmup phase to wake up card
    local timer = timer:new(0.1)
    while timer:running() do
        sendBufs(bufs, port - 1)
    end

    -- benchmark phase    
    timer:reset(duration)
    local totalSent = 0
    while timer:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    return totalSent
end

function throughputCounterSlave(queue, port, frameSize, duration, bar)
    local bufs = memory.bufArray()
    local stats = {}
    bar:wait()

    local timer = timer:new(duration + 3)
    while timer:running() do
        local rx = queue:tryRecv(bufs, 1000)
        for i = 1, rx do
            local buf = bufs[i]
            local pkt = buf:getUdpPacket()
            local port = pkt.udp:getDstPort()
            stats[port] = (stats[port] or 0) + 1
        end
        bufs:freeAll()
    end
    return stats[port] or 0
end

--for standalone benchmark
if standalone then
    function configure(parser)
        parser:description("measure throughput.")
        parser:argument("txport", "Device to transmit to."):default(0):convert(tonumber)
        parser:argument("rxport", "Device to receive from."):default(0):convert(tonumber)
        parser:option("-d --duration", "length of test"):default(1):convert(tonumber)
        parser:option("-n --numiterations", "number of iterations"):default(1):convert(tonumber)
        parser:option("-r --rths", "<throughput rate threshold>"):default(100):convert(tonumber)
        parser:option("-m --mlr", "<max throuput loss rate>"):default(0.1):convert(tonumber)
	parser:option("-f --folder", "folder"):default("testresults")
	parser:option("-t --ratetype", "rate type (hw,cbr,poison)"):default("cbr")
	parser:option("-s --fs", "frame sizes e.g;'64 128 ..'"):default("64,128,256,512,1024,1280,1518")
    end
    function master(args)
        local txPort, rxPort = args.txport, args.rxport
        if not txPort or not rxPort then
            return print("usage: --txport <txport> --rxport <rxport>")
        end
        
        local rxDev, txDev
        if txPort == rxPort then
            -- sending and receiving from the same port
            txDev = device.config({port = txPort, rxQueues = 2, txQueues = 4, disableOffloads = args.ratetype == "hw"})
            rxDev = txDev
        else
            -- two different ports, different configuration
            txDev = device.config({port = txPort, rxQueues = 2, txQueues = 4, disableOffloads = args.ratetype == "hw"})
            rxDev = device.config({port = rxPort, rxQueues = 2, txQueues = 3})
        end
        device.waitForLinks()
        
	local folderName = args.folder
	local report = testreport.new(folderName .. "/rfc_2544_testreport.tex")
	local results = {}

	-- start test
        local bench = benchmark()
        bench:init({
            txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3)}, 
            rxQueues = {rxDev:getRxQueue(0)}, 
            duration = args.duration,
            numIterations = args.numiterations,
	    rateThreshold = args.rths,
	    maxLossRate = args.mlr,
	    ratetype = args.ratetype,
            skipConf = true,
        })
        
	local FRAME_SIZES = {}
	local fram_siz_t = Split(args.fs,",")
	for index,item in ipairs(fram_siz_t) do
		FRAME_SIZES[index] = tonumber(item)
        end
	

	local rates = {}
	local file = io.open(folderName .. "/throughput.csv", "w")
	local ratefile = io.open(folderName .. "/rates.txt", "w")
	log(file, bench:getCSVHeader(), true)
	for _, frameSize in ipairs(FRAME_SIZES) do
	    local result, avgRate = bench:bench(frameSize)
	    rates[frameSize] = avgRate
            ratefile:write(frameSize .. " : " .. avgRate .. "\n")

	    -- save and report results
	    table.insert(results, result)
	    log(file, bench:resultToCSV(result), true)
	    report:addThroughput(result, args.duration, args.mlr, args.rths)
	end
	bench:toTikz(folderName .. "/plot_throughput", unpack(results))
	file:close()
	ratefile:close()
	-- finalize test
	report:append()

    end
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
