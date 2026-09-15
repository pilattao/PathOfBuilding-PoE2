-- API/BuildOps.lua
-- Thin wrappers around PoB headless objects for programmatic operations

local M = {}

-- Constants
local MIN_PLAYER_LEVEL = 1
local MAX_PLAYER_LEVEL = 100
local NUM_FLASK_SLOTS = 2
local NUM_CHARM_SLOTS = 3
local MAX_ITEM_TEXT_LENGTH = 10240  -- 10KB

-- Ensure outputs are (re)built and return the main output table safely
function M.get_main_output()
  if not build or not build.calcsTab then
    return nil, "build not initialized"
  end
  if build.calcsTab.BuildOutput then
    local ok, err = pcall(build.calcsTab.BuildOutput, build.calcsTab)
    if not ok then return nil, "calculation failed: " .. tostring(err) end
  end
  local output = build.calcsTab and build.calcsTab.mainOutput or nil
  if not output then
    return nil, "no output available"
  end
  return output
end

-- Mutations use PoB2's own undo snapshots. Commit the undo entry only after
-- calculation succeeds. Item undo omits live activation controls, so retain those
-- separately. Failed rebuilds invalidate calculated outputs rather than serving stale stats.
local function integer(value, minimum, maximum)
  local n = tonumber(value)
  if not n or n ~= n or n == math.huge or n == -math.huge or n ~= math.floor(n)
      or (minimum and n < minimum) or (maximum and n > maximum) then return nil end
  return n
end

local function mutate(tab, action)
  if not tab.CreateUndoState or not tab.RestoreUndoState or not tab.AddUndoState then
    return nil, 'PoB2 undo interface unavailable'
  end
  local okState, state = pcall(tab.CreateUndoState, tab)
  if not okState then return nil, tostring(state) end
  local oldMod, oldBuildMod, oldFlag = tab.modFlag, build.modFlag, build.buildFlag
  local undo, redo = copyTable(tab.undo, true), copyTable(tab.redo, true)
  local level, autoLevel = build.characterLevel, build.characterLevelAutoMode
  local mainGroup, calcGroup = build.mainSocketGroup, build.calcsTab.input.skill_number
  local placeholder = tab.placeholder and copyTable(tab.placeholder)
  local spectres = build.spectreList and copyTable(build.spectreList)
  local slots = {}
  for name, slot in pairs(tab.slots or {}) do slots[name] = { active = slot.active } end
  local ok, result = pcall(function()
    local value, err = action()
    if value == nil then error(err or 'mutation failed') end
    build.buildFlag = true
    local output, calcErr = M.get_main_output()
    if not output then error(calcErr) end
    tab:AddUndoState()
    build.modFlag = true
    return value
  end)
  if ok then return result end
  build.characterLevel, build.characterLevelAutoMode = level, autoLevel
  if spectres then
    wipeTable(build.spectreList)
    for i,id in ipairs(spectres) do build.spectreList[i] = id end
  end
  if placeholder then
    wipeTable(tab.placeholder)
    for k,v in pairs(placeholder) do tab.placeholder[k] = v end
  end
  local restored, restoreErr = pcall(tab.RestoreUndoState, tab, state)
  for name, saved in pairs(slots) do
    local slot = tab.slots[name]
    slot.active = saved.active
    if slot.controls and slot.controls.activate then slot.controls.activate.state = saved.active end
  end
  build.mainSocketGroup, build.calcsTab.input.skill_number = mainGroup, calcGroup
  tab.undo, tab.redo = undo, redo
  if build.SyncLoadouts then
    local syncOk, syncErr = pcall(build.SyncLoadouts,build)
    if not syncOk then restored, restoreErr = false,syncErr end
  end
  -- Rebuild the restored state; report a recovery error without hiding the original failure.
  local output, calcErr = M.get_main_output()
  if not output then
    build.calcsTab.mainOutput, build.calcsTab.mainEnv = nil, nil
    build.calcsTab.calcsOutput, build.calcsTab.calcsEnv = nil, nil
  end
  tab.modFlag, build.modFlag, build.buildFlag = oldMod, oldBuildMod, oldFlag
  if not restored then result = tostring(result) .. '; rollback failed: ' .. tostring(restoreErr) end
  if not output then result = tostring(result) .. '; restored-state calculation failed: ' .. tostring(calcErr) end
  return nil, tostring(result)
end

-- Export a subset of useful stats from main output
-- If fields is provided, only export those keys (when present)
function M.export_stats(fields)
  local output, err = M.get_main_output()
  if not output then
    return nil, err
  end
  local wanted = fields or {
    "TotalDPS", "CombinedDPS", "FullDPS", "MinionTotalDPS", "MinionCombinedDPS",
    "Life", "EnergyShield", "Armour", "Evasion",
    "FireResist", "ColdResist", "LightningResist", "ChaosResist",
    "BlockChance", "SpellBlockChance",
    "LifeRegen", "LifeRegenRecovery", "Mana", "ManaRegen", "ManaRegenRecovery",
    "Spirit", "SpiritUnreserved", "WardRegenRecovery",
    "Ward", "DodgeChance", "SpellDodgeChance",
    "TotalEHP",
  }
  local result = {}
  for _, k in ipairs(wanted) do
    if type(output[k]) ~= 'nil' then
      result[k] = output[k]
    elseif k == 'MinionTotalDPS' or k == 'MinionCombinedDPS' then
      -- PoB2 stores selected-minion stats in mainOutput.Minion.
      local stat = k:sub(7)
      result[k] = output.Minion and output.Minion[stat]
    end
  end
  -- include some metadata if available
  result._meta = result._meta or {}
  result._meta.game = 'poe2'
  if build and build.spec and build.spec.treeVersion then
    result._meta.treeVersion = tostring(build.spec.treeVersion)
  end
  if build and build.characterLevel then
    result._meta.level = tonumber(build.characterLevel)
  end
  if build and build.buildName then
    result._meta.buildName = tostring(build.buildName)
  end
  return result
end

-- Read current tree allocation and metadata
function M.get_tree()
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  local spec = build.spec
  local out = {
    treeVersion = spec.treeVersion,
    classId = tonumber(spec.curClassId) or 0,
    ascendClassId = tonumber(spec.curAscendClassId) or 0,
    secondaryAscendClassId = tonumber(spec.curSecondaryAscendClassId or 0) or 0,
    nodes = {},
    masteryEffects = {},
    weaponSets = {},
  }
  for id, node in pairs(spec.allocNodes or {}) do
    table.insert(out.nodes, id)
    if node.allocMode and node.allocMode ~= 0 then out.weaponSets[id] = node.allocMode end
  end
  for mastery, effect in pairs(spec.masterySelections or {}) do
    out.masteryEffects[mastery] = effect
  end
  table.sort(out.nodes)
  -- pointsUsed/ascendancyPointsUsed: consumed by the MCP layer to warn on the 8-point
  -- ascendancy cap. These were read as `tree.ascendancyPointsUsed` for a long time while
  -- nothing ever emitted them, so the cap warning could never fire.
  local pointsUsed, ascUsed, secondaryAscUsed, sockets, set1Used, set2Used = spec:CountAllocNodes()
  out.pointsUsed = pointsUsed or 0
  out.ascendancyPointsUsed = ascUsed or 0
  out.secondaryAscendancyPointsUsed = secondaryAscUsed or 0
  out.jewelSocketsUsed = sockets or 0
  out.weaponSet1PointsUsed = set1Used or 0
  out.weaponSet2PointsUsed = set2Used or 0
  return out
end

-- Set tree allocation from parameters
-- params: { classId, ascendClassId, secondaryAscendClassId?, nodes:[int], masteryEffects?:{[id]=effect}, treeVersion? }
function M.set_tree(params)
  if not build or not build.spec then
    return nil, "build/spec not initialized"
  end
  if type(params) ~= 'table' then
    return nil, "invalid params"
  end
  local spec = build.spec
  local classId = tonumber(params.classId or spec.curClassId or 0) or 0
  local ascendId = tonumber(params.ascendClassId or spec.curAscendClassId or 0) or 0
  local secondaryId = tonumber(params.secondaryAscendClassId or spec.curSecondaryAscendClassId or 0) or 0
  local nodes = {}
  if type(params.nodes) == 'table' then
    for _, v in ipairs(params.nodes) do
      local id = tonumber(v)
      if not id or id ~= math.floor(id) then return nil, 'invalid passive node id' end
      table.insert(nodes, id)
    end
  end
  -- PoB2 clears its existing table during import, so pass a copy, even when preserving.
  local mastery = {}
  for key, value in pairs(params.masteryEffects or spec.masterySelections or {}) do mastery[key] = value end
  local hashOverrides = params.hashOverrides or spec.hashOverrides or {}
  local weaponSets = {}
  if params.weaponSets ~= nil then
    for key, value in pairs(params.weaponSets) do
      local id, mode = tonumber(key), tonumber(value)
      if not id or not mode or mode ~= math.floor(mode) or mode < 0 or mode > 2 then
        return nil, 'invalid weapon specialisation map'
      end
      weaponSets[id] = mode
    end
  else
    for id, node in pairs(spec.allocNodes or {}) do weaponSets[id] = node.allocMode or 0 end
  end
  local treeVersion = params.treeVersion or spec.treeVersion
  -- PoB2's sixth argument is the per-node weapon-set map, absent from PoB1's ABI.
  spec:ImportFromNodeList(nil, classId, ascendId, secondaryId, nodes, weaponSets, hashOverrides, mastery, treeVersion)
  build.buildFlag = true
  -- Rebuild calcs to reflect changes
  local output, calcErr = M.get_main_output()
  if not output then return nil, calcErr end
  if spec.AddUndoState then spec:AddUndoState() end
  return true
end

-- Export full build XML
-- Close the current build and return to the build list screen.
function M.close_build()
  if _G.main and main.SetMode then
    main:SetMode('LIST')
    _G.build = nil
    return { ok = true }
  end
  return nil, 'main:SetMode not available'
end

-- Open an existing build XML into PoB's GUI (TCP mode: makes it the active build).
-- Pass xml=nil (or omit) to create a brand-new empty build using PoB's own defaults.
function M.open_build_xml(params)
  if not _G.main or not main.SetMode then
    return nil, 'main:SetMode not available (headless mode?)'
  end
  local path = (type(params) == 'table' and params.path) or ''
  local xml  = (type(params) == 'table' and type(params.xml) == 'string') and params.xml or nil

  -- BuildMode:Init(dbFileName, buildName, buildXML, ...)
  -- dbFileName = nil  → new unsaved build
  -- buildName must be non-nil or Init() immediately returns to LIST mode
  -- BuildMode:Init(dbFileName, buildName, buildXML, ...)
  -- dbFileName = false → new/unsaved build (matches how PoB itself creates new builds)
  -- dbFileName = path  → loading from file
  local buildName = (type(params) == 'table' and params.name) or 'New Build'
  if xml then
    if path ~= '' then
      main:SetMode('BUILD', path, buildName, xml)
    else
      main:SetMode('BUILD', false, buildName, xml)
    end
  else
    main:SetMode('BUILD', false, buildName)
  end

  -- Refresh _G.build reference (may take a frame or two to fully initialize).
  if main.modes and main.modes['BUILD'] then
    _G.build = main.modes['BUILD']
  end
  local ready = not main.newMode and _G.build and _G.build.calcsTab and _G.build.importTab and true or false
  return { ok = true, ready = ready }
end

function M.export_build_xml()
  if not build or not build.SaveDB then
    return nil, 'build not initialized'
  end
  -- Ensure the calculation environment (mainEnv) is populated before saving,
  -- since Build:Save() references calcsTab.mainEnv for PlayerStat elements.
  local output, calcErr = M.get_main_output()
  if not output then return nil, calcErr end
  local xml = build:SaveDB('api-export')
  if not xml then return nil, 'failed to compose xml' end
  return xml
end

-- Save build XML to a file path
function M.save_build(filePath)
  if not filePath or type(filePath) ~= 'string' or filePath == '' then
    return nil, 'missing or invalid file path'
  end
  local xml, err = M.export_build_xml()
  if not xml then return nil, err end
  local f, ferr = io.open(filePath, 'w')
  if not f then return nil, 'cannot open file for writing: ' .. tostring(ferr) end
  local written, writeErr = f:write(xml)
  local closed, closeErr = f:close()
  if not written or not closed then return nil, 'cannot save build: ' .. tostring(writeErr or closeErr) end
  -- Clear PoB's "unsaved changes" flags so the UI doesn't prompt on navigation.
  if build then
    build.modFlag = false
    if build.notesTab  then build.notesTab.modFlag  = false end
    if build.configTab then build.configTab.modFlag = false end
    if build.treeTab   then build.treeTab.modFlag   = false end
    if build.skillsTab then build.skillsTab.modFlag = false end
    if build.itemsTab  then build.itemsTab.modFlag  = false end
  end
  return { size = #xml, path = filePath }
end

-- Set player level and rebuild
function M.set_level(level)
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  local lvl = integer(level, MIN_PLAYER_LEVEL, MAX_PLAYER_LEVEL)
  if not lvl then return nil, 'level must be an integer from 1 to 100' end
  return mutate(build.configTab,function()
    build.characterLevel, build.characterLevelAutoMode = lvl, false
    build.configTab:BuildModList()
    return true
  end)
end

-- Switch the visible GUI tab (build.viewMode). TCP/GUI only; harmless headless.
-- These are exactly the modes PoB's own tab buttons set (see Modules/Build.lua);
-- the frame loop redraws to the selected tab on the next frame.
local VALID_VIEW_MODES = {
  TREE = true, SKILLS = true, ITEMS = true, CALCS = true,
  CONFIG = true, NOTES = true, IMPORT = true, PARTY = true, COMPARE = true,
}
function M.set_view_mode(mode)
  if not build then
    return nil, 'build not initialized'
  end
  if type(mode) ~= 'string' or mode == '' then
    return nil, 'missing mode'
  end
  local m = string.upper(mode)
  if not VALID_VIEW_MODES[m] then
    return nil, 'invalid view mode "' .. tostring(mode) .. '" (expected TREE/SKILLS/ITEMS/CALCS/CONFIG/NOTES/IMPORT/PARTY/COMPARE)'
  end
  build.viewMode = m
  return true, m
end

-- Basic build info
function M.get_build_info()
  if not build then return nil, 'build not initialized' end
  local spec = build.spec
  -- build.buildClassName / build.buildAscendName are not real PoB fields (never defined
  -- anywhere in the codebase, upstream or ours) -- always nil, so class/ascendancy always
  -- reported as "Unknown"/"None" regardless of the actual build. The real, live values are
  -- on the passive spec: curClassName / curAscendClassName (see PassiveSpec.lua's own
  -- display logic, which prefers curClassName when no ascendancy is selected, i.e.
  -- curAscendClassId == 0).
  local className = spec and spec.curClassName or nil
  local ascendClassName = nil
  if spec and spec.curAscendClassId and spec.curAscendClassId ~= 0 then
    ascendClassName = spec.curAscendClassName
  end
  local info = {
    name = build.buildName,
    level = build.characterLevel,
    className = className,
    ascendClassName = ascendClassName,
    treeVersion = (spec and spec.treeVersion) or build.targetVersion or nil,
    game = 'poe2',
  }
  return info
end

-- Update tree by delta lists
-- Incrementally add/remove passive nodes.
--
-- Adds are routed through PoB's own spec:AllocNode(), which allocates the target AND every
-- node along node.path -- i.e. real auto-pathing. The previous implementation simply unioned
-- the requested IDs into a node list and handed it to ImportFromNodeList, which SILENTLY DROPS
-- anything not already connected to the tree. Asking for one non-adjacent notable therefore
-- allocated nothing while still reporting success.
--
-- Returns actual outcomes (never the requested counts) so callers cannot report a phantom edit:
--   added        - nodes newly allocated that the caller explicitly asked for
--   removed      - nodes actually deallocated
--   autoPathedNodes - intermediates PoB pulled in to maintain connectivity
--   droppedNodes - requested adds that could NOT be allocated (no path / bad ID)
--   skippedAscendancyNodes - adds refused because they'd exceed the 8-point ascendancy cap
function M.update_tree_delta(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  local spec = build.spec
  local current, err = M.get_tree()
  if not current then return nil, err end
  params = params or {}

  local before = {}
  for _, id in ipairs(current.nodes) do before[tonumber(id)] = true end

  -- Phase 1: removals, via ImportFromNodeList (rebuilding the list is the only way to
  -- deallocate, and it correctly prunes anything orphaned by the removal).
  local removeReq = {}
  if type(params.removeNodes) == 'table' then
    for _, id in ipairs(params.removeNodes) do removeReq[tonumber(id)] = true end
  end
  if next(removeReq) then
    local keep = {}
    for id in pairs(before) do
      if not removeReq[id] then table.insert(keep, id) end
    end
    table.sort(keep)
    local classId  = params.classId or current.classId or 0
    local ascendId = params.ascendClassId or current.ascendClassId or 0
    local secId    = params.secondaryAscendClassId or current.secondaryAscendClassId or 0
    local tv       = params.treeVersion or current.treeVersion
    local ok, importError = M.set_tree({
      classId=classId, ascendClassId=ascendId, secondaryAscendClassId=secId,
      nodes=keep, weaponSets=params.weaponSets or current.weaponSets,
      masteryEffects=current.masteryEffects, treeVersion=tv,
    })
    if not ok then return nil, importError end
  end

  -- Phase 2: additions, via PoB's pathfinder.
  local addReq, dropped, skippedAsc = {}, {}, {}
  if type(params.addNodes) == 'table' then
    for _, id in ipairs(params.addNodes) do
      local n = tonumber(id)
      if n then addReq[n] = true end
    end
  end
  if next(addReq) then
    -- Populates node.path / node.pathDist, which AllocNode walks.
    spec:BuildAllDependsAndPaths()
    -- Deterministic order so a failure is reproducible rather than pairs()-order dependent.
    local ordered = {}
    for id in pairs(addReq) do table.insert(ordered, id) end
    table.sort(ordered)
    for _, id in ipairs(ordered) do
      -- Node keys may be numeric or string depending on how the spec was built; probe both
      -- (same defensive lookup as calc_with).
      local node = spec.nodes[id] or spec.nodes[tostring(id)]
      local function isAllocated()
        return (spec.allocNodes[id] or spec.allocNodes[tostring(id)]) ~= nil
      end
      if not node then
        table.insert(dropped, id)
      elseif not isAllocated() then
        local _, ascUsed = spec:CountAllocNodes()
        if node.ascendancyName and (ascUsed or 0) >= 8 then
          table.insert(skippedAsc, id)
        else
          spec:AllocNode(node)
          -- AllocNode is a no-op when node.path is nil (unreachable).
          if not isAllocated() then
            table.insert(dropped, id)
          else
            -- Newly reachable nodes may exist now; refresh paths for the next iteration.
            spec:BuildAllDependsAndPaths()
          end
        end
      end
    end
  end

  spec:BuildAllDependsAndPaths()
  build.buildFlag = true
  local output, calcErr = M.get_main_output()
  if not output then return nil, calcErr end
  if spec.AddUndoState then spec:AddUndoState() end

  -- Phase 3: report what ACTUALLY happened by diffing against the pre-edit snapshot.
  local after, added, removed, autoPathed = {}, {}, {}, {}
  for id in pairs(spec.allocNodes or {}) do after[tonumber(id)] = true end
  for id in pairs(after) do
    if not before[id] then
      if addReq[id] then table.insert(added, id) else table.insert(autoPathed, id) end
    end
  end
  for id in pairs(before) do
    if not after[id] then table.insert(removed, id) end
  end
  table.sort(added); table.sort(removed); table.sort(autoPathed)
  table.sort(dropped); table.sort(skippedAsc)

  return {
    added = added,
    removed = removed,
    autoPathedNodes = autoPathed,
    droppedNodes = dropped,
    skippedAscendancyNodes = skippedAsc,
  }
end


-- Calculate what-if scenario without persisting changes
-- params: { addNodes?: number[], removeNodes?: number[], masteryEffects?: {[id]=effectId}, useFullDPS?: boolean }
function M.calc_with(params)
  if not build or not build.calcsTab or not build.spec then return nil, 'build not initialized' end
  params = params or {}
  local spec, override, patches = build.spec, {}, {}
  for _,operation in ipairs({'addNodes','removeNodes'}) do
    if params[operation] then
      if type(params[operation]) ~= 'table' then return nil,operation .. ' must be an array' end
      local nodes = {}
      for _,value in ipairs(params[operation]) do
        local id = integer(value,1)
        local node = id and (spec.nodes[id] or spec.nodes[tostring(id)])
        if not node then return nil,'passive node not found: '..tostring(value) end
        local allocated = spec.allocNodes[node.id] ~= nil
        if (operation == 'addNodes' and not allocated) or (operation == 'removeNodes' and allocated) then nodes[node] = true end
      end
      if next(nodes) then override[operation] = nodes end
    end
  end
  if params.masteryEffects then
    if type(params.masteryEffects) ~= 'table' then return nil,'masteryEffects must be a map' end
    for key,value in pairs(params.masteryEffects) do
      local node = spec.nodes[tonumber(key)]
      local effect = spec.tree and spec.tree.masteryEffects and spec.tree.masteryEffects[tonumber(value)]
      if not node or not effect then return nil,'mastery effect is unavailable in this PoB2 tree' end
      if not spec.allocNodes[node.id] and not (override.addNodes and override.addNodes[node]) then
        return nil,'mastery must be allocated or included in addNodes'
      end
      table.insert(patches,{node=node,effect=effect})
    end
  end
  local view, saved = build.viewMode, {}
  local ok, out, baseOut = pcall(function()
    local calculator, baseline = build.calcsTab:GetMiscCalculator()
    if not calculator then error('PoB2 misc calculator unavailable; rebuild the build first') end
    if not next(override) and #patches == 0 then return baseline,baseline end
    for _,patch in ipairs(patches) do
      local node = patch.node
      saved[node] = copyTable(node,true)
      -- ProcessStats can rewrite sd, mods, modKey and modList. Do not mutate the
      -- shared effect description and restore every node field even if parsing throws.
      node.sd = copyTable(patch.effect.sd)
      spec.tree:ProcessStats(node)
    end
    build.viewMode = 'CALCULATOR'
    local result = calculator(override,params.useFullDPS == true)
    if not result then error('PoB2 calculator returned no output') end
    return result,baseline
  end)
  build.viewMode = view
  for node,state in pairs(saved) do
    wipeTable(node)
    for k,v in pairs(state) do node[k] = v end
  end
  if not ok then return nil,tostring(out) end
  return out,baseOut
end


-- Get basic config values
function M.get_config()
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  local tab, cfg = build.configTab, {}
  local set = tab.configSets and tab.configSets[tab.activeConfigSetId]
  for k, v in pairs(set and set.input or tab.input or {}) do
    if type(v) == 'string' or type(v) == 'number' or type(v) == 'boolean' then cfg[k] = v end
  end
  -- enemyLevel is the persisted override; effectiveEnemyLevel includes auto/boss defaults.
  cfg.effectiveEnemyLevel = tab.enemyLevel
  cfg.activeConfigSetId = tab.activeConfigSetId
  return cfg
end

-- Set selected config values and rebuild
function M.set_config(params)
  if not build or not build.configTab then return nil, 'build/config not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local tab, applied = build.configTab, {}
  local set = tab.configSets and tab.configSets[tab.activeConfigSetId]
  if not set then return nil, 'active PoB2 config set not found' end
  local registry = {}
  for _, entry in ipairs(LoadModule('Modules/ConfigOptions')) do
    if entry.var then registry[entry.var] = entry end
  end
  -- Validate the WHOLE batch before any write. PoE2 uses quest reward options,
  -- not bandits/Pantheon. Unknown values must never be saved as inert configuration.
  for k, v in pairs(params) do
    if k == 'bandit' or k == 'pantheonMajorGod' or k == 'pantheonMinorGod' then
      return nil, k .. ' is PoE1-only; PoE2 quest rewards use the ConfigOptions quest variables'
    end
    local entry = registry[k]
    if not entry or not tab.varControls[k] then return nil, 'unknown config option "' .. tostring(k) .. '"' end
    if entry.type == 'check' then
      if v == true or v == 'true' or v == 1 then applied[k] = true
      elseif v == false or v == 'false' or v == 0 then applied[k] = false
      else return nil, 'config option "' .. k .. '" expects a boolean' end
    elseif entry.type == 'list' then
      local found = false
      for _, option in ipairs(entry.list) do
        if v == option.val or (type(option.val) == 'number' and tonumber(v) == option.val) then
          applied[k], found = option.val, true; break
        end
      end
      if not found then return nil, 'invalid value for config option "' .. k .. '"' end
    elseif entry.type == 'text' then
      if type(v) ~= 'string' then return nil, 'config option "' .. k .. '" expects text' end
      applied[k] = v
    elseif entry.type == 'count' or entry.type == 'integer' or entry.type == 'countAllowZero' or entry.type == 'float' then
      local n = tonumber(v)
      if not n or n ~= n or math.abs(n) == math.huge or (entry.type ~= 'float' and not integer(n))
          or (entry.type ~= 'integer' and n < 0) then
        return nil, 'invalid number for config option "' .. k .. '"'
      end
      applied[k] = n
    else return nil, 'unsupported PoB2 config control: ' .. tostring(entry.type) end
  end
  return mutate(tab, function()
    for k,v in pairs(applied) do set.input[k] = v end
    tab:UpdateControls()
    tab:BuildModList()
    return { applied = applied }
  end)
end


-- Skills API
function M.get_skills()
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end
  local groups = {}
  for idx, g in ipairs(build.skillsTab.socketGroupList or {}) do
    local names = {}
    if g.displaySkillList then
      for _, eff in ipairs(g.displaySkillList) do
        if eff and eff.activeEffect and eff.activeEffect.grantedEffect then
          table.insert(names, eff.activeEffect.grantedEffect.name)
        end
      end
    end
    local gems = {}
    if g.gemList then
      for gemIdx, gem in ipairs(g.gemList) do
        local grantedEffect = gem.grantedEffect or (gem.gemData and gem.gemData.grantedEffect)
        local isSupport = grantedEffect ~= nil and grantedEffect.support == true
        table.insert(gems, {
          index = gemIdx,
          name = gem.nameSpec or '?',
          level = gem.level or 1,
          quality = gem.quality or 0,
          enabled = gem.enabled ~= false,
          is_support = isSupport,
          gemId = gem.gemId,
          skillId = gem.skillId,
          skillMinion = gem.skillMinion,
          statSet = gem.statSet,
          error = gem.errMsg,
        })
      end
    end
    table.insert(groups, {
      index = idx,
      label = g.label,
      slot = g.slot,
      enabled = g.enabled,
      includeInFullDPS = g.includeInFullDPS,
      mainActiveSkill = g.mainActiveSkill,
      source = g.source,
      noSupports = g.noSupports,
      count = g.groupCount,
      skills = names,
      gems = gems,
    })
  end
  local result = {
    mainSocketGroup = build.mainSocketGroup,
    activeSkillSetId = build.skillsTab.activeSkillSetId,
    calcsSkillNumber = build.calcsTab.input and build.calcsTab.input.skill_number or nil,
    groups = groups,
  }
  return result
end

function M.set_main_selection(params)
  if not build or not build.skillsTab or not build.calcsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local idx = integer(params.mainSocketGroup or build.mainSocketGroup,1)
  local g = idx and build.skillsTab.socketGroupList[idx]
  if not g then return nil, 'invalid mainSocketGroup' end
  local active = integer(params.mainActiveSkill or g.mainActiveSkill or 1,1)
  local effect = active and g.displaySkillList and g.displaySkillList[active] and g.displaySkillList[active].activeEffect
  if params.mainActiveSkill ~= nil and not effect then return nil,'invalid mainActiveSkill' end
  local part = params.skillPart and integer(params.skillPart,1)
  local statSet = params.statSet and integer(params.statSet,1)
  if params.skillPart and not (part and effect and effect.grantedEffect.parts and effect.grantedEffect.parts[part]) then return nil,'invalid skillPart' end
  if params.statSet and not (statSet and effect and effect.grantedEffect.statSets[statSet]) then return nil,'invalid statSet' end
  return mutate(build.skillsTab,function()
    build.mainSocketGroup, build.calcsTab.input.skill_number = idx, idx
    g.mainActiveSkill, g.mainActiveSkillCalcs = active, active
    if part then effect.srcInstance.skillPart, effect.srcInstance.skillPartCalcs = part, part end
    if statSet then
      local src = effect.srcInstance
      src.statSet, src.statSetCalcs = copyTable(src.statSet or {}), copyTable(src.statSetCalcs or {})
      src.statSet[effect.grantedEffect.id], src.statSetCalcs[effect.grantedEffect.id] = statSet, statSet
    end
    return true
  end)
end

-- Items API
function M.add_item_text(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.text) ~= 'string' then return nil, 'missing text' end
  if #params.text == 0 or #params.text > MAX_ITEM_TEXT_LENGTH then return nil, 'invalid item text length' end
  local tab = build.itemsTab
  local slot = params.slotName and tab.slots[params.slotName]
  if params.slotName and not slot then return nil, 'slot not found: ' .. tostring(params.slotName) end
  local ok, item = pcall(new, 'Item', params.text)
  if not ok or not item or not item.baseName then return nil, 'failed to parse item: ' .. tostring(item) end
  if slot and not tab:IsItemValidForSlot(item, slot.slotName) then
    return nil, 'item is not valid for slot: ' .. slot.slotName
  end
  return mutate(tab, function()
    item:NormaliseQuality()
    tab:AddItem(item, params.noAutoEquip == true or slot ~= nil)
    if slot then slot:SetSelItemId(item.id) end
    tab:PopulateSlots()
    local equipped
    for _, candidate in ipairs(tab.orderedSlots) do
      if candidate.selItemId == item.id then equipped = candidate.slotName; break end
    end
    if slot and slot.selItemId ~= item.id then return nil, 'PoB2 rejected equipment assignment' end
    return { id = item.id, name = item.name, slot = equipped, equipped = equipped ~= nil }
  end)
end

-- Clear (unequip) an item from a specific slot
-- params: { slotName: string }
function M.clear_item_slot(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  local slotName = type(params) == 'table' and params.slotName
  local tab = build.itemsTab
  local slot = slotName and tab.slots[slotName]
  if not slot then return nil, 'slot not found: ' .. tostring(slotName) end
  return mutate(tab, function()
    slot:SetSelItemId(0)
    tab:PopulateSlots()
    return {slot=slotName, cleared=true}
  end)
end

function M.set_flask_active(params)
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  if type(params) ~= 'table' or type(params.active) ~= 'boolean' then return nil, 'active must be a boolean' end
  -- Compatibility: index 1/2 means life/mana flask. Charms use their explicit
  -- PoB2 slotName (Charm 1..3); never reinterpret PoE1 flask indices 3..5.
  local slotName = params.slotName
  if slotName == nil then
    local idx = integer(params.index, 1, NUM_FLASK_SLOTS)
    if not idx then return nil, 'invalid flask index (PoE2 has 2 flasks; use slotName for charms)' end
    slotName = 'Flask ' .. idx
  end
  local kind, idx = tostring(slotName):match('^(%a+) (%d+)$')
  if not ((kind == 'Flask' and integer(idx,1,NUM_FLASK_SLOTS)) or
      (kind == 'Charm' and integer(idx,1,NUM_CHARM_SLOTS))) then return nil, 'invalid flask/charm slot' end
  local tab = build.itemsTab
  local slot = tab.slots[slotName]
  local entry = tab.activeItemSet and tab.activeItemSet[slotName]
  if not slot or not entry then return nil, 'slot not found' end
  return mutate(tab, function()
    slot.active, entry.active = params.active, params.active
    if slot.controls.activate then slot.controls.activate.state = params.active end
    return true
  end)
end


-- Get equipped items summary
function M.get_items()
  if not build or not build.itemsTab then return nil, 'items not initialized' end
  local itemsTab = build.itemsTab
  local result = { }
  -- Prefer orderedSlots for deterministic order
  local ordered = itemsTab.orderedSlots or {}
  local seen = {}
  local function add_slot(slotName)
    if seen[slotName] then return end
    seen[slotName] = true
    local slotCtrl = itemsTab.slots[slotName]
    if not slotCtrl then return end
    local selId = slotCtrl.selItemId or 0
    local entry = { slot = slotName, id = selId }
    if selId > 0 then
      local it = itemsTab.items[selId]
      if it then
        entry.name = it.name
        entry.baseName = it.baseName
        entry.type = it.type
        entry.rarity = it.rarity
        entry.raw = it.raw
      end
    end
    -- PoB2 flask/charm activation is read from the live control.
    local set = itemsTab.activeItemSet
    if set and set[slotName] and set[slotName].active ~= nil then
      entry.active = slotCtrl.active == true
    end
    table.insert(result, entry)
  end
  for _, slot in ipairs(ordered) do
    if slot and slot.slotName then add_slot(slot.slotName) end
  end
  -- Add any remaining slots not in ordered list
  for slotName, _ in pairs(itemsTab.slots or {}) do add_slot(slotName) end
  return result
end


-- PoB2 keeps independent skillSets; socketGroupList aliases only the active set.
local function skill_group(params, allowSource)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local tab = build.skillsTab
  local set = tab.skillSets[tab.activeSkillSetId]
  local idx = integer(params.groupIndex, 1)
  local group = set and idx and set.socketGroupList[idx]
  if not group then return nil, 'socket group not found' end
  if group.source and not allowSource then
    return nil, 'generated PoB2 group: create a separate support group in the same slot'
  end
  return group, tab, idx
end

local function resolve_gem(name)
  local gems = build and build.data and build.data.gems or data and data.gems
  if not gems or type(name) ~= 'string' then return nil, 'gem name or ID required' end
  if gems[name] then return gems[name] end
  local found
  for _, gem in pairs(gems) do
    if (gem.name and gem.name:lower() == name:lower()) or (gem.nameSpec and gem.nameSpec:lower() == name:lower()) then
      if found then return nil, 'ambiguous gem name; use a PoB2 gem ID' end
      found = gem
    end
  end
  if not found then return nil, 'gem not found: ' .. name end
  return found
end

local function gem_values(params, gem)
  if params.qualityId and params.qualityId ~= 'Default' then
    return nil, 'PoE1 alternate quality IDs are unsupported; PoB2 uses its gem quality/altQualityStats data'
  end
  local level = params.level ~= nil and integer(params.level,1) or gem.naturalMaxLevel
  if not level or not gem.grantedEffect.levels[level] then return nil, 'level is not present in PoB2 gem data' end
  if params.level ~= nil and not integer(params.level,1) then return nil, 'invalid gem level' end
  -- Matches PoB2 SkillsTab's two-digit quality control (no PoE1 23% assumption).
  local quality = params.quality == nil and 0 or integer(params.quality,0,99)
  if quality == nil then return nil, 'quality must be an integer from 0 to 99' end
  return {level=level,quality=quality}
end

function M.create_socket_group(params)
  if not build or not build.skillsTab then return nil, 'skills not initialized' end
  params = params or {}
  local tab = build.skillsTab
  local set = tab.skillSets[tab.activeSkillSetId]
  if not set then return nil, 'active skill set not found' end
  if params.slot and params.slot ~= '' and not build.itemsTab.slots[params.slot] then return nil, 'unknown equipment slot' end
  local count = params.count == nil and 1 or integer(params.count,1)
  if not count then return nil, 'count must be a positive integer' end
  return mutate(tab, function()
    local group = {label=params.label or '',slot=params.slot,enabled=params.enabled ~= false,
      includeInFullDPS=params.includeInFullDPS == true,groupCount=count,gemList={},mainActiveSkill=1,mainActiveSkillCalcs=1}
    table.insert(set.socketGroupList,group)
    tab:ProcessSocketGroup(group)
    tab:SetDisplayGroup(group)
    return {index=#set.socketGroupList,label=group.label,activeSkillSetId=tab.activeSkillSetId}
  end)
end

function M.add_gem(params)
  local group, tab = skill_group(params)
  if not group then return nil, tab end
  local gem, err = resolve_gem(params.gemId or params.gemName)
  if not gem then return nil, err end
  if gem.grantedEffect.hideFromSideBar then return nil, 'gem cannot be inserted as an active skill' end
  if gem.grantedEffect.support and group.noSupports then return nil, 'group cannot accept supports' end
  local values, valueErr = gem_values(params,gem)
  if not values then return nil,valueErr end
  local count = params.count == nil and 1 or integer(params.count,1)
  if not count then return nil, 'count must be a positive integer' end
  return mutate(tab, function()
    local instance = {gemId=gem.id,skillId=gem.grantedEffectId,gemData=gem,nameSpec=gem.name,
      level=values.level,quality=values.quality,enabled=params.enabled ~= false,
      enableGlobal1=true,enableGlobal2=true,count=count,corruptLevel=0,corrupted=false}
    table.insert(group.gemList,instance)
    tab:ProcessSocketGroup(group)
    if instance.errMsg or not instance.gemData then return nil,instance.errMsg or 'PoB2 rejected gem' end
    return {gemIndex=#group.gemList,name=instance.nameSpec,level=instance.level,gemId=instance.gemId}
  end)
end

local function edit_gem(params, edit)
  local group, tab = skill_group(params)
  if not group then return nil, tab end
  local idx = integer(params.gemIndex,1)
  local gem = idx and group.gemList[idx]
  if not gem then return nil, 'gem not found' end
  return mutate(tab, function()
    local ok, err = edit(gem,group,idx)
    if not ok then return nil,err end
    tab:ProcessSocketGroup(group)
    return true
  end)
end

function M.set_gem_level(params)
  return edit_gem(params, function(gem)
    local effect = gem.grantedEffect or gem.gemData and gem.gemData.grantedEffect
    local level = integer(params.level,1)
    if not level or not effect or not effect.levels[level] then return nil, 'level is not present in PoB2 gem data' end
    gem.level = level
    return true
  end)
end

function M.set_gem_quality(params)
  return edit_gem(params, function(gem)
    if params.qualityId and params.qualityId ~= 'Default' then return nil, 'PoE1 alternate quality IDs are unsupported' end
    local quality = integer(params.quality,0,99)
    if not quality then return nil,'quality must be an integer from 0 to 99' end
    gem.quality = quality
    return true
  end)
end

function M.remove_skill(params)
  local group, tab, idx = skill_group(params)
  if not group then return nil, tab end
  return mutate(tab,function()
    table.remove(tab.socketGroupList,idx)
    local function adjust(n) return math.max(1, math.min(#tab.socketGroupList, n > idx and n-1 or n)) end
    build.mainSocketGroup = adjust(build.mainSocketGroup or 1)
    build.calcsTab.input.skill_number = adjust(build.calcsTab.input.skill_number or 1)
    tab:SetDisplayGroup(tab.socketGroupList[build.mainSocketGroup])
    return true
  end)
end

function M.remove_gem(params)
  return edit_gem(params,function(gem,group,idx) table.remove(group.gemList,idx); return true end)
end

-- Search for passive tree nodes by keyword
-- params: { keyword: string, nodeType?: string ('normal'|'notable'|'keystone'), maxResults?: number, includeAllocated?: boolean }
-- Return PoB2's current normalized node type and processed stat descriptions.
-- This includes its attribute selections and any engine-applied transformations.
--
-- Returns a flat structure:
--   { id, dn, type, allocated, sd, conqueredBy = {seed, conqueror_type} | nil }
--
-- dn is the (possibly transformed) display name. sd is the array of
-- (possibly transformed) stat description lines. conqueredBy is set only when
-- installed engine provides transformation metadata (it is not synthesized).
function M.get_node_state(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' then return nil, 'missing params' end
  local nodeId = params.node_id or params.nodeId
  if not nodeId then return nil, 'missing node_id' end
  -- node IDs may arrive as strings; PoB indexes by numeric ID
  local idNum = tonumber(nodeId)
  if not idNum then return nil, 'node_id must be numeric' end

  local node = build.spec.nodes and build.spec.nodes[idNum]
  if not node then return nil, 'node not found: ' .. tostring(nodeId) end

  local allocated = build.spec.allocNodes and build.spec.allocNodes[idNum] ~= nil

  local nType = 'normal'
  if node.type == 'Keystone' or node.isKeystone then nType = 'keystone'
  elseif node.type == 'Notable' or node.isNotable then nType = 'notable'
  elseif node.type == 'Socket' or node.isJewelSocket then nType = 'jewel'
  elseif node.type == 'Mastery' then nType = 'mastery'
  elseif node.ascendancyName then nType = 'ascendancy'
  end

  -- Copy stat descriptions defensively; PoB may reuse the underlying table.
  local sd = {}
  if type(node.sd) == 'table' then
    for i, line in ipairs(node.sd) do sd[i] = line end
  end

  local conqueredBy = nil
  if node.conqueredBy then
    local cq = node.conqueredBy
    conqueredBy = {
      seed = cq.id,
      conqueror_type = cq.conqueror and cq.conqueror.type or nil,
    }
  end

  return {
    id = idNum,
    dn = node.dn or node.name,
    type = nType,
    allocated = allocated,
    sd = sd,
    conqueredBy = conqueredBy,
    ascendancyName = node.ascendancyName,
  }
end

-- Tabulate the modifiers contributing to a given stat, with source
-- attribution. Uses the live calc env's player (or minion) modDB and
-- ModStore:Tabulate to enumerate each contributing modifier's value, type
-- (BASE/INC/MORE/OVERRIDE/FLAG), and source ("Tree:nodeId", item name, etc).
--
-- Accuracy note: a nil config is used, so only UNCONDITIONAL modifiers are
-- captured. This is complete for defensive/attribute stats (Life, resists,
-- Strength, Armour, EnergyShield, regen, etc.) but INCOMPLETE for damage and
-- other skill-conditional stats, where mods depend on the active skill's
-- config. The caller is told this so it can scope expectations.
function M.get_stat_breakdown(params)
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  if type(params) ~= 'table' then return nil, 'missing params' end
  local statName = params.stat or params.name
  if type(statName) ~= 'string' or statName == '' then
    return nil, 'missing stat name'
  end

  local output, calcErr = M.get_main_output()
  if not output then return nil, calcErr end
  local env = build.calcsTab.mainEnv
  if not env then return nil, 'no calc env available' end

  local actorName = (params.actor == 'minion') and 'minion' or 'player'
  local actor = env[actorName]
  if not actor then return nil, 'no actor ' .. actorName end

  -- Choose the modifier store + config:
  --   default            -> actor.modDB with nil cfg (unconditional mods only)
  --   use_skill_config    -> the MAIN skill's skillModList + skillCfg, which
  --                          captures skill-conditional mods (damage, speed,
  --                          crit, etc.) for that specific skill.
  local store, cfg, configMode, configNote
  if params.use_skill_config then
    local skill = actor.mainSkill
    if not skill or not skill.skillModList or not skill.skillCfg then
      return nil, 'no main skill / skill config available for actor ' .. actorName
    end
    store = skill.skillModList
    cfg = skill.skillCfg
    configMode = 'skill'
    local ge = skill.activeEffect and skill.activeEffect.grantedEffect
    configNote = ge and ge.name or 'main skill'
  else
    store = actor.modDB
    cfg = nil
    configMode = 'global'
    if not store then return nil, 'no modDB for actor ' .. actorName end
  end

  local contributions = {}
  local modTypes = { 'BASE', 'INC', 'MORE', 'OVERRIDE', 'FLAG' }
  for _, modType in ipairs(modTypes) do
    local ok, tab = pcall(function() return store:Tabulate(modType, cfg, statName) end)
    if ok and type(tab) == 'table' then
      for _, entry in ipairs(tab) do
        local mod = entry.mod
        local v = entry.value
        -- Keep only JSON-safe scalar values; skip table-valued (LIST) mods.
        local vt = type(v)
        if vt == 'number' or vt == 'boolean' or vt == 'string' then
          table.insert(contributions, {
            modType = modType,
            value = v,
            source = (mod and mod.source) or '?',
            name = (mod and mod.name) or statName,
            flags = (mod and mod.flags) or 0,
          })
        end
      end
    end
  end

  -- Aggregate inc-sum / more-product for this mod name (the inc-vs-more
  -- diagnosis). Single mod name only — not the full damage stat set.
  local incSum, moreProduct
  pcall(function() incSum = store:Sum('INC', cfg, statName) end)
  pcall(function() moreProduct = store:More(cfg, statName) end)

  local output = actor.output or {}
  local outVal = nil
  if output and type(output[statName]) ~= 'nil' then
    outVal = output[statName]
  end

  return {
    stat = statName,
    actor = actorName,
    config = configMode,
    config_note = configNote,
    output_value = outVal,
    inc_sum = incSum,
    more_multiplier = moreProduct,
    contributions = contributions,
  }
end

-- Strip PoB console color codes (^7, ^xRRGGBB) from a display string.
local function stripColorCodes(s)
  if type(s) ~= 'string' then return s end
  s = s:gsub('%^[xX]%x%x%x%x%x%x', '')
  s = s:gsub('%^%d', '')
  return s
end

-- Keys that hold heavy object refs / potential cycles — never recurse into them.
local BREAKDOWN_SKIP_KEYS = {
  item = true, modList = true, cfg = true, actor = true, env = true,
  skill = true, mainSkill = true, parent = true, mod = true,
}

-- Flatten one of PoB's heterogeneous breakdown entries into display text
-- lines. Handles: plain strings, nested string arrays, `.label`, `.slots`
-- (per-source rows), `.rowList`/`.colList` (table displays), and generic
-- scalar named fields. Skips heavy object refs. Depth-guarded.
local function flattenBreakdown(entry, lines, indent, depth)
  depth = depth or 0
  indent = indent or ''
  if depth > 6 then return end
  local t = type(entry)
  if t == 'string' then
    local s = stripColorCodes(entry)
    if s and s:gsub('%s', '') ~= '' then table.insert(lines, indent .. s) end
    return
  elseif t == 'number' or t == 'boolean' then
    table.insert(lines, indent .. tostring(entry))
    return
  elseif t ~= 'table' then
    return
  end

  if type(entry.label) == 'string' then
    table.insert(lines, indent .. stripColorCodes(entry.label))
  end

  -- array part (the common multiplier-chain lines)
  for _, v in ipairs(entry) do
    flattenBreakdown(v, lines, indent, depth + 1)
  end

  -- per-source slot rows
  if type(entry.slots) == 'table' then
    for _, slot in ipairs(entry.slots) do
      if type(slot) == 'table' then
        local src = stripColorCodes(tostring(slot.sourceName or slot.source or '?'))
        local parts = { indent .. '  ' .. src .. ':' }
        if slot.base ~= nil then table.insert(parts, ' base ' .. tostring(slot.base)) end
        if slot.inc then table.insert(parts, stripColorCodes(tostring(slot.inc))) end
        if slot.more then table.insert(parts, stripColorCodes(tostring(slot.more))) end
        if slot.total ~= nil then table.insert(parts, ' = ' .. stripColorCodes(tostring(slot.total))) end
        table.insert(lines, table.concat(parts))
      end
    end
  end

  -- table display (rowList + colList)
  if type(entry.rowList) == 'table' and type(entry.colList) == 'table' then
    local cols = {}
    for _, col in ipairs(entry.colList) do
      if type(col) == 'table' and col.key then table.insert(cols, col) end
    end
    for _, row in ipairs(entry.rowList) do
      if type(row) == 'table' then
        local cells = {}
        for _, col in ipairs(cols) do
          local val = row[col.key]
          if val ~= nil then
            local label = col.label and stripColorCodes(tostring(col.label)) or col.key
            table.insert(cells, label .. '=' .. stripColorCodes(tostring(val)))
          end
        end
        if #cells > 0 then table.insert(lines, indent .. '  ' .. table.concat(cells, '  ')) end
      end
    end
  end

  -- generic scalar named fields not handled above (surfaces unexpected shapes)
  for k, v in pairs(entry) do
    if type(k) == 'string' and not BREAKDOWN_SKIP_KEYS[k]
       and k ~= 'label' and k ~= 'slots' and k ~= 'rowList' and k ~= 'colList' then
      local vt = type(v)
      if vt == 'string' then
        local s = stripColorCodes(v)
        if s and s:gsub('%s', '') ~= '' then table.insert(lines, indent .. k .. ': ' .. s) end
      elseif vt == 'number' or vt == 'boolean' then
        table.insert(lines, indent .. k .. ': ' .. tostring(v))
      end
    end
  end
end

-- Surface PoB's own computed breakdown for an output stat (the multiplier
-- chain shown on the Calcs tab): base -> added -> conversion -> increased ->
-- more -> crit -> ailment, etc. Reads the CALCS-mode env that PoB already
-- builds and keeps (build.calcsTab.calcsEnv) — no extra calc run, and no math
-- re-derived on our side; we just flatten PoB's display structure to text.
function M.get_calc_breakdown(params)
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  if type(params) ~= 'table' then params = {} end

  local output, calcErr = M.get_main_output()
  if not output then return nil, calcErr end
  local env = build.calcsTab.calcsEnv
  if not env then return nil, 'no CALCS env available (breakdowns require CALCS mode)' end
  local actorName = (params.actor == 'minion') and 'minion' or 'player'
  local actor = env[actorName]
  if not actor then return nil, 'no actor ' .. actorName end
  local bd = actor.breakdown
  if type(bd) ~= 'table' then return nil, 'no breakdown table for actor ' .. actorName end

  -- enumerate available breakdown keys (stats that currently have one).
  -- Skip function values: PoB stores its breakdown.* helper builders (mod,
  -- slot, simple, multiChain, area, dot, critDot, effMult, leech) on the
  -- same table — those are not stat breakdowns.
  local available = {}
  for k, v in pairs(bd) do
    if type(k) == 'string' and type(v) ~= 'function' then
      table.insert(available, k)
    end
  end
  table.sort(available)

  local statName = params.stat or params.name
  if type(statName) ~= 'string' or statName == '' then
    return { available = available }
  end

  local entry = bd[statName]
  if entry == nil then
    return { stat = statName, found = false, available = available }
  end

  local lines = {}
  flattenBreakdown(entry, lines, '', 0)

  local output = actor.output or {}
  local outVal = nil
  if type(output[statName]) ~= 'nil' then outVal = output[statName] end

  return {
    stat = statName,
    found = true,
    actor = actorName,
    output_value = outVal,
    lines = lines,
  }
end

function M.search_nodes(params)
  if not build or not build.spec then return nil, 'build/spec not initialized' end
  if type(params) ~= 'table' or type(params.keyword) ~= 'string' then
    return nil, 'missing or invalid keyword'
  end

  local keyword = params.keyword:lower()
  local nodeType = params.nodeType and params.nodeType:lower() or nil
  if nodeType == "any" or nodeType == "" then nodeType = nil end
  local maxResults = tonumber(params.maxResults) or 50
  local includeAllocated = params.includeAllocated ~= false

  local results = {}
  local count = 0

  -- Get allocated nodes set for quick lookup
  local allocatedSet = {}
  if build.spec.allocNodes then
    for id, _ in pairs(build.spec.allocNodes) do
      allocatedSet[id] = true
    end
  end

  -- Search through all nodes
  for id, node in pairs(build.spec.nodes) do
    if count >= maxResults then break end

    -- Skip if already allocated and we don't want allocated nodes
    if not includeAllocated and allocatedSet[id] then
      goto continue
    end

    -- Filter by node type if specified
    if nodeType then
      local nType = 'normal'
      if node.type == 'Keystone' or node.isKeystone then nType = 'keystone'
      elseif node.type == 'Notable' or node.isNotable then nType = 'notable'
      elseif node.type == 'Socket' or node.isJewelSocket then nType = 'jewel'
      elseif node.type == 'Mastery' then nType = 'mastery'
      elseif node.ascendancyName then nType = 'ascendancy'
      end
      if nType ~= nodeType then goto continue end
    end

    -- Check if keyword matches name
    local matches = false
    if node.name and node.name:lower():find(keyword, 1, true) then
      matches = true
    end

    -- Check if keyword matches stats/modifiers
    if not matches and node.sd then
      for _, stat in ipairs(node.sd) do
        if type(stat) == 'string' and stat:lower():find(keyword, 1, true) then
          matches = true
          break
        end
      end
    end

    -- Check modifiers list
    if not matches and node.modList then
      for _, mod in ipairs(node.modList) do
        local modStr = tostring(mod)
        if modStr:lower():find(keyword, 1, true) then
          matches = true
          break
        end
      end
    end

    if matches then
      local nodeType = 'normal'
      if node.type == 'Keystone' or node.isKeystone then nodeType = 'keystone'
      elseif node.type == 'Notable' or node.isNotable then nodeType = 'notable'
      elseif node.type == 'Socket' or node.isJewelSocket then nodeType = 'jewel'
      elseif node.type == 'Mastery' then nodeType = 'mastery'
      elseif node.ascendancyName then nodeType = 'ascendancy'
      end

      local stats = {}
      if node.sd then
        for _, stat in ipairs(node.sd) do
          if type(stat) == 'string' then
            table.insert(stats, stat)
          end
        end
      end

      table.insert(results, {
        id = id,
        name = node.name or 'Unnamed',
        type = nodeType,
        stats = stats,
        allocated = allocatedSet[id] == true,
        x = node.x,
        y = node.y,
        orbit = node.orbit,
        orbitIndex = node.orbitIndex,
        ascendancyName = node.ascendancyName,
      })
      count = count + 1
    end

    ::continue::
  end

  -- Sort results: keystones first, then notables, then normal
  table.sort(results, function(a, b)
    local typeOrder = { keystone = 1, notable = 2, jewel = 3, mastery = 4, ascendancy = 5, normal = 6 }
    local aOrder = typeOrder[a.type] or 99
    local bOrder = typeOrder[b.type] or 99
    if aOrder ~= bOrder then
      return aOrder < bOrder
    end
    return (a.name or '') < (b.name or '')
  end)

  return { nodes = results, count = #results }
end


-- ============================================================
-- Spec (passive tree spec) management
-- ============================================================

local function spec_info(spec, index, activeIndex)
  return {
    index = index,
    title = spec.title or ('Spec ' .. tostring(index)),
    className = spec.curClassName or 'Unknown',
    ascendClassName = spec.curAscendClassName or 'None',
    nodeCount = spec.allocNodes and (function() local n=0; for _ in pairs(spec.allocNodes) do n=n+1 end; return n end)() or 0,
    treeVersion = spec.treeVersion,
    active = (index == activeIndex),
  }
end

local function get_spec_list()
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  local activeIdx = tt.activeSpec or 1
  local result = {}
  for i, spec in ipairs(specs) do
    table.insert(result, spec_info(spec, i, activeIdx))
  end
  return { specs = result, activeSpec = activeIdx }
end

function M.list_specs()
  return get_spec_list()
end

function M.select_spec(index)
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  if not specs[index] then return nil, 'spec index out of range: ' .. tostring(index) end
  tt:SetActiveSpec(index)
  tt.modFlag = true
  local output, err = M.get_main_output()
  if not output then return nil, err end
  return get_spec_list()
end

function M.create_spec(params)
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  -- Build a REAL PassiveSpec via PoB's own constructor + copy pattern (TreeTab.lua:599-602),
  -- NOT a hand-fabricated table. A plain table omits fields a genuine spec has (jewels, nodes,
  -- allocNodes, hashOverrides, ...); native code that iterates every spec then crashes — e.g.
  -- ItemsTab:DeleteItem does pairs(spec.jewels) during import's clear-items step and throws on
  -- a fake spec, corrupting the import (root-caused 2026-07-09).
  local newSpec
  if params and params.copyFrom and specs[params.copyFrom] then
    local src = specs[params.copyFrom]
    newSpec = new("PassiveSpec", build, src.treeVersion)
    newSpec.title = params.title or ((src.title or 'Default') .. ' (copy)')
    newSpec.jewels = copyTable(src.jewels)
    newSpec:RestoreUndoState(src:CreateUndoState(), src.treeVersion)
  else
    newSpec = new("PassiveSpec", build, latestTreeVersion)
    newSpec.title = (params and params.title) or ('Spec ' .. tostring(#specs + 1))
  end
  table.insert(specs, newSpec)
  tt.specList = specs
  tt.modFlag = true
  local newIdx = #specs
  if params and params.activate then
    tt:SetActiveSpec(newIdx)
    local output, err = M.get_main_output()
    if not output then return nil, err end
  end
  return get_spec_list()
end

function M.delete_spec(index)
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  if #specs <= 1 then return nil, 'cannot delete the last spec' end
  if not specs[index] then return nil, 'spec index out of range: ' .. tostring(index) end
  table.remove(specs, index)
  -- Adjust active spec index if needed
  if tt.activeSpec >= index and tt.activeSpec > 1 then
    tt.activeSpec = tt.activeSpec - 1
  end
  tt:SetActiveSpec(tt.activeSpec)
  tt.modFlag = true
  local output, err = M.get_main_output()
  if not output then return nil, err end
  return get_spec_list()
end

function M.rename_spec(index, title)
  if not build or not build.treeTab then return nil, 'build not initialized' end
  local tt = build.treeTab
  local specs = tt.specList or {}
  if not specs[index] then return nil, 'spec index out of range: ' .. tostring(index) end
  specs[index].title = tostring(title)
  tt.modFlag = true
  return get_spec_list()
end


-- ============================================================
-- Item set management
-- ============================================================

local function itemset_info(set, id, activeId)
  return {
    id = id,
    title = set.title or ('Item Set ' .. tostring(id)),
    useSecondWeaponSet = set.useSecondWeaponSet == true,
    active = (id == activeId),
  }
end

local function get_itemset_list()
  if not build or not build.itemsTab then return nil, 'build not initialized' end
  local it = build.itemsTab
  local sets = it.itemSets or {}
  local order = it.itemSetOrderList or {}
  local activeId = it.activeItemSetId or 1
  local result = {}
  for _, id in ipairs(order) do
    local set = sets[id]
    if set then
      table.insert(result, itemset_info(set, id, activeId))
    end
  end
  return { itemSets = result, activeItemSetId = activeId }
end

function M.list_item_sets()
  return get_itemset_list()
end

function M.select_item_set(id)
  if not build or not build.itemsTab then return nil, 'build not initialized' end
  local tab = build.itemsTab
  id = integer(id,1)
  if not id or not tab.itemSets[id] then return nil,'item set id not found' end
  return mutate(tab,function()
    tab:SetActiveItemSet(id)
    return get_itemset_list()
  end)
end

function M.create_item_set(params)
  if not build or not build.itemsTab then return nil, 'build not initialized' end
  params = params or {}
  local tab = build.itemsTab
  local sourceId = params.copyFrom and integer(params.copyFrom,1)
  if params.copyFrom and not (sourceId and tab.itemSets[sourceId]) then return nil, 'source item set not found' end
  return mutate(tab, function()
    -- NewItemSet already registers the ID in itemSetOrderList in PoB2.
    local set = tab:NewItemSet(nil, params.title)
    if sourceId then
      local source = tab.itemSets[sourceId]
      set.title = params.title or ((source.title or 'Item Set') .. ' (copy)')
      set.useSecondWeaponSet = source.useSecondWeaponSet
      for name, slot in pairs(tab.slots) do
        if not slot.nodeId and set[name] then
          local from = sourceId == tab.activeItemSetId and slot or source[name]
          set[name].selItemId, set[name].active = from.selItemId, from.active
        end
      end
    end
    if params.activate then tab:SetActiveItemSet(set.id) end
    return get_itemset_list()
  end)
end


-- ============================================================
-- Mastery options
-- ============================================================

function M.get_mastery_options()
  if not build or not build.spec then return nil, 'build not initialized' end
  local spec = build.spec
  local result = {}
  for id, node in pairs(spec.nodes or {}) do
    if (node.type == 'Mastery' or node.m or node.isMastery) and not node.ascendancyName then
      local options = {}
      for _, effect in ipairs(node.masteryEffects or {}) do
        local eid = effect.effect  -- effect.effect is the numeric ID; effect.id is nil
        local selected = (spec.masterySelections and spec.masterySelections[node.id] == eid) == true
        table.insert(options, { effectId = eid, stats = effect.stats or {}, selected = selected })
      end
      if #options > 0 then
        table.insert(result, { nodeId = id, name = node.name or node.dn or 'Mastery', options = options })
      end
    end
  end
  return { masteries = result }
end


-- ============================================================
-- Socket group and gem enable/disable toggles
-- ============================================================

function M.set_socket_group_enabled(params)
  local group, tab, idx = skill_group(params, true)
  if not group then return nil, tab end
  if type(params.enabled) ~= 'boolean' then return nil, 'enabled must be a boolean' end
  local count = params.count ~= nil and integer(params.count,1) or group.groupCount
  if params.count ~= nil and not integer(params.count,1) then return nil, 'count must be a positive integer' end
  return mutate(tab,function()
    group.enabled = params.enabled
    if params.includeInFullDPS ~= nil then group.includeInFullDPS = params.includeInFullDPS == true end
    group.groupCount = count
    tab:ProcessSocketGroup(group)
    return {groupIndex=idx,label=group.label or '',enabled=group.enabled,includeInFullDPS=group.includeInFullDPS,count=group.groupCount}
  end)
end

function M.set_gem_enabled(params)
  return edit_gem(params,function(gem)
    if type(params.enabled) ~= 'boolean' then return nil,'enabled must be a boolean' end
    gem.enabled = params.enabled
    return true
  end)
end

-- ============================================================
-- Spectre catalog and per-gem selection (CalcActiveSkill.lua / Build.lua)
-- ============================================================
-- build.spectreList is a catalog, not a count of simultaneously raised monsters.
-- PoB2 selects one entry per gem with skillMinion/skillMinionCalcs.

local function spectre_library()
  local lib = build and build.data and build.data.spectres
  if not lib then return nil, 'spectre data not available' end
  return lib
end

-- Resolve a name or metadata id to an id in the spectre library.
-- Matching: exact id -> exact name (case-insensitive) -> unique substring of name.
local function resolve_spectre(lib, query)
  if lib[query] then return query end
  local q = query:lower()
  local exact, partial = {}, {}
  for id, minion in pairs(lib) do
    local name = (minion.name or ''):lower()
    if name == q then
      table.insert(exact, id)
    elseif name:find(q, 1, true) then
      table.insert(partial, id)
    end
  end
  if #exact == 1 then return exact[1] end
  if #exact > 1 then return nil, 'ambiguous exact name (multiple ids share it)' end
  if #partial == 1 then return partial[1] end
  if #partial > 1 then
    local names = {}
    for i, id in ipairs(partial) do
      if i > 8 then table.insert(names, '...') break end
      table.insert(names, (lib[id].name or id))
    end
    return nil, 'ambiguous: matches ' .. table.concat(names, ', ')
  end
  return nil, 'no spectre matches "' .. query .. '"'
end

function M.list_spectres(params)
  if not build then return nil, 'build not initialized' end
  local lib, err = spectre_library()
  if not lib then return nil, err end
  local active = {}
  for groupIndex, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or {}) do
    for gemIndex, gem in ipairs(group.gemList) do
      local id = gem.skillMinion
      if id and lib[id] then
        table.insert(active,{id=id,name=lib[id].name,groupIndex=groupIndex,gemIndex=gemIndex,enabled=group.enabled ~= false and gem.enabled ~= false})
      end
    end
  end
  local result = { active = active }
  local query = params and params.search
  if query and query ~= '' then
    local q = query:lower()
    local matches = {}
    for id, minion in pairs(lib) do
      if (minion.name or ''):lower():find(q, 1, true) then
        table.insert(matches, { id = id, name = minion.name or '?' })
      end
    end
    table.sort(matches, function(a, b) return a.name < b.name end)
    result.search_results = matches
  end
  return result
end

function M.set_spectres(params)
  if type(params) ~= 'table' or not params.groupIndex or not params.gemIndex then
    return nil, 'PoB2 selects spectres per gem: groupIndex and gemIndex are required; a global raised-spectre list has no calc counterpart'
  end
  if type(params.spectres) ~= 'table' or #params.spectres ~= 1 or (params.mode and params.mode ~= 'replace') then
    return nil, 'select exactly one spectre per PoB2 gem; use separate groups for different spectres'
  end
  local group, tab = skill_group(params,true)
  if not group then return nil,tab end
  local gem = group.gemList[integer(params.gemIndex,1)]
  if not gem then return nil,'gem not found' end
  local lib, err = spectre_library()
  if not lib then return nil,err end
  local id, resolveErr = resolve_spectre(lib,tostring(params.spectres[1]))
  if not id then return nil,resolveErr end
  local effect = gem.grantedEffect or gem.gemData and gem.gemData.grantedEffect
  -- CalcActiveSkill uses build.spectreList as the catalog for Spectre effects;
  -- their static minionList is empty. Selection still lives on each gem instance.
  local usesCatalog = effect and effect.minionList and effect.name:match('^Spectre')
  local allowed = usesCatalog and true or false
  for _,minionId in ipairs(effect and effect.minionList or {}) do if minionId == id then allowed = true end end
  if not allowed then return nil,"spectre is not in this gem's PoB2 minion list" end
  return mutate(tab,function()
    if usesCatalog then
      build.spectreList = build.spectreList or {}
      local present = false
      for _,candidate in ipairs(build.spectreList) do if candidate == id then present = true end end
      if not present then table.insert(build.spectreList,id) end
    end
    gem.skillMinion, gem.skillMinionCalcs = id,id
    gem.skillMinionItemSet, gem.skillMinionItemSetCalcs = nil,nil
    if gem.nameSpec:match('^Spectre:') then gem.nameSpec = 'Spectre: ' .. lib[id].name end
    return {active={{id=id,name=lib[id].name,groupIndex=params.groupIndex,gemIndex=params.gemIndex}}}
  end)
end


-- ============================================================
-- Anointment evaluation
-- ============================================================

function M.evaluate_anoint_candidates(params)
  if not build or not build.itemsTab or not build.calcsTab then return nil, 'build not initialized' end
  local slotName = (params and params.slot) or 'Amulet'
  local focus    = (params and params.focus) or 'both'
  local limit    = tonumber(params and params.limit) or 50


  local activeItemSet = build.itemsTab.activeItemSet
  local slotEntry = build.itemsTab.slots[slotName]
  local item = slotEntry and build.itemsTab.items[slotEntry.selItemId]
  if not item then
    return nil, 'no item equipped in slot: ' .. slotName
  end

  if not (item.canBeAnointed or item.base and item.base.type == 'Amulet') then
    return nil, 'item cannot be anointed in PoB2'
  end
  -- Save state, then point displayItem at the target item
  local savedDisplayItem   = build.itemsTab.displayItem
  local savedAnointSlot    = build.itemsTab.anointEnchantSlot

  -- slotType drives the calc engine replacement slot
  local slotType = slotName

  local calcFunc = build.calcsTab:GetMiscCalculator()
  if not calcFunc then
    build.itemsTab.displayItem     = savedDisplayItem
    build.itemsTab.anointEnchantSlot = savedAnointSlot
    return nil, 'failed to get calc function'
  end

  build.itemsTab.displayItem, build.itemsTab.anointEnchantSlot = item, 1
  -- Base stats without any anoint
  local okBase, baseCalc = pcall(function()
    return calcFunc({ repSlotName = slotType, repItem = build.itemsTab:anointItem(nil) })
  end)
  if not okBase or not baseCalc then
    build.itemsTab.displayItem, build.itemsTab.anointEnchantSlot = savedDisplayItem, savedAnointSlot
    return nil, 'anoint baseline failed: ' .. tostring(baseCalc)
  end
  local baseDPS  = baseCalc and (baseCalc.CombinedDPS or baseCalc.TotalDPS or 0) or 0
  local baseEHP  = baseCalc and (baseCalc.TotalEHP or 0) or 0

  local candidates = {}
  local evaluated  = 0
  local skipped    = 0

  for id, node in pairs(build.spec.nodes or {}) do
    -- Only anointable notables not already allocated
    if node.recipe and #node.recipe >= 1 and (node.type == 'Notable' or node.isNotable) and node.type ~= 'Keystone' and not node.isKeystone
        and not node.ascendancyName and not build.spec.allocNodes[id] then
      local ok, output = pcall(function()
        return calcFunc({ repSlotName = slotType, repItem = build.itemsTab:anointItem(node) })
      end)
      if ok and output then
        local dps      = output.CombinedDPS or output.TotalDPS or 0
        local ehp      = output.TotalEHP or 0
        local dpsDelta = dps - baseDPS
        local ehpDelta = ehp - baseEHP
        local score
        if focus == 'dps' then
          score = baseDPS > 0 and (dpsDelta / baseDPS) or dpsDelta
        elseif focus == 'defence' then
          score = baseEHP > 0 and (ehpDelta / baseEHP) or ehpDelta
        else
          local dpsN = baseDPS > 0 and (dpsDelta / baseDPS) or 0
          local ehpN = baseEHP > 0 and (ehpDelta / baseEHP) or 0
          score = dpsN + 0.5 * ehpN
        end
        table.insert(candidates, {
          nodeId   = id,
          name     = node.dn or node.name or 'Unknown',
          dpsDelta = dpsDelta,
          ehpDelta = ehpDelta,
          score    = score,
          recipe   = node.recipe,
        })
        evaluated = evaluated + 1
      else
        skipped = skipped + 1
      end
    end
  end

  -- Restore state
  build.itemsTab.displayItem     = savedDisplayItem
  build.itemsTab.anointEnchantSlot = savedAnointSlot

  table.sort(candidates, function(a, b) return a.score > b.score end)

  local top = {}
  for i = 1, math.min(limit, #candidates) do top[i] = candidates[i] end

  return {
    candidates = top,
    base       = { CombinedDPS = baseDPS, TotalEHP = baseEHP },
    evaluated  = evaluated,
    skipped    = skipped,
    slot       = slotName,
    baseType   = item.baseName or item.name or slotName,
    focus      = focus,
  }
end

-- Probe the build's sensitivity to individual stat mods WITHOUT mutating it.
-- For each probe mod line, clones the item in a carrier slot, appends the mod,
-- and evaluates through the non-mutating GetMiscCalculator closure (same
-- pattern as evaluate_anoint_candidates: no AddItem, no undo state, no
-- buildFlag — nothing the user sees changes).
-- params: { slot?: string, mods: string[] }
function M.probe_stat_weights(params)
  if not build or not build.itemsTab or not build.calcsTab then return nil, 'build not initialized' end
  local mods = params and params.mods
  if type(mods) ~= 'table' or #mods == 0 then return nil, 'mods list required' end
  if #mods > 40 then return nil, 'too many probe mods (max 40)' end

  -- Pick a carrier slot: probe mods are appended to a clone of this slot's item.
  local activeItemSet = build.itemsTab.activeItemSet
  local function itemIn(name)
    local entry = build.itemsTab.slots[name]
    return entry and build.itemsTab.items[entry.selItemId]
  end
  local slotName = params and params.slot
  local item
  if slotName then
    item = itemIn(slotName)
    if not item then return nil, 'no item equipped in slot: ' .. slotName end
  else
    for _, cand in ipairs({ 'Ring 1', 'Ring 2', 'Amulet', 'Belt', 'Helmet', 'Boots', 'Gloves' }) do
      item = itemIn(cand)
      if item then slotName = cand; break end
    end
    if not item then return nil, 'no equipped item found to carry probe mods; pass slot explicitly' end
  end

  -- repSlotName is matched against the SLOT NAME (CalcSetup.lua:
  -- `slotName == override.repSlotName`) — "Ring 1", not base type "Ring".
  -- (evaluate_anoint_candidates gets away with base.type only because the
  -- Amulet/Belt slot names happen to equal their base types.)
  local repSlot = slotName
  local rawText
  if item.BuildRaw then
    local okRaw, r = pcall(function() return item:BuildRaw() end)
    if okRaw and type(r) == 'string' and #r > 0 then rawText = r end
  end
  rawText = rawText or item.raw
  if type(rawText) ~= 'string' or #rawText == 0 then return nil, 'could not serialize carrier item' end
  local originalModCount = #(item.explicitModLines or {})

  local calcFunc = build.calcsTab:GetMiscCalculator()
  if not calcFunc then return nil, 'failed to get calc function' end

  -- Keep GUI selection stable while the calculator evaluates replacements.
  -- The default misc-calculator call includes Full DPS when the build enables it.
  local savedViewMode = build.viewMode
  build.viewMode = 'CALCULATOR'

  -- Baseline runs the UNCHANGED carrier through the same replacement path, so
  -- clone/normalisation artifacts cancel out of every delta.
  local baseDPS, baseEHP, baseMinionDPS, baseFullDPS = 0, 0, 0, 0
  local okBase, baseErr = pcall(function()
    local baseItem = new('Item', rawText)
    if not baseItem or not baseItem.baseName then error('failed to re-parse carrier item') end
    local out = calcFunc({ repSlotName = repSlot, repItem = baseItem })
    baseDPS = out and (out.CombinedDPS or out.TotalDPS or 0) or 0
    baseEHP = out and (out.TotalEHP or 0) or 0
    baseMinionDPS = out and (out.Minion and (out.Minion.CombinedDPS or out.Minion.TotalDPS) or 0) or 0
    baseFullDPS = out and (out.FullDPS or 0) or 0
  end)
  if not okBase then
    build.viewMode = savedViewMode
    return nil, 'baseline calc failed: ' .. tostring(baseErr)
  end

  local results = {}
  local evaluated, failed = 0, 0
  for _, modLine in ipairs(mods) do
    if type(modLine) == 'string' and #modLine > 0 and #modLine < 200 then
      local ok, res = pcall(function()
        local probeItem = new('Item', rawText .. '\n' .. modLine)
        if not probeItem or not probeItem.baseName then error('probe item parse failed') end
        local out = calcFunc({ repSlotName = repSlot, repItem = probeItem })
        local dps = out and (out.CombinedDPS or out.TotalDPS or 0) or 0
        local ehp = out and (out.TotalEHP or 0) or 0
        local mdps = out and (out.Minion and (out.Minion.CombinedDPS or out.Minion.TotalDPS) or 0) or 0
        local fdps = out and (out.FullDPS or 0) or 0
        -- Distinguish "no effect on this build" from "PoB didn't understand
        -- the mod line": an unrecognized line parses with .extra set.
        local lines = probeItem.explicitModLines or {}
        local last = lines[#lines]
        local recognized = (#lines > originalModCount) and last ~= nil and (last.extra == nil)
        return { dps = dps, ehp = ehp, mdps = mdps, fdps = fdps, recognized = recognized }
      end)
      if ok and res then
        evaluated = evaluated + 1
        table.insert(results, {
          mod            = modLine,
          dpsDelta       = res.dps - baseDPS,
          ehpDelta       = res.ehp - baseEHP,
          minionDpsDelta = res.mdps - baseMinionDPS,
          fullDpsDelta   = res.fdps - baseFullDPS,
          recognized     = res.recognized,
        })
      else
        failed = failed + 1
        table.insert(results, { mod = modLine, error = tostring(res) })
      end
    else
      failed = failed + 1
      table.insert(results, { mod = tostring(modLine), error = 'invalid mod line' })
    end
  end

  build.viewMode = savedViewMode

  return {
    base      = { CombinedDPS = baseDPS, TotalEHP = baseEHP, MinionCombinedDPS = baseMinionDPS, FullDPS = baseFullDPS },
    slot      = slotName,
    carrier   = item.name or item.baseName or slotName,
    results   = results,
    evaluated = evaluated,
    failed    = failed,
  }
end

-- Full DPS per-skill breakdown — rebuilds and reads PoB2's MAIN output.
-- calcs.buildOutput unconditionally computes calcFullDPS and stores the
-- per-skill list on mainOutput.SkillDPS ({name, dps, count, trigger,
-- skillPart, source}); dps is PER-INSTANCE (per single minion), count is the
-- socket group's manually-set "Count" field. Values come only from the engine.
function M.get_full_dps_breakdown()
  if not build or not build.calcsTab then return nil, 'build not initialized' end
  local output, err = M.get_main_output()
  if not output then return nil, err end

  local skills = {}
  for _, s in ipairs(output.SkillDPS or {}) do
    table.insert(skills, {
      name      = s.name,
      dps       = tonumber(s.dps) or 0,
      count     = tonumber(s.count) or 1,
      trigger   = s.trigger,
      skillPart = s.skillPart,
      source    = s.source,
    })
  end

  return {
    skills     = skills,
    fullDPS    = tonumber(output.FullDPS) or 0,
    fullDotDPS = tonumber(output.FullDotDPS) or 0,
    playerDPS  = tonumber(output.CombinedDPS or output.TotalDPS) or 0,
  }
end


-- ============================================================
-- Weighted trade query generation (mirrors PoB's Find Upgrade)
-- ============================================================

function M.generate_weighted_trade_query(params)
  if not build or not build.itemsTab then return nil, 'build not initialized' end
  local slotName = params and params.slot
  if not slotName then return nil, 'slot is required' end

  local slot = build.itemsTab.slots[slotName]
  if not slot then return nil, 'slot not found: ' .. tostring(slotName) end

  local tradeQuery = build.itemsTab.tradeQuery
  if not tradeQuery then return nil, 'tradeQuery not initialized' end

  local weights = tradeQuery.statSortSelectionList
  if not weights or #weights == 0 then
    weights = {{label='Full DPS',stat='FullDPS',weightMult=1}, {label='Effective Hit Pool',stat='TotalEHP',weightMult=0.5}}
  end
  -- Installed PoB2 TradeQueryGenerator uses trade2, runes and Base/Radius jewels.
  -- Do not accept PoE1 influence/scourge/eldritch/synthesis filters as silent no-ops.
  local options = {includeCorrupted=false,includeMirrored=false,includeRunes=false,jewelType='Base',statWeights=weights}
  local allowed = {includeCorrupted=true,includeMirrored=true,includeRunes=true,jewelType=true,
    statWeights=true,maxPrice=true,maxPriceType=true,maxLevel=true,sockets=true,requiredMods=true,account=true,special=true}
  local poe1 = {influence1=true,influence2=true,includeScourge=true,includeEldritch=true,includeSynthesis=true}
  for k,v in pairs(params.options or {}) do
    if poe1[k] then return nil, 'PoE1 trade option has no PoE2 counterpart: ' .. k end
    if not allowed[k] then return nil, 'unknown PoB2 trade option: ' .. tostring(k) end
    options[k] = v
  end
  if options.jewelType ~= 'Base' and options.jewelType ~= 'Radius' then return nil,'jewelType must be Base or Radius' end

  -- Instantiate a generator against the build's tradeQuery object
  local ok_gen, gen = pcall(function() return new("TradeQueryGenerator", tradeQuery) end)
  if not ok_gen or not gen then
    return nil, 'failed to create TradeQueryGenerator: ' .. tostring(gen)
  end

  -- Capture result via callback
  local capturedJson, capturedErr
  gen.requesterCallback = function(_, queryJson, errMsg)
    capturedJson = queryJson
    capturedErr  = errMsg
  end
  gen.requesterContext = nil

  -- Launch the query (creates coroutine, opens no-op GUI popup in headless)
  local ok_start, startErr = pcall(gen.StartQuery, gen, slot, options)
  if not ok_start then
    return nil, 'StartQuery failed: ' .. tostring(startErr)
  end

  -- Drive the coroutine to completion (replaces the OnFrame loop)
  if gen.calcContext and gen.calcContext.co then
    local maxIter = 200000
    local iter = 0
    while coroutine.status(gen.calcContext.co) ~= 'dead' and iter < maxIter do
      local ok_resume, resumeErr = coroutine.resume(gen.calcContext.co, gen)
      if not ok_resume then
        return nil, 'coroutine error: ' .. tostring(resumeErr)
      end
      iter = iter + 1
    end
    if coroutine.status(gen.calcContext.co) ~= 'dead' then
      return nil, 'PoB2 trade query iteration limit reached; no partial query returned'
    end
    -- FinishQuery builds the trade2 JSON and fires the callback
    local ok_finish, finishErr = pcall(gen.FinishQuery, gen)
    if not ok_finish then
      return nil, 'FinishQuery failed: ' .. tostring(finishErr)
    end
  end

  if not capturedJson then
    return nil, capturedErr or 'no query generated'
  end

  return { query = capturedJson, warning = capturedErr }
end

function M.get_notes()
  if not build or not build.notesTab then return nil, 'build/notesTab not initialized' end
  return { notes = build.notesTab.controls.edit.buf or '' }
end

function M.set_notes(params)
  if not build or not build.notesTab then return nil, 'build/notesTab not initialized' end
  local text = (type(params) == 'table' and type(params.text) == 'string') and params.text or ''
  if build.notesTab.controls.edit.SetText then
    build.notesTab.controls.edit:SetText(text)
  else
    build.notesTab.controls.edit.buf = text
  end
  build.notesTab.modFlag = true
  build.modFlag = true
  return { ok = true }
end

-- ============================================================
-- Node Power
-- ============================================================

function M.get_node_power(params)
  if not build or not build.spec or not build.calcsTab then
    return nil, 'build not initialized'
  end
  params = params or {}
  local mode     = params.mode     or 'combined'
  local filter   = params.filter   or 'unallocated'
  local maxDepth = params.max_depth   -- nil = no depth limit
  local limit    = params.limit    or 20
  local doRecalc = params.recalculate == true

  if doRecalc then
    build.calcsTab.powerBuildFlag = true
    if not _G.main then
      -- Headless: no frame loop, so pump the coroutine to completion.
      ConPrintf('[PoB API] Node power recalculation started (headless)')
      local safety = 0
      repeat
        build.calcsTab:BuildPower()
        safety = safety + 1
      until (not build.calcsTab.powerBuilder) or safety > 5000
      ConPrintf('[PoB API] Node power recalculation complete')
    else
      -- TCP: kick the coroutine into existence with a small inline pump so
      -- partial data is available immediately; frame loop finishes the rest.
      -- (TcpServer.lua detects the start/complete transitions and logs them.)
      for _ = 1, 10 do
        build.calcsTab:BuildPower()
        if not build.calcsTab.powerBuilder then break end
      end
    end
  end

  local spec    = build.spec
  local powerMax = build.calcsTab.powerMax or {}

  -- BFS from allocated nodes to compute hop-distance for each reachable node.
  local nodeDistance = nil
  if maxDepth then
    nodeDistance = {}
    local queue = {}
    local qOut, qIn = 1, 1

    for _, node in pairs(spec.allocNodes or {}) do
      nodeDistance[node.id] = 0
      for _, linked in ipairs(node.linked or {}) do
        if not nodeDistance[linked.id] then
          nodeDistance[linked.id] = 1
          queue[qIn] = { node = linked, dist = 1 }
          qIn = qIn + 1
        end
      end
    end

    while qOut < qIn do
      local entry = queue[qOut]
      qOut = qOut + 1
      local n    = entry.node
      local dist = entry.dist
      if dist < maxDepth then
        for _, linked in ipairs(n.linked or {}) do
          if not nodeDistance[linked.id]
            and n.type ~= 'Mastery'
            and linked.type ~= 'ClassStart'
            and linked.type ~= 'AscendClassStart'
          then
            nodeDistance[linked.id] = dist + 1
            queue[qIn] = { node = linked, dist = dist + 1 }
            qIn = qIn + 1
          end
        end
      end
    end
  end

  -- Collect qualifying nodes.
  local results = {}
  for nodeId, node in pairs(spec.nodes or {}) do
    local isAlloc = spec.allocNodes[nodeId] ~= nil

    -- Allocation filter
    if filter == 'unallocated' and isAlloc then
    elseif filter == 'allocated' and not isAlloc then
    else
      -- Depth filter
      local depthOk = true
      local depth = nil
      if maxDepth then
        depth = nodeDistance and nodeDistance[nodeId]
        if not depth or depth > maxDepth then depthOk = false end
      end

      if depthOk then
        local power = node.power
        if power then
          local off  = power.offence or 0
          local def  = power.defence or 0
          if off ~= 0 or def ~= 0 then
            table.insert(results, {
              id       = nodeId,
              name     = node.name or '?',
              type     = node.type or 'Normal',
              allocated = isAlloc,
              offence  = off,
              defence  = def,
              combined = off + def,
              depth    = depth,
            })
          end
        end
      end
    end
  end

  -- Sort
  table.sort(results, function(a, b)
    if mode == 'offence' then return a.offence > b.offence
    elseif mode == 'defence' then return a.defence > b.defence
    else return a.combined > b.combined
    end
  end)

  -- Apply limit
  local out = {}
  for i = 1, math.min(limit, #results) do
    out[i] = results[i]
  end

  local recalcPending = build.calcsTab.powerBuildFlag == true
                     or build.calcsTab.powerBuilder ~= nil

  return {
    nodes         = out,
    total         = #results,
    has_data      = #results > 0,
    recalc_pending = recalcPending,
    mode          = mode,
    filter        = filter,
    power_max     = {
      offence = powerMax.offence or 0,
      defence = powerMax.defence or 0,
    },
  }
end

-- Get static gem data straight from PoB's own game data (no build required).
-- Reuses PoB's renderers (calcLib.buildSkillInstanceStats + data.describeStats), so the
-- output matches the in-game gem tooltip exactly. Works with no character loaded.
-- params: { gemName: string, levels?: number[] }
-- Returns: { name, baseTypeName, tags, support, castTime, description, variants[],
--            maxLevel, perLevel:[{level, levelRequirement, reqStr, reqDex, reqInt,
--            critChance, damageEffectiveness, cost, statLines[]}], qualityLines[] }
function M.get_gem_detail(params)
  if type(params) ~= 'table' then return nil, 'invalid params' end
  local gem, err = resolve_gem(params.gemId or params.gemName)
  if not gem then return nil, err end
  local gd = build and build.data or data
  local effect = gem.grantedEffect
  if not effect then return nil, 'gem has no granted effect' end
  if not effect.statSets then return nil, 'PoB2 gem statSets unavailable' end
  local maxLevel, levels = 0, {}
  for level in pairs(effect.levels) do if type(level)=='number' then maxLevel=math.max(maxLevel,level) end end
  if params.levels then
    if type(params.levels) ~= 'table' or #params.levels == 0 then return nil,'levels must be a nonempty array' end
    for _,value in ipairs(params.levels) do
      local n = integer(value,1)
      if not n or not effect.levels[n] then return nil, 'gem level not present in PoB2 data: '..tostring(value) end
      table.insert(levels,n)
    end
  else
    for _,n in ipairs({1,10,maxLevel}) do
      if effect.levels[n] and levels[#levels] ~= n then table.insert(levels,n) end
    end
    table.sort(levels)
  end
  local perLevel = {}
  for _,level in ipairs(levels) do
    local levelData = effect.levels[level]
    local reqLevel = levelData.levelRequirement or 1
    local instance = {level=level,quality=0,gemData=gem,actorLevel=reqLevel}
    local rendered, allLines = {}, {}
    for index,statSet in ipairs(effect.statSets) do
      local stats = calcLib.buildSkillInstanceStats(instance,effect,statSet)
      local lines = gd.describeStats and gd.describeStats(stats,statSet.statDescriptionScope) or {}
      local sl = statSet.levels[level] or statSet.levels[1] or {}
      table.insert(rendered,{index=index,label=statSet.label,statLines=lines,
        critChance=sl.critChance,damageEffectiveness=sl.damageEffectiveness,baseMultiplier=sl.baseMultiplier})
      for _,line in ipairs(lines) do table.insert(allLines,line) end
    end
    local costs = {}
    for _,res in ipairs(gd.costs or {}) do
      local v = levelData.cost and levelData.cost[res.Resource]
      if v then table.insert(costs,(res.ResourceString:gsub('{0}',string.format('%g',math.floor(v/res.Divisor*100+0.5)/100)))) end
    end
    local first = rendered[1] or {}
    table.insert(perLevel,{level=level,levelRequirement=reqLevel,
      reqStr=calcLib.getGemStatRequirement(reqLevel,gem.reqStr or 0,effect.support),
      reqDex=calcLib.getGemStatRequirement(reqLevel,gem.reqDex or 0,effect.support),
      reqInt=calcLib.getGemStatRequirement(reqLevel,gem.reqInt or 0,effect.support),
      critChance=first.critChance or levelData.critChance,
      damageEffectiveness=first.damageEffectiveness and first.damageEffectiveness*100,
      cost=#costs>0 and table.concat(costs,', ') or nil,statLines=allLines,statSets=rendered})
  end
  -- GemTooltip selects each quality stat's own (zero-based) stat-set index.
  local function qualityLines(qualityStats)
    local lines = {}
    for _,stat in ipairs(qualityStats or {}) do
      local setIndex = stat[3] and stat[3][1] or 0
      local statSet = effect.statSets[setIndex+1] or effect.statSets[1]
      if statSet and gd.describeStats then
        local descriptions = gd.describeStats({[stat[1]]=math.modf(stat[2]*20)},statSet.statDescriptionScope,true)
        for _,line in ipairs(descriptions) do table.insert(lines,line) end
      end
    end
    return lines
  end
  local variants = {}
  for _,v in pairs(gd.gemsByGameId and gd.gemsByGameId[gem.gameId] or {}) do
    if v.name then table.insert(variants,v.name) end
  end
  table.sort(variants)
  return {name=gem.name,gemId=gem.id,baseTypeName=gem.baseTypeName,tags=gem.tagString,
    support=effect.support == true,castTime=effect.castTime,description=effect.description,
    variants=variants,maxLevel=maxLevel,naturalMaxLevel=gem.naturalMaxLevel,perLevel=perLevel,
    qualityLines=qualityLines(effect.qualityStats),altQualityLines=qualityLines(effect.altQualityStats)}
end

return M
