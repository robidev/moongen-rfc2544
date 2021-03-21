package.path = package.path .. "rfc2544/?.lua"

local standalone = false
if master == nil then
        standalone = true
        master = "dummy"
end

local moongen       = require "moongen"
local testreport    = require "utils.testreport"


--for standalone benchmark
if standalone then
    function configure(parser)
        parser:description("finish report")
	parser:option("-f --folder", "folder"):default("testresults")
    end
    function master(args)      
	local folderName = args.folder
	local report = testreport.new(folderName .. "/rfc_2544_testreport.tex")
	report:finish()
    end
end

local mod = {}
mod.__index = mod

mod.benchmark = benchmark
return mod
