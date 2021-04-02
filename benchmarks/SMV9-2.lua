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

local uint64 = ffi.typeof("uint64_t")

local PKT_SIZE	= 134
local smvPayload = ffi.new("uint8_t[?]", PKT_SIZE, { 
--0x01, 0x0c, 0xcd, 0x01, 0x00, 0x03,--dst
--0x00, 0x00, 0x00, 0x00, 0x00, 0x00,--src
--				0x81, 0x00, -- vlan	    12	
				0x80, 0x01, -- vlan options 14

				0x88, 0xba, -- smv ethtype 16
				0x40, 0x00, -- appid       18
				0x00, 0x74, -- lengt       20
				0x00, 0x00, -- reserved 1  22
				0x00, 0x00, -- reserved 2  24
				0x60, 0x6a, --             26

				0x80, 0x01, -- savPdu      28
				0x01,       -- noAsdu 1    30

				0xa2, 0x65, --             31
				0x30, 0x63, -- seqAsdu: 1 item, ASDU  33

				0x80, 0x08, -- svID:       35
				0x50, 0x68, 0x73, 0x4d, 0x65, 0x61, 0x73, 0x31, -- PhsMeas1 37

				0x82, 0x02, -- smpcnt:     45
				0x00, 0x00, -- 0           47

				0x83, 0x04, -- confrev     49
				0x00, 0x00, 0x00, 0x01, -- 1  51

				0x84, 0x08, -- refrTm      55
				0x60, 0x64, 0x55, 0xca, 0xc9, 0x78, 0xd4, 0x0a, --57

				0x85, 0x01, -- smpSynch    65
				0x00, -- 0                 67

				0x87, 0x40, -- PhsMeas1{   68

				0x00, 0x00, 0x00, 0x01, -- 70
				0x00, 0x00, 0x00, 0x00, -- 74

				0x00, 0x00, 0x00, 0x02, -- 78
				0x00, 0x00, 0x00, 0x00, -- 82

				0x00, 0x00, 0x00, 0x03, -- 86
				0x00, 0x00, 0x00, 0x00, -- 90
				 
				0x00, 0x00, 0x00, 0x04, -- 94
				0x00, 0x00, 0x00, 0x00, -- 98

				0x00, 0x00, 0x00, 0x11, -- 102
				0x00, 0x00, 0x00, 0x00, -- 106

				0x00, 0x00, 0x00, 0x12, -- 110
				0x00, 0x00, 0x00, 0x00, -- 114

				0x00, 0x00, 0x00, 0x13, -- 118
				0x00, 0x00, 0x00, 0x00, -- 122

				0x00, 0x00, 0x00, 0x14, -- 126
				0x00, 0x00, 0x00, 0x00  -- 130
			}) --                              134



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

    self.samples_per_sec = arg.samples_per_sec
    self.measurements = arg.measurements
    self.type = arg.type

    self.trigger_index = arg.trigger_index
    self.burstsize = arg.burstsize

    self.initialized = true
end

function benchmark:getCSVHeader()
    return "SMV92,packet,frame size,rate,duration"
end

function benchmark:resultToCSV(result)
    local str = ""
    result:calc()
    for k ,v in ipairs(result.sortedHisto) do
            str = str .. v.k .. "," .. v.v .. "," .. self.samples_per_sec .. "," .. self.duration
        if result.sortedHisto[k+1] then
            str = str .. "\n"
        end
    end
    return str
end

function benchmark:toTikz(filename, ...)
    local cdf = tikz.new(filename .. "_cdf" .. ".tikz", [[xlabel={SMV92 [$\mu$s]}, ylabel={CDF}, grid=both, ymin=0, ymax=1, mark repeat=100, scaled ticks=false, no markers, width=9cm, height=4cm,cycle list name=exotic]])
    
    local numResults = select("#", ...)
    --print("numResults:" .. numResults)
    for i=1, numResults do
        local result = select(i, ...)
        local histo = tikz.new(filename .. "_histo" .. ".tikz", [[xlabel={SMV92 [$\mu$s]}, ylabel={probability [\%]}, grid=both, ybar interval, ymin=0, xtick={}, scaled ticks=false, tick label style={/pgf/number format/fixed}, x tick label as interval=false, width=9cm, height=4cm ]])
        histo:startPlot([[orange, fill=blue]])
        cdf:startPlot()
        
        result:calc()
        local numSamples = result.numSamples
        local q1,q2,q3 = result:quartiles()
        local min, max = result.sortedHisto[1].k, result.sortedHisto[#result.sortedHisto].k        
        local binWidth =  (q3 - q1) / (numSamples ^ (1/2))
        local numBins = math.ceil((max - min) / binWidth) + 1
    
        local bins = {}
        if numBins ~= numBins then --if numBins is nan, it is not equal to itself, force it 1
            numBins = 1
	end
        for j=1, numBins do
            bins[j] = 0
        end

        for k, v in pairs(result.histo) do
            local j = math.floor((k - min) / binWidth) + 1
            if j ~= j then j = 1 end --if j is nan, it is not equal to itself, force it 1
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
        cdf:endPlot("result " .. numResults)
    end
    cdf:finalize()
end

function benchmark:bench()
    if not self.initialized then
        return print("benchmark not initialized");
    end

    local maxLinkRate = self.rxQueues[1].dev:getLinkStatus().speed
    local bar = barrier.new(0,0)

    local hist = hist:create()
    n = self.measurements
    for i=1, n do
        bar:reinit(2)

        local rateLimiter
        local loadSlave

	local timerTask

	if self.type == "hw" then
            timerTask = moongen.startTask("GOOSETimerSlave", self.rxQueues[1], self.duration, bar)
    
            -- SMV92 traffic generator
            loadSlave = moongen.startTask("SMV92LoadSlave", self.txQueues[3], self.duration, self.samples_per_sec, bar, self.trigger_index ,self.burstsize)
	elseif self.type == "sw" then
            timerTask = moongen.startTask("GOOSETimerSlaveSw", self.rxQueues[1], self.duration, bar)
    
            -- SMV92 traffic generator
            loadSlave = moongen.startTask("SMV92LoadSlaveSw", self.txQueues[3], self.duration, self.samples_per_sec, bar, self.trigger_index ,self.burstsize)
	else
	    print("ERROR: invalid type")
	    os.exit(-1)
	end

        local tx_time = loadSlave:wait()
        if rateLimiter ~= nil then
	    rateLimiter:stop()
        end
        local rx_time = timerTask:wait()

        if tx_time == -1  then
	    print("ERROR: no send packets timestamped")
        end
        if rx_time == -1 then
	    print("ERROR: no trigger packets received with timestamp")
        end
	if tx_time ~= -1 and rx_time ~= -1 then
		local latency = rx_time - tx_time
		if self.type == "sw" then
		    local tscFreq = moongen.getCyclesFrequency()
		    latency =latency / tscFreq * 10^9 -- to nanoseconds
		end
		print("latency: " .. latency)
		hist:update(latency)
	else
	    if i > 1 then -- we had at least one good measurement
		print("WARNING: bad measurement, will retry..")
		i = i - 1
	    end
	end
    end

    hist:print()
    if hist.numSamples == 0 then
	print("ERROR: no packets recieved. Please check NIC connection")
	os.exit(-1)
    end

    return hist
end

function SMV92LoadSlave(queue, duration, samples_per_sec, bar, trigger_index, burstsize)
	queue:enableTimestamps()
	local mem = memory.createMemPool(4096, function(buf)
		local pkt = buf:getEthernetPacket()
		pkt:fill {
			ethSrc = queue,
			ethDst = "01:0c:cd:01:00:01",--ethDst,
			ethType = 0x8100
		}
		ffi.copy(pkt.payload, smvPayload, PKT_SIZE)
	end)

	    -- sync with timerSlave
        bar:wait()

	print("starting the publisher")
	local runtime = timer:new(duration+3)
	local bufs = mem:bufArray(burstsize) -- prepare x buffers per time 

	-- calculate 250us increment
	local time_250us_increment = moongen.getCyclesFrequency() / samples_per_sec

	-- set time for start
	local time_250us = moongen.getCycles() + moongen.getCyclesFrequency()

	local trigger = (duration -1) * samples_per_sec -- trigger one second before duration ends

	local smpCnt = 0
	local tx_time = -1
	local counter = 0
	print("streams: " .. burstsize .. " stream index for trigger:" .. trigger_index)
	while runtime:running() do
		if time_250us < moongen.getCycles() then
			bufs:alloc(PKT_SIZE) -- size of each packet
			local pkt
			for i, buf in ipairs(bufs) do
			    pkt = buf:getEthernetPacket()
			    pkt.payload.uint8[33] = smpCnt / 256 -- 47
			    pkt.payload.uint8[34] = smpCnt % 256 	
			    
			    if i == trigger_index then
				pkt.payload.uint8[30] = 0x31
				pkt.payload.uint8[-9] = 0x03
			    else
			    	pkt.payload.uint8[30] = 0x32
			    	pkt.payload.uint16[29] = 0x0000
			    	pkt.payload.uint8[-9] = 0x01
			    end
			end
			smpCnt = (smpCnt + 1) % samples_per_sec

			if counter == trigger then --trigger trip event
				pkt = bufs[trigger_index]:getEthernetPacket()
				pkt.payload.uint16[29] = 0xFFFF --smv value to trigger trip event

				bufs[trigger_index]:enableTimestamps() --enable hw timestamp for this buffer
				queue:sendN(bufs, burstsize) -- send it
				tx_time = queue:getTimestamp(500) --retrieve the timestamp from register
			else
				queue:sendN(bufs, burstsize)
			end
			counter = counter + 1
			time_250us = time_250us + time_250us_increment
		end
	end
	
    print("tx_time: " .. tx_time)
    return tx_time
end

function GOOSETimerSlave(queue, duration, bar)

    local bufs = memory.createBufArray()

    -- sync with LoadSlave
    bar:wait()
    --moongen.sleepMillis(1000)

    queue:enableTimestampsAllPackets()
    local timer = timer:new(duration + 3)
    print("starting the measurement")

    local timestamp = -1
    while timer:running() do
	local n = queue:tryRecv(bufs, 1000)
	for i = 1, n do
            local pkt = bufs[i]:getEthernetPacket()
	    --check for GOOSE value packet ethertype
            if pkt.payload.uint16[7] == 0xb888 and timestamp == -1 and pkt.payload.uint8[143] == 255 then
		timestamp = bufs[i]:getTimestamp()
            end
	    --bufs[i]:dump()
	end
	bufs:free(n)
    end
    print("rx_time: " .. timestamp )
    return timestamp
end

function SMV92LoadSlaveSw(queue, duration, samples_per_sec, bar, trigger_index, burstsize)
	local tscFreq = moongen.getCyclesFrequency()
	local mem = memory.createMemPool(function(buf)
		local pkt = buf:getEthernetPacket()
		pkt:fill {
			ethSrc = queue,
			ethDst = "01:0c:cd:01:00:01",--ethDst,
			ethType = 0x8100
		}
		ffi.copy(pkt.payload, smvPayload, PKT_SIZE)
	end)

	    -- sync with timerSlave
        bar:wait()

	print("starting the sw publisher")
	local runtime = timer:new(duration+3)
	local bufs = mem:bufArray(burstsize) -- prepare x buffers per time

	-- calculate 250us increment
	local time_250us_increment = moongen.getCyclesFrequency() / samples_per_sec

	-- set time for start
	local time_250us = moongen.getCycles() + moongen.getCyclesFrequency()

	local trigger = (duration -1) * samples_per_sec -- trigger one second before duration ends

	local smpCnt = 0
	local tx_time_1 = -1
	local tx_time_2 = -1
	local counter = 0
	while runtime:running() do
		if time_250us < moongen.getCycles() then
			bufs:alloc(PKT_SIZE) -- size of each packet
			local pkt
			for i, buf in ipairs(bufs) do
			    pkt = buf:getEthernetPacket()
			    pkt.payload.uint8[33] = smpCnt / 256 -- 47
			    pkt.payload.uint8[34] = smpCnt % 256 	
			    
			    if i == trigger_index then
				pkt.payload.uint8[30] = 0x31
				pkt.payload.uint8[-9] = 0x03
			    else
			    	pkt.payload.uint8[30] = 0x32
			    	pkt.payload.uint16[29] = 0x0000
			    	pkt.payload.uint8[-9] = 0x01
			    end
			end
			smpCnt = (smpCnt + 1) % samples_per_sec

			if counter == trigger then --trigger trip event
				pkt = bufs[trigger_index]:getEthernetPacket()
				pkt.payload.uint16[29] = 0xFFFF --smv value to trigger trip event

				tx_time_1 = moongen.getCycles() 
				queue:sendN(bufs, burstsize)
				tx_time_2 = moongen.getCycles()
			else
				queue:sendN(bufs, burstsize)
			end
			counter = counter + 1
			time_250us = time_250us + time_250us_increment
		end
	end
    local tx_time = tx_time_1 + ( ( ( tx_time_2 - tx_time_1) / burstsize) * trigger_index )
    print("tx_time: " .. tonumber(tx_time % 0x100000000))
    return tonumber(tx_time % 0x100000000)
end

function GOOSETimerSlaveSw(queue, duration, bar)
    local tscFreq = moongen.getCyclesFrequency()
    local bufs = memory.createBufArray()

    -- sync with LoadSlave
    bar:wait()
    moongen.sleepMillis(1000)

    --queue:enableTimestampsAllPackets()
    local timer = timer:new(duration + 3)
    print("starting the sw measurement")

    local timestamp = -1
    while timer:running() do
	local n = queue:recvWithTimestamps(bufs)
	for i = 1, n do
            local pkt = bufs[i]:getEthernetPacket()
	    --check for GOOSE value packet ethertype

            if pkt.payload.uint16[-1] == 0xb888 and timestamp == -1 and pkt.payload.uint8[0x7f] == 255 then
		timestamp = bufs[i].udata64 
            end
	    --bufs[i]:dump()
	end
	bufs:free(n)
    end
    print("rx_time: " .. tonumber(timestamp % 0x100000000) )
    return tonumber(timestamp % 0x100000000)
end


--for standalone benchmark
if standalone then
    function configure(parser)
        parser:description("measure SMV92 processing.")
        parser:argument("txport", "Device to transmit to."):default(0):convert(tonumber)
        parser:argument("rxport", "Device to receive from."):default(0):convert(tonumber)
	parser:option("-f --folder", "folder"):default("testresults")
	parser:option("-d --duration", "duration of each test"):default(2):convert(tonumber)
	parser:option("-s --samples_per_sec", "samples per second [4000,4800]"):default(4000):convert(tonumber)
	parser:option("-m --measurements", "amount of measurements done"):default(5):convert(tonumber)
	parser:option("-t --type", "type of measurements(hw|sw)"):default("hw")
	parser:option("-i --trigger_index", "stream to trigger on"):default(1):convert(tonumber)
	parser:option("-b --streamsize", "amount of streams"):default(1):convert(tonumber)
    end
    function master(args)
        --local args = utils.parseArguments(arg)
        local txPort, rxPort = args.txport, args.rxport
        if not txPort or not rxPort then
            return print("usage: --txport <txport> --rxport <rxport> [OPTIONS]")
        end
        
        local disableOffloads = false
	if args.ratetype ~= "posion" then --if posion is not the type, disable the offloads
	    disableOffloads = false--true
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
            rxQueues = {rxDev:getRxQueue(0)}, 
            duration = args.duration,
	    samples_per_sec = args.samples_per_sec,
            measurements = args.measurements,
	    type = args.type,
    	    trigger_index = args.trigger_index,
    	    burstsize = args.streamsize,
        })

	print(folderName)
	file = io.open(folderName .. "/SMV92.csv", "w")
	log(file, bench:getCSVHeader(), true)

        local result = bench:bench()
	-- save and report results        
	table.insert(results, result)
	log(file, bench:resultToCSV(result), true)
	report:addSMV92(result, args.samples_per_sec) 

	bench:toTikz(folderName .. "/plot_SMV92", unpack(results))
	file:close()
	-- finalize test
	report:append()
    end
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
