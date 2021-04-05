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
local timer         = require "timer"
local namespaces    = require "namespaces"
local utils         = require "utils.utils"
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
    self.granularity = arg.granularity
    self.duration = arg.duration
    self.numIterations = arg.numIterations
    
    self.rxQueues = arg.rxQueues
    self.txQueues = arg.txQueues
    
    self.dut = arg.dut

    self.rateType = arg.ratetype

    self.ip4Src = "198.18.1.2"
    self.ip4Dst = "198.19.1.2"
    self.UDP_PORT = 42
    self.bufArrayCnt = 128 -- 128 packets per send
    
    self.initialized = true
end

function benchmark:getCSVHeader()
    local str = "frameSize,precision,linkspeed,duration"
    for iteration=1, self.numIterations do
        str = str .. ",burstsize iter" .. iteration
    end
    return str
end

function benchmark:resultToCSV(result)
    str = result.frameSize .. "," .. self.granularity .. "," .. self.txQueues[1].dev:getLinkStatus().speed .. "," .. self.duration .. "s" 
    for iteration=1, self.numIterations do
        str = str .. "," .. result[iteration]
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
        for _, v in ipairs(result) do
            avg = avg + v
            numVals = numVals + 1
        end
        avg = avg / numVals
        
        table.insert(values, {k = result.frameSize, v = avg})
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
    
    local img = tikz.new(filename .. ".tikz", [[xlabel={packet size [byte]}, ylabel={burst size [packet]}, grid=both, ymin=0, xmin=0, xtick={]] .. xtick .. [[},scaled ticks=false, width=9cm, height=4cm, cycle list name=exotic]])
    
    img:startPlot()
    for _, p in ipairs(values) do
        img:addPoint(p.k, p.v)
    end
    img:endPlot("average burst size")
    
    img:startPlot()
    for _, p in ipairs(values) do
        local v = math.ceil((self.txQueues[1].dev:getLinkStatus().speed * 10^6 / ((p.k + 20) * 8)) * self.duration)
        img:addPoint(p.k, v)
    end
    img:finalize("max burst size")
end

function benchmark:bench(frameSize)
    if not self.initialized then
        return print("benchmark not initialized");
    elseif frameSize == nil then
        return error("benchmark got invalid frameSize");
    end
    
    local port = self.UDP_PORT
    local bar = barrier.new(2,2)
    local results = {frameSize = frameSize}
    
    
    for iteration=1, self.numIterations do
        printf("starting iteration %d for frame size %d", iteration, frameSize)
        local rateLimiter
        local loadSlave
	if self.rateType == "hw" then
	    loadSlave = moongen.startTask("backtobackLoadSlave", self.txQueues[1], frameSize, bar, self.granularity, self.duration)
	end
	if self.rateType == "cbr" then
	    print("WARNING: ratelimiter uses an extra thread/core.")
	    local delay_ns = ((frameSize + 20) * 8 ) * (1000/10) --fixed at 10 mbit
	    print("inter packet delay: " .. delay_ns) 
	    rateLimiter = limiter:new(self.txQueues[1], "cbr", delay_ns)
	    loadSlave = moongen.startTask("backtobackLoadSlaveCBR", self, self.txQueues[1], rateLimiter, frameSize, bar, self.granularity, self.duration)
	end
	if self.rateType == "poison" then
	    loadSlave = moongen.startTask("backtobackLoadSlavePoison", self, self.txQueues[1], frameSize, bar, self.granularity, self.duration)
	end
        local counterSlave = moongen.startTask("backtobackCounterSlave", self, self.rxQueues[1], frameSize, bar, self.granularity, self.duration)
        
        local longestS = loadSlave:wait()
        local longestR = counterSlave:wait()

	if rateLimiter ~= nil then
	    rateLimiter:stop()
	end

	if longestR == 0 then
	    print("ERROR: no packets recieved. Please check NIC connection")
	    os.exit(-1)
	end
        
        if longest ~= loadSlave:wait() then
            printf("WARNING: loadSlave and counterSlave reported different burst sizes (sender=%d, receiver=%d)", longestS, longestR)
            results[iteration] = -1
        else
            results[iteration] = longestS
            printf("iteration %d: longest burst: %d", iteration, longestS)
        end

	moongen.sleepMillis(2000)
    end
    
    return results
end

local rsns = namespaces.get()

function sendBurst(numPkts, mem, queue, size, port)
    local sent = 0
    local bufs = mem:bufArray(64)
    local stop = numPkts - (numPkts % 64)
    while moongen.running() and sent < stop do
        bufs:alloc(size)
        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            pkt.udp:setDstPort(port)
        end
        bufs:offloadUdpChecksums()
        sent = sent + queue:send(bufs)
        
    end
    if numPkts ~= stop then
        bufs = mem:bufArray(numPkts % 64)
        bufs:alloc(size)
        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            pkt.udp:setDstPort(port)
        end
        bufs:offloadUdpChecksums()
        sent = sent + queue:send(bufs)
    end
    return sent    
end

function sendBurstDelayCBR(numPkts, mem, queue, size, port)
    local sent = 0
    local bufs = mem:bufArray(64)
    local stop = numPkts - (numPkts % 64)
    while moongen.running() and sent < stop do
        bufs:alloc(size)
        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            pkt.udp:setDstPort(port)
	    --buf:setDelay( delay )
        end
        --bufs:offloadUdpChecksums()
	queue:send(bufs)
        sent = sent + 64
        
    end
    if numPkts ~= stop then
        bufs = mem:bufArray(numPkts % 64)
        bufs:alloc(size)
        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            pkt.udp:setDstPort(port)
            --buf:setDelay( delay )
        end
        --bufs:offloadUdpChecksums()
	queue:send(bufs)
        sent = sent + (numPkts % 64)
    end
    return sent    
end

function sendBurstDelayPoison(numPkts, mem, queue, size, port, delay)
    local sent = 0
    local bufs = mem:bufArray(64)
    local stop = numPkts - (numPkts % 64)
    while moongen.running() and sent < stop do
        bufs:alloc(size)
        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            pkt.udp:setDstPort(port)
	    buf:setDelay( poissonDelay(delay) )
        end
        bufs:offloadUdpChecksums()
        sent = sent + queue:sendWithDelay(bufs)
        
    end
    if numPkts ~= stop then
        bufs = mem:bufArray(numPkts % 64)
        bufs:alloc(size)
        for _, buf in ipairs(bufs) do
            local pkt = buf:getUdpPacket()
            pkt.udp:setDstPort(port)
            buf:setDelay( delay) --poissonDelay(delay) )
        end
        bufs:offloadUdpChecksums()
        sent = sent + queue:sendWithDelay(bufs)
    end
    return sent    
end

function backtobackLoadSlave(self, queue, frameSize, bar, granularity, duration) 
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
    
    --wait for counter slave
    bar:wait()
    --TODO: dirty workaround for resetting a barrier
    moongen.sleepMicros(100)
    bar:reinit(2)
    
    local linkSpeed = queue.dev:getLinkStatus().speed
    local maxPkts = math.ceil((linkSpeed * 10^6 / ((frameSize + 20) * 8)) * duration) -- theoretical max packets send in about `duration` seconds with linkspeed
    local count = maxPkts
    local longest = 0
    local binSearch = utils.binarySearch(0, maxPkts)
    local first = true


    while moongen.running() do
        local t = timer.new(0.5)
        queue:setRate(10)
        while t:running() do
            sendBurst(64, mem, queue, frameSize - 4, UDP_PORT+1)
        end
        queue:setRate(linkSpeed)

        local sent = sendBurst(count, mem, queue, frameSize - 4, UDP_PORT)
        
        rsns.sent = sent
        
        bar:wait()
        --TODO: fix barrier reset
        -- reinit interferes with wait
        moongen.sleepMicros(100)
        bar:reinit(2)
        
        -- do a binary search
        -- throw away first try
        if first then
           first = false 
        else
            local top = sent == rsns.received
            --get next rate
            local nextCount, finished = binSearch:next(count, top, granularity)
            -- update longest
            longest = (top and count) or longest
            if finished then
                break
            end
            printf("loadSlave: sent %d and received %d => changing from %d to %d", sent, rsns.received, count, nextCount)
            count = nextCount
        end
        moongen.sleepMillis(2000)
    end
    return longest
end

function backtobackLoadSlaveCBR(self, queue, rateLimiter, frameSize, bar, granularity, duration) 
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
    
    --wait for counter slave
    bar:wait()
    --TODO: dirty workaround for resetting a barrier
    moongen.sleepMicros(100)
    bar:reinit(2)
    
    local linkSpeed = queue.dev:getLinkStatus().speed
    local maxPkts = math.ceil((linkSpeed * 10^6 / ((frameSize + 20) * 8)) * duration) -- theoretical max packets send in about `duration` seconds with linkspeed
    local count = maxPkts
    local longest = 0
    local binSearch = utils.binarySearch(0, maxPkts)
    local first = true


    while moongen.running() do
        local t = timer.new(0.5)

	-- set rate 10 mbit
        while t:running() do
            sendBurstDelayCBR(64, mem, rateLimiter, frameSize - 4, self.UDP_PORT+1)
        end
        -- set rate link speed

        local sent = sendBurst(count, mem, queue, frameSize - 4, self.UDP_PORT)
        
        rsns.sent = sent
        
        bar:wait()
        --TODO: fix barrier reset
        -- reinit interferes with wait
        moongen.sleepMicros(100)
        bar:reinit(2)
        
        -- do a binary search
        -- throw away first try
        if first then
           first = false 
        else
            local top = sent == rsns.received
            --get next rate
            local nextCount, finished = binSearch:next(count, top, granularity)
            -- update longest
            longest = (top and count) or longest
            if finished then
                break
            end
            printf("loadSlaveCBR: sent %d and received %d => changing from %d to %d", sent, rsns.received, count, nextCount)
            count = nextCount
        end
        moongen.sleepMillis(2000)
    end
    return longest
end

function backtobackLoadSlavePoison(self,queue, frameSize, bar, granularity, duration) 
    -- gen payload template suggested by RFC2544
    --10 mbit delay
    local delay = (10^12 / 8 / (10 * 10^6)) - (frameSize + 24)
    if delay < 0 then
        delay = 0
    end

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
    
    --wait for counter slave
    bar:wait()
    --TODO: dirty workaround for resetting a barrier
    moongen.sleepMicros(100)
    bar:reinit(2)
    
    local linkSpeed = queue.dev:getLinkStatus().speed
    local maxPkts = math.ceil((linkSpeed * 10^6 / ((frameSize + 20) * 8)) * duration) -- theoretical max packets send in about `duration` seconds with linkspeed
    local count = maxPkts
    local longest = 0
    local binSearch = utils.binarySearch(0, maxPkts)
    local first = true


    while moongen.running() do
        local t = timer.new(0.5)

	--10 mbit rate
        while t:running() do
            sendBurstDelayPoison(64, mem, queue, frameSize - 4, self.UDP_PORT+1, delay)
        end
	--line speed rate
        local sent = sendBurst(count, mem, queue, frameSize - 4, self.UDP_PORT)
        rsns.sent = sent
        
        bar:wait()
        --TODO: fix barrier reset
        -- reinit interferes with wait
        moongen.sleepMicros(100)
        bar:reinit(2)
        
        -- do a binary search
        -- throw away first try
        if first then
           first = false 
        else
            local top = sent == rsns.received
            --get next rate
            local nextCount, finished = binSearch:next(count, top, granularity)
            -- update longest
            longest = (top and count) or longest
            if finished then
                break
            end
            printf("loadSlavePoison: sent %d and received %d => changing from %d to %d", sent, rsns.received, count, nextCount)
            count = nextCount
        end
        moongen.sleepMillis(2000)
    end
    return longest
end


function backtobackCounterSlave(self, queue, frameSize, bar, granularity, duration)
    
    local bufs = memory.bufArray() 
    
    local maxPkts = math.ceil((queue.dev:getLinkStatus().speed * 10^6 / ((frameSize + 20) * 8)) * duration) -- theoretical max packets send in about `duration` seconds with linkspeed
    local count = maxPkts
    local longest = 0
    local binSearch = utils.binarySearch(0, maxPkts)
    local first = true
    
    
    local t = timer:new(0.5)
    while t:running() do
        queue:tryRecv(bufs, 100)
        bufs:freeAll()
    end
    
    -- wait for sender to be ready
    bar:wait()
    while moongen.running() do
        local timer = timer:new(duration + 2)
        local counter = 0
        
        while timer:running() do
            rx = queue:tryRecv(bufs, 1000)
            for i = 1, rx do
                local buf = bufs[i]
                local pkt = buf:getUdpPacket()
                if pkt.udp:getDstPort() == self.UDP_PORT then
                    counter = counter + 1
                end
            end
            bufs:freeAll()
            if counter >= count then
                break
            end
        end
        rsns.received = counter
        
        -- wait for sender -> both renewed value in rsns
        bar:wait()
        
        -- do a binary search
        -- throw away firt try
        if first then
            first = false
        else
            local top = counter == rsns.sent
            --get next rate
            local nextCount, finished = binSearch:next(count, top, granularity)
            -- update longest 
            longest = (top and count) or longest
            if finished then
                break
            end
            printf("counterSlave: sent %d and received %d => changing from %d to %d", rsns.sent, counter, count, nextCount)
            count = nextCount
        end
        moongen.sleepMillis(2000)
    end
    return longest
end

--for standalone benchmark
if standalone then
    function configure(parser)
        parser:description("measure backtoback frames.")
        parser:argument("txport", "Device to transmit to."):default(0):convert(tonumber)
        parser:argument("rxport", "Device to receive from."):default(0):convert(tonumber)
        parser:option("-d --duration", "length of test"):default(1):convert(tonumber)
        parser:option("-n --numiterations", "number of iterations"):default(1):convert(tonumber)
        parser:option("-b --bths", "bths"):default(5):convert(tonumber)
	parser:option("-f --folder", "folder"):default("testresults")
	parser:option("-t --ratetype", "rate type (hw,cbr,poison)"):default("cbr")
	parser:option("-s --fs", "frame sizes e.g;'64 128 ..'"):default("64,128,256,512,1024,1280,1518")
    end
    function master(args)
        local txPort, rxPort = args.txport, args.rxport
        if not txPort or not rxPort then
            return print("usage: --txport <txport> --rxport <rxport> --duration <duration> --iterations <num iterations>")
        end
        
        local disableOffloads = false
	if args.ratetype ~= "posion" then --if posion is not the type, disable the offloads
	    disableOffloads = true
	end

        local rxDev, txDev
        if txPort == rxPort then
            -- sending and receiving from the same port
            txDev = device.config({port = txPort, rxQueues = 2, txQueues = 4, disableOffloads })
            rxDev = txDev
        else
            -- two different ports, different configuration
            txDev = device.config({port = txPort, rxQueues = 2, txQueues = 4, disableOffloads })
            rxDev = device.config({port = rxPort, rxQueues = 2, txQueues = 3})
        end
        device.waitForLinks()     

	local folderName = args.folder
	local report = testreport.new(folderName .. "/rfc_2544_testreport.tex")
	local results = {}

	-- start test
        local bench = benchmark()
        bench:init({
            txQueues = {txDev:getTxQueue(1)}, 
            rxQueues = {rxDev:getRxQueue(0)}, 
            granularity = args.bths,
            duration = args.duration,
            numIterations = args.numiterations,
	    ratetype = args.ratetype,
            skipConf = true,
        })
        
	local FRAME_SIZES = {}
	local fram_siz_t = Split(args.fs,",")
	for index,item in ipairs(fram_siz_t) do
		FRAME_SIZES[index] = tonumber(item)
        end

	file = io.open(folderName .. "/backtoback.csv", "w")
	log(file, bench:getCSVHeader(), true)
	for _, frameSize in ipairs(FRAME_SIZES) do
            if frameSize > 0 then
		local result = bench:bench(frameSize)
		
		-- save and report results
		table.insert(results, result)
		log(file, bench:resultToCSV(result), true)
		report:addBackToBack(result, bench.duration, args.bths, txDev:getLinkStatus().speed)
            end
	end
	bench:toTikz(folderName .. "/plot_backtoback", unpack(results))
	file:close()
	-- finalize test
	report:append()
    end
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
