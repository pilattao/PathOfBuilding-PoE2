-- API/Handlers.lua
-- Shared JSON-RPC handlers for PoB API (transport-agnostic)

-- Debug logging control
local DEBUG = os.getenv('POB_API_DEBUG') == '1'
local function debug_log(msg)
  if DEBUG then io.stderr:write('[Handlers] ' .. msg .. '\n') end
end

-- JSON: PoB bundles dkjson under lua/ and requires it as a local module (see
-- Classes/ImportTab.lua, Modules/Data.lua) — there is NO global `dkjson`. Require
-- it the same way for JSON decoding in the import handlers (3.29 import contract).
local dkjson = require('dkjson')

-- Resolve BuildOps reliably regardless of CWD
local BuildOps
do
  debug_log('Attempting to require API.BuildOps')
  local ok_ops, mod = pcall(require, 'API.BuildOps')
  debug_log('pcall require result: ok=' .. tostring(ok_ops) .. ', mod=' .. tostring(mod))
  if ok_ops and mod then
    debug_log('Successfully loaded BuildOps via require')
    BuildOps = mod
  else
    debug_log('require failed, trying dofile fallbacks')
    -- Try path relative to this file's directory
    local dir = ''
    local info = debug and debug.getinfo and debug.getinfo(1, 'S')
    local src = info and info.source or ''
    if type(src) == 'string' and src:sub(1,1) == '@' then
      local p = src:sub(2)
      dir = (p:gsub('[^/\\]+$', ''))
    end
    local tried = {}
    local function try(p)
      if p then table.insert(tried, p) end
      if not p then return false end
      debug_log('Trying to load: ' .. tostring(p))
      local ok2, m = pcall(dofile, p)
      if ok2 and m then
        debug_log('Successfully loaded BuildOps from: ' .. tostring(p))
        BuildOps = m
        return true
      end
      debug_log('Failed to load from: ' .. tostring(p) .. ' - error: ' .. tostring(m))
      return false
    end
    if not BuildOps then
      local _ = try(dir .. 'BuildOps.lua')
              or try((rawget(_G,'POB_SCRIPT_DIR') or '.') .. '/API/BuildOps.lua')
              or try('API/BuildOps.lua')
              or try('src/API/BuildOps.lua')
    end
    if not BuildOps then
      io.stderr:write('[Handlers] BuildOps.lua not found. Tried paths: ' .. table.concat(tried, ', ') .. '\n')
      error('API/BuildOps.lua not found. Tried: ' .. table.concat(tried, ', '))
    end
  end
end

-- API version (semantic versioning)
local API_VERSION = "1.4.0"

local function version_meta()
  return {
    number      = _G.launch and launch.versionNumber or '?',
    branch      = _G.launch and launch.versionBranch or '?',
    platform    = _G.launch and launch.versionPlatform or '?',
    apiVersion  = API_VERSION,
    game        = "poe2",
    features    = { queuedBuildOpen = true, nativeGemEvaluation = true, nativeItemEvaluation = true, nativeTreeEvaluation = true },
  }
end

local handlers = {}

handlers.ping = function(params)
  return { ok = true, pong = true }
end

handlers.version = function(params)
  return { ok = true, version = version_meta() }
end

local function headless_open(params)
  if not _G.runCallback then return {ok=false,error='headless frame callback unavailable'} end
  local queued, err = BuildOps.open_build_xml(params)
  if not queued then return {ok=false,error=err} end
  runCallback('OnFrame')
  local ready, readyErr = BuildOps.open_build_xml({statusOnly=true,requestId=queued.requestId})
  if not ready then return {ok=false,error=readyErr} end
  if not ready.ready then return {ok=false,error='headless build did not initialize'} end
  return ready
end

handlers.new_build = function(params)
  return headless_open(params or {})
end

handlers.load_build_xml = function(params)
  if not params or type(params.xml) ~= 'string' then return {ok=false,error='missing xml'} end
  return headless_open(params)
end

handlers.get_stats = function(params)
  local fields = params and params.fields or nil
  local stats, err = BuildOps.export_stats(fields)
  if not stats then
    return { ok = false, error = err }
  end
  return { ok = true, stats = stats }
end

handlers.get_items = function(params)
  local list, err = BuildOps.get_items()
  if not list then return { ok = false, error = err } end
  return { ok = true, items = list }
end

handlers.get_skills = function(params)
  local info, err = BuildOps.get_skills()
  if not info then return { ok = false, error = err } end
  return { ok = true, skills = info }
end

handlers.get_tree = function(params)
  local tree, err = BuildOps.get_tree()
  if not tree then
    return { ok = false, error = err }
  end
  return { ok = true, tree = tree }
end

handlers.set_main_selection = function(params)
  local ok2, err = BuildOps.set_main_selection(params or {})
  if not ok2 then return { ok = false, error = err } end
  local skills = BuildOps.get_skills()
  return { ok = true, skills = skills }
end

handlers.set_tree = function(params)
  local ok2, err = BuildOps.set_tree(params or {})
  if not ok2 then
    return { ok = false, error = err }
  end
  local tree = BuildOps.get_tree()
  return { ok = true, tree = tree }
end

handlers.add_item_text = function(params)
  local res, err = BuildOps.add_item_text(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, item = res }
end

handlers.clear_item_slot = function(params)
  local res, err = BuildOps.clear_item_slot(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.export_build_xml = function(params)
  local xml, err = BuildOps.export_build_xml()
  if not xml then return { ok = false, error = err } end
  return { ok = true, xml = xml }
end

handlers.open_build_xml = function(params)
  local res, err = BuildOps.open_build_xml(params or {})
  if not res then return { ok = false, error = err } end
  return res
end

handlers.get_build_open_status = function(params)
  local res, err = BuildOps.open_build_xml({statusOnly=true,requestId=params and params.requestId})
  if not res then return {ok=false,error=err} end
  return res
end

handlers.close_build = function(params)
  local res, err = BuildOps.close_build()
  if not res then return { ok = false, error = err } end
  return { ok = true }
end

handlers.set_level = function(params)
  if not params or params.level == nil then
    return { ok = false, error = 'missing level' }
  end
  local ok2, err = BuildOps.set_level(params.level)
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.set_view_mode = function(params)
  if not params or params.mode == nil then
    return { ok = false, error = 'missing mode' }
  end
  local ok2, result = BuildOps.set_view_mode(params.mode)
  if not ok2 then return { ok = false, error = result } end
  return { ok = true, mode = result }
end

handlers.set_flask_active = function(params)
  local ok2, err = BuildOps.set_flask_active(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.get_build_info = function(params)
  local info, err = BuildOps.get_build_info()
  if not info then return { ok = false, error = err } end
  return { ok = true, info = info }
end

handlers.get_gem_detail = function(params)
  local gem, err = BuildOps.get_gem_detail(params or {})
  if not gem then return { ok = false, error = err } end
  return { ok = true, gem = gem }
end

handlers.evaluate_gem_setups = function(params)
  local result, err = BuildOps.evaluate_gem_setups(params or {})
  if not result then return {ok=false,error=err} end
  return {ok=true,result=result}
end

handlers.update_tree_delta = function(params)
  local res, err = BuildOps.update_tree_delta(params or {})
  if not res then return { ok = false, error = err } end
  local tree = BuildOps.get_tree()
  -- Pass through the ACTUAL outcome so the caller reports what landed, not what was asked for.
  return {
    ok = true,
    tree = tree,
    added = res.added,
    removed = res.removed,
    autoPathedNodes = res.autoPathedNodes,
    droppedNodes = res.droppedNodes,
    skippedAscendancyNodes = res.skippedAscendancyNodes,
  }
end

handlers.calc_with = function(params)
  local out, base = BuildOps.calc_with(params or {})
  if not out then return { ok = false, error = base } end
  -- Native output also includes functions and opaque objects. Preserve every
  -- finite measurement (including zero), but only the known context fields.
  local function finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
  end
  local slim = {}
  for key, value in pairs(out) do
    if finite(value) then slim[key] = value end
  end
  if type(out.Minion) == 'table' then
    slim.Minion = {}
    for key, value in pairs(out.Minion) do
      if finite(value) then slim.Minion[key] = value; slim['Minion' .. key] = value end
    end
  end
  if type(out.calculationContext) == 'table' then
    local context = out.calculationContext
    slim.calculationContext = {
      weaponSet = context.weaponSet,
      treeVersion = context.treeVersion,
    }
  end
  return { ok = true, output = slim }
end

handlers.get_config = function(params)
  local cfg, err = BuildOps.get_config()
  if not cfg then return { ok = false, error = err } end
  return { ok = true, config = cfg }
end

handlers.set_config = function(params)
  local ok2, err = BuildOps.set_config(params or {})
  if not ok2 then return { ok = false, error = err } end
  local cfg = BuildOps.get_config()
  return { ok = true, config = cfg }
end

handlers.get_notes = function(params)
  local res, err = BuildOps.get_notes()
  if not res then return { ok = false, error = err } end
  return { ok = true, notes = res.notes }
end

handlers.set_notes = function(params)
  local ok2, err = BuildOps.set_notes(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.create_socket_group = function(params)
  local res, err = BuildOps.create_socket_group(params or {})
  if not res then return { ok = false, error = err or 'failed to create socket group' } end
  return { ok = true, socketGroup = res }
end

handlers.add_gem = function(params)
  local res, err = BuildOps.add_gem(params or {})
  if not res then return { ok = false, error = err or 'failed to add gem' } end
  return { ok = true, gem = res }
end

handlers.set_gem_level = function(params)
  local ok2, err = BuildOps.set_gem_level(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to set gem level' } end
  return { ok = true }
end

handlers.set_gem_quality = function(params)
  local ok2, err = BuildOps.set_gem_quality(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to set gem quality' } end
  return { ok = true }
end

handlers.remove_skill = function(params)
  local ok2, err = BuildOps.remove_skill(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to remove skill' } end
  return { ok = true }
end

handlers.remove_gem = function(params)
  local ok2, err = BuildOps.remove_gem(params or {})
  if not ok2 then return { ok = false, error = err or 'failed to remove gem' } end
  return { ok = true }
end

handlers.get_node_state = function(params)
  local res, err = BuildOps.get_node_state(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, node = res }
end

handlers.get_node_power = function(params)
  local res, err = BuildOps.get_node_power(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.get_stat_breakdown = function(params)
  local res, err = BuildOps.get_stat_breakdown(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, breakdown = res }
end

handlers.get_calc_breakdown = function(params)
  local res, err = BuildOps.get_calc_breakdown(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, breakdown = res }
end

handlers.search_nodes = function(params)
  local res, err = BuildOps.search_nodes(params or {})
  if not res then return { ok = false, error = err or 'failed to search nodes' } end
  return { ok = true, results = res }
end

handlers.save_build = function(params)
  if not params or type(params.path) ~= 'string' then
    return { ok = false, error = 'missing path' }
  end
  local res, err = BuildOps.save_build(params.path)
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.list_specs = function(params)
  local res, err = BuildOps.list_specs()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.select_spec = function(params)
  if not params or params.index == nil then return { ok = false, error = 'missing index' } end
  local res, err = BuildOps.select_spec(tonumber(params.index))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.create_spec = function(params)
  local res, err = BuildOps.create_spec(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.delete_spec = function(params)
  if not params or params.index == nil then return { ok = false, error = 'missing index' } end
  local res, err = BuildOps.delete_spec(tonumber(params.index))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.rename_spec = function(params)
  if not params or params.index == nil or params.title == nil then
    return { ok = false, error = 'missing index or title' }
  end
  local res, err = BuildOps.rename_spec(tonumber(params.index), tostring(params.title))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.list_item_sets = function(params)
  local res, err = BuildOps.list_item_sets()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.select_item_set = function(params)
  if not params or params.id == nil then return { ok = false, error = 'missing id' } end
  local res, err = BuildOps.select_item_set(tonumber(params.id))
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.create_item_set = function(params)
  local res, err = BuildOps.create_item_set(params or {})
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.get_mastery_options = function(params)
  local res, err = BuildOps.get_mastery_options()
  if not res then return { ok = false, error = err } end
  return { ok = true, result = res }
end

handlers.set_socket_group_enabled = function(params)
  local res, err = BuildOps.set_socket_group_enabled(params or {})
  if not res then return { ok = false, error = err or 'failed' } end
  return { ok = true, result = res }
end

handlers.set_gem_enabled = function(params)
  local ok2, err = BuildOps.set_gem_enabled(params or {})
  if not ok2 then return { ok = false, error = err or 'failed' } end
  return { ok = true }
end

handlers.list_spectres = function(params)
  local res, err = BuildOps.list_spectres(params or {})
  if not res then return { ok = false, error = err or 'failed' } end
  return { ok = true, result = res }
end

handlers.set_spectres = function(params)
  local res, err = BuildOps.set_spectres(params or {})
  if not res then return { ok = false, error = err or 'failed' } end
  return { ok = true, result = res }
end

handlers.get_full_dps_breakdown = function()
  local res, err = BuildOps.get_full_dps_breakdown()
  if not res then return { ok = false, error = err } end
  return {
    ok         = true,
    skills     = res.skills,
    fullDPS    = res.fullDPS,
    fullDotDPS = res.fullDotDPS,
    playerDPS  = res.playerDPS,
  }
end

handlers.probe_stat_weights = function(params)
  local res, err = BuildOps.probe_stat_weights(params or {})
  if not res then return { ok = false, error = err } end
  return {
    ok        = true,
    base      = res.base,
    slot      = res.slot,
    carrier   = res.carrier,
    results   = res.results,
    evaluated = res.evaluated,
    failed    = res.failed,
  }
end

handlers.evaluate_item_replacements = function(params)
  local result, err = BuildOps.evaluate_item_replacements(params or {})
  if not result then return { ok = false, error = err } end
  return { ok = true, result = result }
end

handlers.evaluate_anoint_candidates = function(params)
  local res, err = BuildOps.evaluate_anoint_candidates(params or {})
  if not res then return { ok = false, error = err } end
  return {
    ok         = true,
    candidates = res.candidates,
    base       = res.base,
    evaluated  = res.evaluated,
    skipped    = res.skipped,
    slot       = res.slot,
    baseType   = res.baseType,
    focus      = res.focus,
  }
end

handlers.generate_weighted_trade_query = function(params)
  if not params or type(params.slot) ~= 'string' then
    return { ok = false, error = 'missing slot' }
  end
  local res, err = BuildOps.generate_weighted_trade_query(params)
  if not res then return { ok = false, error = err } end
  return { ok = true, query = res.query, warning = res.warning }
end

-- ---------------------------------------------------------------------------
-- Character import handlers
-- Node.js fetches the JSON bodies from pathofexile.com and forwards them here.
-- We delegate directly to the existing ImportTab methods; the controls table
-- already exists (created in ImportTab:Init), so we only need to patch the
-- boolean state fields the import functions read before calling them.
-- ---------------------------------------------------------------------------

-- PoB2 DownloadCharacter decodes {character={...}} once. Its native import
-- methods take that complete character as ONE argument. Split PoE1 responses
-- must not be reshaped into empty PoB2 equipment/skill/jewel arrays.
local function import_character_payload(params, section)
  if not params or type(params.json) ~= 'string' then return nil,'missing json' end
  local decoded, _, decodeErr = dkjson.decode(params.json)
  if type(decoded) ~= 'table' then return nil,'invalid PoB2 character JSON: '..tostring(decodeErr) end
  local character = type(decoded.character)=='table' and decoded.character or decoded
  if type(character.name) ~= 'string' or type(character.class) ~= 'string' or type(character.level) ~= 'number' then
    return nil,'complete PoB2 character payload required; PoE1 split responses are unsupported. Public snapshots use open_build_xml with pob_xml'
  end
  if character.level < 1 or character.level > 100 or character.level ~= math.floor(character.level) then return nil,'invalid PoB2 character level' end
  local tree = build and build.spec and build.spec.tree
  if not tree or not (tree.classNameMap[character.class] or tree.ascendNameMap[character.class] or tree.internalAscendNameMap[character.class]) then
    return nil,'class is unavailable in the loaded PoB2 tree: '..character.class
  end
  if section=='passives' then
    local passives = character.passives
    if type(passives)~='table' or type(passives.hashes)~='table' or type(passives.specialisations)~='table'
        or type(passives.skill_overrides)~='table' or type(character.jewels)~='table' then
      return nil,'complete PoB2 passives, specialisations, skill_overrides and jewels are required'
    end
    passives.jewel_data = passives.jewel_data or {}
  elseif type(character.equipment)~='table' or type(character.skills)~='table' then
    return nil,'complete PoB2 equipment and skills arrays are required'
  end
  return character
end

handlers.import_passive_tree = function(params)
  if not build or not build.importTab then return {ok=false,error='build not initialized'} end
  local character, err = import_character_payload(params,'passives')
  if not character then return {ok=false,error=err} end
  local control = build.importTab.controls.charImportTreeClearJewels
  if control then control.state = params.clear_jewels ~= false end
  local ok, importErr = pcall(build.importTab.ImportPassiveTreeAndJewels,build.importTab,character)
  if not ok then return {ok=false,error='import_passive_tree exception: '..tostring(importErr)} end
  local output, calcErr = BuildOps.get_main_output()
  if not output then return {ok=false,error=calcErr} end
  local info = BuildOps.get_build_info()
  return {ok=true,status='Passive tree imported',level=info.level,className=info.className,ascendClassName=info.ascendClassName}
end

handlers.import_items_skills = function(params)
  if not build or not build.importTab then return {ok=false,error='build not initialized'} end
  local character, err = import_character_payload(params,'equipment')
  if not character then return {ok=false,error=err} end
  local controls = build.importTab.controls
  if controls.charImportItemsClearItems then controls.charImportItemsClearItems.state = params.clear_items ~= false end
  if controls.charImportItemsClearSkills then controls.charImportItemsClearSkills.state = params.clear_skills ~= false end
  if controls.charImportItemsIgnoreWeaponSwap then controls.charImportItemsIgnoreWeaponSwap.state = params.ignore_weapon_swap == true end
  local ok, importErr = pcall(build.importTab.ImportItemsAndSkills,build.importTab,character)
  if not ok then return {ok=false,error='import_items_skills exception: '..tostring(importErr)} end
  local output, calcErr = BuildOps.get_main_output()
  if not output then return {ok=false,error=calcErr} end
  return {ok=true,status='Items and skills imported',level=build.characterLevel,character=character}
end

-- TcpServer refreshes _G.build from a reusable BUILD object, including while
-- Main has queued a transition. Refuse operations on that stale build.
local transitionSafe = {ping=true,version=true,open_build_xml=true,get_build_open_status=true,
  new_build=true,load_build_xml=true,close_build=true,get_gem_detail=true}
for name, handler in pairs(handlers) do
  if not transitionSafe[name] then
    handlers[name] = function(params)
      local mainObj = _G.main or (_G.__mainObject__ and __mainObject__.main)
      if mainObj and mainObj.newMode then return {ok=false,error='native build transition pending'} end
      if mainObj and mainObj.mode and mainObj.mode~='BUILD' then return {ok=false,error='no active native build'} end
      return handler(params)
    end
  end
end

return {
  handlers = handlers,
  version_meta = version_meta,
}
