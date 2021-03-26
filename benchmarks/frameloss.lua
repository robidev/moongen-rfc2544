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
local testreport    = require "utils.testreport"
local limiter = require "software-ratecontrol"

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
    self.granularity = arg.granularity
    
    self.rxQueues = arg.rxQueues
    self.txQueues = arg.txQueues
    
    self.dut = arg.dut

    self.rateType = arg.ratetype

    self.maxQueues = arg.maxQueues
    self.settleTime = arg.settleTime

    self.ip4Src = "198.18.1.2"
    self.ip4Dst = "198.19.1.2"
    self.UDP_PORT = 42
    self.bufArrayCnt = 128 -- 128 packets per send (can be used to send more/less packets per iteration)   

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

    local maxLinkRate = self.txQueues[1].dev:getLinkStatus().speed
    local rateMulti = 1
    local bar = barrier.new(2,2)
    local results = {}
    local port = self.UDP_PORT
    local lastNoLostFrame = false
    
    -- loop until no packetloss
    while moongen.running() and rateMulti >= 0.05 do
        -- set rate
        local rate = maxLinkRate * rateMulti
        
        -- workaround for rate bug
	local numQueues = 1
	if rate > (64 * 64) / (84 * 84) * maxLinkRate and rate < maxLinkRate and self.maxQueues > 1 then
	    if self.maxQueues == 2 then numQueues = 2 end
	    if self.maxQueues > 2 then numQueues = 3 end
	    printf("set queue %i to rate %d (maxLinkRate %d)", i, rate * frameSize / (frameSize + 20) / numQueues, maxLinkRate)
	    rate = rate * frameSize / (frameSize + 20) / numQueues
	end

        bar:reinit(numQueues + 1)

        --check if rate goes above link rate
        if(rate > maxLinkRate) then
	    printf("WARNING: no more options for framerate to reduce packet loss, quitting at rate %d", rate)
	    break	
        end

        local rateLimiter = {}
        local loadTasks = {}
        -- traffic generator
        print("rate: " .. rate)
        for i=1, numQueues do
	    if self.rateType == "hw" then
	    	self.txQueues[i]:setRate(rate)
            	table.insert(loadTasks, moongen.startTask("framelossLoadSlave", self, self.txQueues[i], port, frameSize, self.duration, bar, self.settleTime))
	    end
	    if self.rateType == "cbr" then
	    	print("WARNING: ratelimiter uses an extra thread/core.")
	    	local delay_ns = ((frameSize + 20) * 8 ) * (1000/rate) 
	    	print("inter packet delay: " .. delay_ns) 
	    	rateLimiter[i] = limiter:new(self.txQueues[i], "cbr", delay_ns)
            	table.insert(loadTasks, moongen.startTask("framelossLoadSlaveCBR", self, rateLimiter[i], port, frameSize, self.duration, bar, rate))
	    end
	    if self.rateType == "poison" then
            	table.insert(loadTasks, moongen.startTask("framelossLoadSlavePoison", self, self.txQueues[i], port, frameSize, self.duration, bar, rate, maxLinkRate, self.settleTime))
	    end
        end
        
        -- count the incoming packets
        local ctrTask = moongen.startTask("framelossCounterSlave", self.rxQueues[1], port, frameSize, self.duration, bar)
        
        -- wait until all slaves are finished
        local spkts = 0
        for i, loadTask in ipairs(loadTasks) do
            spkts = spkts + loadTask:wait()
	    if rateLimiter[i] ~= nil then
		rateLimiter[i]:stop()
	    end
        end
        local rpkts = ctrTask:wait()
        
        
        local elem = {}
        elem.multi = rateMulti
        elem.size = frameSize
        elem.spkts = spkts
        elem.rpkts = rpkts
        table.insert(results, elem)
        print("rate="..rate..", totalReceived="..rpkts..", totalSent="..spkts..", frameLoss="..(spkts-rpkts)/spkts)
        if rpkts == 0 then
	    print("ERROR: no packets recieved. Please check NIC connection")
	    os.exit(-1)
	end
        local noLostFrame = spkts == rpkts
        if noLostFrame and lastNoLostFrame then
            break
        end
        lastNoLostFrame = noLostFrame
        rateMulti = rateMulti - self.granularity
        port = port + 1
        
        -- TODO: maybe wait for resettlement of DUT (RFC2544)
        
    end

    return results
end

function framelossLoadSlave(self, queue, port, frameSize, duration, bar,settleTime)
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
            ip4Src = self.ip4Src,
            ip4Dst = self.ip4Dst,
            udpSrc = self.UDP_PORT,
            -- udpSrc will be set later as it varies
        }
        -- fill udp payload with prepared udp payload
        ffi.copy(pkt.payload, udpPayload, udpPayloadLen)
    end)

    local bufs = mem:bufArray()

    local sendBufs = function(bufs, port) 
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(port)
        end
        -- send packets
        bufs:offloadUdpChecksums()
        return queue:send(bufs)
    end
    -- warmup phase to wake up card
    local timer = timer:new(settleTime)
    while timer:running() do
        sendBufs(bufs, port - 1)
    end

    -- benchmark phase    
    timer:reset(duration)
    local totalSent = 0
    while timer:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    --print("idk why it hangs here if frameSize = 1518 and i dont print something")
    return totalSent
end


function framelossLoadSlaveCBR(self, queue, port, frameSize, duration, bar, rate,settleTime)
    --wait for counter slave
    bar:wait()
    -- gen payload template suggested by RFC2544
    local udpPayloadLen = frameSize - 46
    local udpPayload = ffi.new("uint8_t[?]", udpPayloadLen)
    for i = 0, udpPayloadLen - 1 do
        udpPayload[i] = bit.band(i, 0xf)
    end

    local mem = memory.createMemPool(4096, function(buf)
        local pkt = buf:getUdpPacket()
        pkt:fill{
            pktLength = frameSize,-- - 4, -- self sets all length headers fields in all used protocols, -4 for FCS
            ethSrc = queue, -- get the src mac from the device
            ethDst = ethDst,
            ip4Src = self.ip4Src,
            ip4Dst = self.ip4Dst,
            udpSrc = self.UDP_PORT,
            -- udpDst will be set later as it varies
        }
        -- fill udp payload with prepared udp payload
        ffi.copy(pkt.payload, udpPayload, udpPayloadLen)
    end)

    local bufs = mem:bufArray(self.bufArrayCnt)--send one packet

    local sendBufs = function(bufs, port) 
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize)-- - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(port)
        end
        -- send packets
        --bufs:offloadUdpChecksums() --TODO is this needed? seems to have no effect
	queue:sendN(bufs,self.bufArrayCnt) --send x packets
	return self.bufArrayCnt--x packets send
    end
    -- warmup phase to wake up card
    local timer = timer:new(settleTime)
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


function framelossLoadSlavePoison(self, queue, port, frameSize, duration, bar, rate, maxLinkRate, settleTime)
    --wait for counter slave
    bar:wait()
    --delay is for poison in bytes (ie 1 is 8ns on 1gb link)
--(1000000/rate)*8 --(10^12 / 8 / (rate * 10^6)) - (frameSize + 24)

    --delay in bytes per packet=   delay bytes per sec.    /    packets per second
    local delay =               (((maxLinkRate - rate)*(10^6 * maxLinkRate)) /8 )  / ( (rate*(10^6 * maxLinkRate)) / 8 / (frameSize + 20) )

    --local rate_mpps = rate / 8 / (frameSize + 24)
    --local delay = 10^9 / 8 / (rate_mpps * 10^6) - frameSize - 24
    if delay < 0 then
        delay = 0
    end
    print("delay:" .. delay )
    -- gen payload template suggested by RFC2544
    local udpPayloadLen = frameSize - 46
    local udpPayload = ffi.new("uint8_t[?]", udpPayloadLen)
    for i = 0, udpPayloadLen - 1 do
        udpPayload[i] = bit.band(i, 0xf)
    end

    local mem = memory.createMemPool(4096, function(buf)
        local pkt = buf:getUdpPacket()
        pkt:fill{
            pktLength = frameSize,-- - 4, -- self sets all length headers fields in all used protocols, -4 for FCS
            ethSrc = queue, -- get the src mac from the device
            ethDst = ethDst,
            ip4Src = self.ip4Src,
            ip4Dst = self.ip4Dst,
            udpSrc = self.UDP_PORT,
            -- udpDst will be set later as it varies
        }
        -- fill udp payload with prepared udp payload
        ffi.copy(pkt.payload, udpPayload, udpPayloadLen)
    end)

    local bufs = mem:bufArray(self.bufArrayCnt)

    local sendBufs = function(bufs, port) 
        -- allocate buffers from the mem pool and store them in self array
        bufs:alloc(frameSize)-- - 4)

        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            -- set packet udp port
            pkt.udp:setDstPort(port)
            buf:setDelay(delay) -- poissonDelay(delay) for randomized delay
	    
        end
        -- send packets
        bufs:offloadUdpChecksums() --TODO is this needed?
        return queue:sendWithDelay(bufs)
    end
    -- warmup phase to wake up card
    local timer = timer:new(settleTime)
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
        parser:argument("txport", "Device to transmit to."):default(0):convert(tonumber)
        parser:argument("rxport", "Device to receive from."):default(0):convert(tonumber)
        parser:option("-d --duration", "length of test"):default(1):convert(tonumber)
        parser:option("-g --granularity", "granularity"):default(0.5):convert(tonumber)
        parser:option("-q --maxQueues", "<max load queues>"):default(1):convert(tonumber)
        parser:option("-k --settleTime", "time to warm up>"):default(0.1):convert(tonumber)
	parser:option("-f --folder", "folder"):default("testresults")
	parser:option("-t --ratetype", "rate type (hw,cbr,poison)"):default("cbr")
	parser:option("-s --fs", "frame sizes e.g;'64 128 ..'"):default("64,128,256,512,1024,1280,1518")
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
        
	local folderName = args.folder
	local report = testreport.new(folderName .. "/rfc_2544_testreport.tex")
	local results = {}

	-- start test
        local bench = benchmark()
        bench:init({
            txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3)}, 
            rxQueues = {rxDev:getRxQueue(0)},
            duration = args.duration,
            granularity = args.granularity,
	    ratetype = args.ratetype,

	    maxQueues = args.maxQueues,
	    settleTime = args.settleTime,
        })
        
	local FRAME_SIZES = {}
	local fram_siz_t = Split(args.fs,",")
	for index,item in ipairs(fram_siz_t) do
		FRAME_SIZES[index] = tonumber(item)
        end

	file = io.open(folderName .. "/frameloss.csv", "w")
	log(file, bench:getCSVHeader(), true)
	for _, frameSize in ipairs(FRAME_SIZES) do
		local result = bench:bench(frameSize)
		
		-- save and report results
		table.insert(results, result)
		log(file, bench:resultToCSV(result), true)
		report:addFrameloss(result, args.duration)
	end
	bench:toTikz(folderName .. "/plot_frameloss", unpack(results))
	file:close()
	-- finalize test
	report:append()
    end
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
