package.path = package.path .. "rfc2544/?.lua"

local standalone = false
if master == nil then
        standalone = true
        master = "dummy"
end

local moongen       = require "moongen"
local utils         = require "utils.utils"
local testreport    = require "utils.testreport"


--for standalone benchmark
if standalone then
    function configure(parser)
        parser:description("start report")
	parser:argument("device", "device name")
	parser:argument("OS", "device os")
	parser:option("-f --folder", "folder"):default("testresults")
    end
    function master(args)      
	utils.setDeviceName(args.device)
	utils.setDeviceOS(args.OS)

	local folderName = args.folder
	-- create testresult folder if not exist
	-- there is no clean lua way without using 3rd party libs
	os.execute("mkdir -p " .. folderName)    
	local report = testreport.new(folderName .. "/rfc_2544_testreport.tex")
	report:start()
    end
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
