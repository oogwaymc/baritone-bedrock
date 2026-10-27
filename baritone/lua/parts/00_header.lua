--[[
  Baritone for Bedrock
  ------------------------------------------------------------------
  Runs inside Baritone.dll (embedded Lua, native game access) or, as a
  fallback, as a Flarial Lua module driven by BaritoneHelper.exe.

  Original Flarial module notes:
  ------------------------------------------------------------------
  Pathfinding bot for Minecraft: Bedrock Edition (Windows), modelled on
  Baritone for Java. Runs inside Flarial's injected client as a Lua
  module and drives the game with real keyboard/mouse input through the
  companion app BaritoneHelper.exe (Flarial scripts cannot press keys).

  Chat:   #help   #goto x y z   #mine diamond_ore   #follow Steve
          #build house   #farm   #elytra x z   #stop
  Backup: .b <command>  (works even if your Flarial build does not pass
          chat messages to scripts)

  Files (in %LOCALAPPDATA%\Flarial\Client\Baritone\):
    settings.txt, waypoints.txt, farm_*.txt, schematics\, ipc.txt, helper.txt
]]

name = "Baritone"
description = "Baritone-style pathfinding bot. Type #help in chat. Needs BaritoneHelper.exe running."
author = "Bedrock Baritone"
debug = false

local VERSION = "1.2.0"
local DIR = "Baritone"
-- true inside Baritone.dll: input, rotation, inventory and rendering are native
local NATIVE = type(rawget(_G, "native")) == "table" and type(native.setInput) == "function"
local Bot = {}          -- filled in later (forward declaration)

-- lots of small short-lived tables: generational GC avoids long pauses (frame hitches)
if NATIVE then pcall(collectgarbage, "generational") end
