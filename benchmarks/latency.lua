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
local ts            = require "timestamping"
local filter        = require "filter"
local ffi           = require "ffi"
local barrier       = require "barrier"
local hist          = require "histogram"
local timer         = require "timer"
local tikz          = require "utils.tikz"
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

    self.rxQueues = arg.rxQueues
    self.txQueues = arg.txQueues
    
    self.dut = arg.dut

    self.rateType = arg.ratetype

    self.maxQueues = arg.maxQueues
    self.rateLimit = arg.rateLimit
    self.settleTime = arg.settleTime

    self.ip4Src = "198.18.1.2"
    self.ip4Dst = "198.19.1.2"
    self.UDP_PORT = 42
    self.bufArrayCnt = 128 -- 128 packets per send

    self.initialized = true
end

function benchmark:getCSVHeader()
    return "latency,packet,frame size,rate,duration"
end

function benchmark:resultToCSV(result)
    local str = ""
    result:calc()
    for k ,v in ipairs(result.sortedHisto) do
            str = str .. v.k .. "," .. v.v .. "," .. result.frameSize .. "," .. result.rate .. "," .. self.duration
        if result.sortedHisto[k+1] then
            str = str .. "\n"
        end
    end
    return str
end

function benchmark:toTikz(filename, ...)
    local cdf = tikz.new(filename .. "_cdf" .. ".tikz", [[xlabel={latency [$\mu$s]}, ylabel={CDF}, grid=both, ymin=0, ymax=1, mark repeat=100, scaled ticks=false, no markers, width=9cm, height=4cm,cycle list name=exotic]])
    
    local numResults = select("#", ...)
    for i=1, numResults do
        local result = select(i, ...)
        local histo = tikz.new(filename .. "_histo" .. "_" .. result.frameSize .. ".tikz", [[xlabel={latency [$\mu$s]}, ylabel={probability [\%]}, grid=both, ybar interval, ymin=0, xtick={}, scaled ticks=false, tick label style={/pgf/number format/fixed}, x tick label as interval=false, width=9cm, height=4cm ]])
        histo:startPlot([[orange, fill=orange]])
        cdf:startPlot()
        
        result:calc()
        local numSamples = result.numSamples
        local q1,q2,q3 = result:quartiles()
        local min, max = result.sortedHisto[1].k, result.sortedHisto[#result.sortedHisto].k        
        local binWidth =  (q3 - q1) / (numSamples ^ (1/2))
        local numBins = math.ceil((max - min) / binWidth) + 1
    
        local bins = {}
        for j=1, numBins do
            bins[j] = 0
        end
        for k, v in pairs(result.histo) do
            local j = math.floor((k - min) / binWidth) + 1
            bins[j] = bins[j] + v
        end

        local prevYhist = -1
        local prevYcdf = -1
        local prevHistWritten = true -- true to ensure first sample is skipped
	local prevCdfWritten = true -- true to ensure first sample is skipped
        
        local sum = 0
        for k, v in ipairs(bins) do
            local x = (k-1) * binWidth + min

            if (v / numSamples * 100) ~= prevYhist then--only store a change
                if prevHistWritten == false then --skip first sample, and already written samples
                    histo:addPoint((x - binWidth) / 1000, prevYhist)--and then also store previous sample
                end
                histo:addPoint(x / 1000, v / numSamples * 100)
		prevHistWritten = true
            else
		prevHistWritten = false
            end
	    prevYhist = v / numSamples * 100

            sum = sum + v
            if sum / numSamples ~= prevYcdf then --only store a change
                if prevCdfWritten == false then --skip first sample and already written samples
		    cdf:addPoint((x - binWidth) / 1000, prevYcdf) --and then also store previous sample
                end
                cdf:addPoint(x / 1000, sum / numSamples)
		prevCdfWritten = true
            else
		prevCdfWritten = false
            end
            prevYcdf = sum / numSamples
        end            
        
        histo:finalize()
        cdf:endPlot(result.frameSize .. "byte")
    end
    cdf:finalize()
end

function benchmark:bench(frameSize, rate)
    if not self.initialized then
        return print("benchmark not initialized");
    elseif frameSize == nil then
        return error("benchmark got invalid frameSize");
    end


    local maxLinkRate = self.txQueues[1].dev:getLinkStatus().speed
    local bar = barrier.new(0,0)
    local port = self.UDP_PORT

    -- workaround for rate bug
    local numQueues = 1

    if rate > (64 * 64) / (84 * 84) * maxLinkRate and rate < maxLinkRate and self.maxQueues > 1 then
        if self.maxQueues == 2 then numQueues = 2 end
	if self.maxQueues > 2 then numQueues = 3 end
        printf("set queue %i to rate %d", i, rate * frameSize / (frameSize + 20) / numQueues)
	rate = rate * frameSize / (frameSize + 20) / numQueues
    end
    --allow no load tests by setting rate or maxqueues to 0
    if self.maxQueues == 0 or rate == 0 or frameSize == 0 then
	numQueues = 0
	print("INFO: load is disabled")
    else
	print("rate: " .. rate)
    end

    bar:reinit(numQueues + 1)

    local rateLimiter = {}
    local loadSlaves = {}
    -- traffic generator

    for i=1, numQueues do
	if self.rateType == "hw" then
            self.txQueues[i]:setRate(rate)
            table.insert(loadSlaves, moongen.startTask("latencyLoadSlave", self.txQueues[i], port, frameSize, self.duration, bar,self.settleTime))
	end
	if self.rateType == "cbr" then
	    print("WARNING: ratelimiter uses an extra thread/core.")
	    local delay_ns = ((frameSize + 20) * 8 ) * (1000 / rate)
	    print("inter packet delay: " .. delay_ns) 
	    rateLimiter[i] = limiter:new(self.txQueues[i], "cbr", delay_ns)
            table.insert(loadSlaves, moongen.startTask("latencyLoadSlaveCBR", self, rateLimiter[i], port, frameSize, self.duration, bar, rate))
	end
	if self.rateType == "poison" then
            table.insert(loadSlaves, moongen.startTask("latencyLoadSlavePoison", self, self.txQueues[i], port, frameSize, self.duration, bar, rate, maxLinkRate, self.settleTime))
	end
    end
    
    local hist = latencyTimerSlave(self.txQueues[numQueues+1], self.rxQueues[1], port, frameSize, self.duration, bar,self.rateLimit)
    hist:print()

    if hist.numSamples == 0 then
	print("ERROR: no packets recieved. Please check NIC connection")
	os.exit(-1)
    end
    
    local spkts = 0
    for i, sl in pairs(loadSlaves) do
        spkts = spkts + sl:wait()
        if rateLimiter[i] ~= nil then
	    rateLimiter[i]:stop()
        end
    end

    hist.frameSize = frameSize
    hist.rate = spkts / 10^6 / self.duration
    return hist
end

function latencyLoadSlave(self, queue, port, frameSize, duration, bar,settleTime)
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
        sendBufs(bufs, port + 1)
    end

    -- sync with timerSlave
    bar:wait()

    -- benchmark phase
    local totalSent = 0
    t:reset(duration + 2)
    while t:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    return totalSent
end

function latencyLoadSlaveCBR(self, queue, port, frameSize, duration, bar, rate,settleTime)
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
        sendBufs(bufs, port + 1)
    end

    --wait for counter slave
    bar:wait()

    -- benchmark phase    
    timer:reset(duration)
    local totalSent = 0
    while timer:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    return totalSent
end


function latencyLoadSlavePoison(self, queue, port, frameSize, duration, bar, rate, maxLinkRate, settleTime)
    --delay is for poison in bytes (ie 1 is 8ns on 1gb link)
--(1000000/rate)*8 --(10^12 / 8 / (rate * 10^6)) - (frameSize + 24)

    --delay in bytes per packet=           delay bytes per sec.                   /    packets per second
    --                                (bits to fill up *    bits/sec ) /byte-sec  /     (bits-rate *   bits/sec) /byte-sec / frame+20          
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
        sendBufs(bufs, port + 1)
    end

    --wait for counter slave
    bar:wait()

    -- benchmark phase    
    timer:reset(duration)
    local totalSent = 0
    while timer:running() do
        totalSent = totalSent + sendBufs(bufs, port)
    end
    return totalSent
end


function latencyTimerSlave(txQueue, rxQueue, port, frameSize, duration, bar,rateLimit)
    --Timestamped packets must be > 80 bytes (+4crc)
    frameSize = frameSize > 84 and frameSize or 84
        
    rxQueue:filterL2Timestamps(rxQueue)
    local timestamper = ts:newTimestamper(txQueue, rxQueue)
    local hist = hist:new()
    local rateLimit = timer:new(rateLimit)

    -- sync with load slave and wait additional few milliseconds to ensure 
    -- the traffic generator has started
    bar:wait()
    moongen.sleepMillis(1000)
    
    local t = timer:new(duration)
    while t:running() do
        hist:update(timestamper:measureLatency(frameSize - 4, function(buf)
        end))
        rateLimit:wait()
        rateLimit:reset()
    end
    return hist
end

--for standalone benchmark
if standalone then
    function configure(parser)
        parser:description("measure latencies.")
        parser:argument("txport", "Device to transmit to."):default(0):convert(tonumber)
        parser:argument("rxport", "Device to receive from."):default(0):convert(tonumber)
        parser:option("-d --duration", "length of test"):default(1):convert(tonumber)
        parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
       parser:option("-q --maxQueues", "<max load queues>"):default(1):convert(tonumber)
        parser:option("-x --rateLimit", "<time to wait between latency measures>"):default(0.001):convert(tonumber)
        parser:option("-k --settleTime", "time to warm up>"):default(0.1):convert(tonumber)
	parser:option("-f --folder", "folder"):default("testresults")
	parser:option("-t --ratetype", "rate type (hw,cbr,poison)"):default("cbr")
	parser:option("-s --fs", "frame sizes e.g;'64 128 ..'"):default("64,128,256,512,1024,1280,1518")
	parser:flag("-o --overwrite", "overwrite rates"):default(false)
    end
    function master(args)
        --local args = utils.parseArguments(arg)
        local txPort, rxPort = args.txport, args.rxport
        if not txPort or not rxPort then
            return print("usage: --txport <txport> --rxport <rxport> --duration <duration> --rate <rate>")
        end
        
        local disableOffloads = false
	if args.ratetype ~= "posion" then --if posion is not the type, disable the offloads
	    disableOffloads = true
	end

        local rxDev, txDev
        if txPort == rxPort then
            -- sending and receiving from the same port
            txDev = device.config({port = txPort, rxQueues = 3, txQueues = 5, disableOffloads })
            rxDev = txDev
        else
            -- two different ports, different configuration
            txDev = device.config({port = txPort, rxQueues = 2, txQueues = 5, disableOffloads })
            rxDev = device.config({port = rxPort, rxQueues = 3, txQueues = 1})
        end
        device.waitForLinks()
             
	local folderName = args.folder
	local report = testreport.new(folderName .. "/rfc_2544_testreport.tex")
	local results = {}
	
	-- start test        
	local bench = benchmark()
        bench:init({
            txQueues = {txDev:getTxQueue(1), txDev:getTxQueue(2), txDev:getTxQueue(3), txDev:getTxQueue(4)}, 
            rxQueues = {rxDev:getRxQueue(2)}, 
            duration = args.duration,
	    ratetype = args.ratetype,

	    maxQueues = args.maxQueues,
	    settleTime = args.settleTime,
	    rateLimit = args.rateLimit,

        })
        
        local FRAME_SIZES = {}
	local fram_siz_t = Split(args.fs,",")
	for index,item in ipairs(fram_siz_t) do
		FRAME_SIZES[index] = tonumber(item)
        end


	local rates_arr = {}
	if args.overwrite == false then
            print("using " .. folderName .. "/rates.txt for rate setting")
	    local ratefile = io.open(folderName .. "/rates.txt", "r")
            if ratefile == nil then
                return print("ERROR: could not open ratefile: " .. folderName .. "/rates.txt")
            end
	    for line in ratefile:lines() do
                local cols = Split(line,",")
                --table.insert(rates_arr, cols[0])
	        rates_arr[ tonumber(cols[1]) ] = tonumber(cols[2])
	    end
            ratefile:close()
        else
            print("NOT using rates.txt for rate setting")
        end
	
	file = io.open(folderName .. "/latency.csv", "w")
	log(file, bench:getCSVHeader(), true)
	for _, frameSize in ipairs(FRAME_SIZES) do
            local result
	    local rate = args.rate
            if rates_arr[frameSize] ~= nil then
		-- calulate mbit rate from mega-packets-per-second(mpps)
		print("rate mpps: " .. rates_arr[frameSize])
		rate = rates_arr[frameSize] * (frameSize + 20) * 8
            end	
            result = bench:bench(frameSize, rate )
	    -- save and report results        
	    table.insert(results, result)
	    log(file, bench:resultToCSV(result), true)
	    report:addLatency(result, args.duration) -- TODO: add stdeviation in report
	end
	bench:toTikz(folderName .. "/plot_latency", unpack(results))
	file:close()
	-- finalize test
	report:append()
    end
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
