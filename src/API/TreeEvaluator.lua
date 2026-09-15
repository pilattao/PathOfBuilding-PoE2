-- Native PoE2 passive scenarios. No live spec, inventory, selection or undo edits.
local M, busy = {}, false
local xmlSemantics
local function sameNativeXml(actual,expected)
  if not xmlSemantics then
    local source=debug and debug.getinfo and debug.getinfo(1,'S').source or ''
    xmlSemantics=source:sub(1,1)=='@'
      and dofile(source:sub(2):gsub('[^/\\]+$','')..'XmlSemantics.lua')
      or require('API.XmlSemantics')
  end
  -- Shared with ItemEvaluator: compare the entire native document, preserving
  -- literal attribute whitespace, sequences, repeated keys and unknown fields.
  return xmlSemantics.equivalent(actual,expected)
end
-- Bound calculation work, not semantics. Restoration always finishes after a
-- timeout; the caller must allow transport headroom for that cleanup.
local TIME_BUDGET_SECONDS = 15
local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function integer(value, minimum, maximum)
  local n=(type(value)=='number' or type(value)=='string') and tonumber(value)
  if not finite(n) or n~=math.floor(n) or n<(minimum or 0) or maximum and n>maximum then return nil end
  return n
end
local function copy(value, seen)
  if type(value)~='table' then return value end
  seen=seen or {};if seen[value] then return seen[value] end
  local out={};seen[value]=out
  for k,v in pairs(value) do out[copy(k,seen)]=copy(v,seen) end
  local meta=getmetatable(value)
  if meta~=nil and type(meta)~='table' then error('Cannot isolate protected native table') end
  return setmetatable(out,copy(meta,seen))
end
-- Table identity matters: nodes and granted effects are used as map keys, and
-- undo/redo entries can alias the catalogs. Restore values in their original tables.
local function audit(root)
  local records,seen={},{}
  local function visit(t)
    if type(t)~='table' or seen[t] then return end;seen[t]=true
    local record={ref=t,values={},meta=getmetatable(t)};records[#records+1]=record
    visit(record.meta)
    for k,v in pairs(t) do record.values[k]=v;visit(k);visit(v) end
  end
  visit(root);return records
end
local function restore(records)
  for _,r in ipairs(records) do
    for k in pairs(r.ref) do if r.values[k]==nil then rawset(r.ref,k,nil) end end
    for k,v in pairs(r.values) do if rawget(r.ref,k)~=v then rawset(r.ref,k,v) end end
    if getmetatable(r.ref)~=r.meta then setmetatable(r.ref,r.meta) end
  end
  for _,r in ipairs(records) do
    if getmetatable(r.ref)~=r.meta then error('Tree evaluator metatable restoration failed') end
    for k,v in pairs(r.values) do if rawget(r.ref,k)~=v then error('Tree evaluator restoration failed: '..tostring(k)) end end
    for k in pairs(r.ref) do if r.values[k]==nil then error('Tree evaluator restoration left an unexpected key') end end
  end
end
local function detached(b, originalData, originalMain, originalLaunch)
  local shadowMain,shadowLaunch={},{}
  local seen={[originalMain]=shadowMain}
  if originalLaunch then seen[originalLaunch]=shadowLaunch end
  for k,v in pairs(originalMain) do shadowMain[k]=v end
  for k,v in pairs(originalLaunch or {}) do shadowLaunch[k]=v end
  shadowMain.tree=copy(originalMain.tree,seen)
  local shadowData=copy(originalData,seen)
  local trial=copy(b,seen)
  shadowMain.modes={BUILD=trial}
  local function block() error('UI or persistence callback is forbidden during tree calculation') end
  for _,name in ipairs({'SetMode','CallMode','OnFrame','OpenPopup','ClosePopup','SetWindowTitleSubtext','SaveSettings','SaveModCache','ChangeUserPath'}) do shadowMain[name]=block end
  for _,name in ipairs({'DownloadPage','ShowErrMsg','OpenURL','Exit','Restart'}) do shadowLaunch[name]=block end
  local seenControls={}
  local function guard(control)
    if type(control)~='table' or seenControls[control] then return end;seenControls[control]=true
    for k,v in pairs(control) do
      if type(v)=='function' then control[k]=block
      elseif k=='controls' then for _,child in pairs(v) do guard(child) end end
    end
  end
  for _,tab in ipairs({trial,trial.itemsTab,trial.skillsTab,trial.calcsTab,trial.configTab,trial.treeTab}) do
    for _,control in pairs(tab.controls or {}) do guard(control) end
  end
  for _,control in pairs(trial.itemsTab.slots or {}) do guard(control) end
  return trial,shadowData,shadowMain,shadowLaunch
end
local function freshCache(original)
  local cache={}
  for k,v in pairs(original or {}) do if k~='cachedData' then cache[k]=copy(v) end end
  cache.cachedData={MAIN={},CALCS={},CALCULATOR={}}
  return cache
end
local allowed={expectedBuildName=true,expectedXml=true,weaponSet=true,weaponSets=true,attributeOverrides=true,addNodes=true,removeNodes=true,masteryEffects=true,useFullDPS=true}
local function request(b,p)
  if type(p)~='table' then error('calc_with params must be an object') end
  for key in pairs(p) do if not allowed[key] then error('Unknown calc_with parameter: '..tostring(key)) end end
  if p.expectedBuildName~=nil and (type(p.expectedBuildName)~='string' or p.expectedBuildName=='' or p.expectedBuildName~=b.buildName) then error('Expected build name does not match the selected build') end
  if p.expectedXml~=nil and (type(p.expectedXml)~='string' or #p.expectedXml==0 or #p.expectedXml>20*1024*1024) then error('expectedXml must be a nonempty string of at most 20 MB') end
  if p.weaponSet~=nil and (type(p.weaponSet)~='number' or not integer(p.weaponSet,1,2)) then error('weaponSet must be 1 or 2') end
  if p.useFullDPS~=nil and type(p.useFullDPS)~='boolean' then error('useFullDPS must be a boolean') end
  local result={expectedXml=p.expectedXml,weaponSet=p.weaponSet,useFullDPS=p.useFullDPS==true,addNodes={},removeNodes={},weaponSets={},attributeOverrides={},masteryEffects={}}
  local function nodeId(value)
    local id=integer(value,1)
    if not id or not b.spec.nodes[id] then error('Passive node not found: '..tostring(value)) end
    return id
  end
  for _,name in ipairs({'addNodes','removeNodes'}) do
    local values=p[name]
    if values~=nil then
      if type(values)~='table' then error(name..' must be a dense array') end
      for key in pairs(values) do if type(key)~='number' or not integer(key,1,#values) then error(name..' must be a dense array') end end
      for _,value in ipairs(values) do
        local id=nodeId(value)
        if result[name][id] then error('Duplicate node in '..name) end
        result[name][id]=true
      end
    end
  end
  for id in pairs(result.addNodes) do if result.removeNodes[id] then error('Node appears in both addNodes and removeNodes') end end
  for _,name in ipairs({'weaponSets','attributeOverrides','masteryEffects'}) do
    if p[name]~=nil then
      if type(p[name])~='table' then error(name..' must be a map') end
      for key,value in pairs(p[name]) do
        local id=nodeId(key)
        if result[name][id]~=nil then error('Duplicate node alias in '..name) end
        if name=='weaponSets' then
          if type(value)~='number' or not integer(value,0,2) then error('Weapon allocation mode must be 0, 1 or 2') end
        elseif name=='attributeOverrides' then
          if value~='str' and value~='dex' and value~='int' then error('Attribute choice must be str, dex or int') end
          if not b.spec.nodes[id].isAttribute then error('Attribute override targets a non-attribute node: '..id) end
        else
          if not integer(value,1,65535) or b.spec.nodes[id].type~='Mastery' then error('Invalid native mastery selection: '..id) end
          local effect=b.spec.tree.masteryEffects and b.spec.tree.masteryEffects[tonumber(value)]
          local offered=false
          for _,option in ipairs(b.spec.nodes[id].masteryEffects or {}) do if option.effect==tonumber(value) then offered=true end end
          if not effect or not offered then error('Mastery effect is unavailable for this native node') end
          value=tonumber(value)
        end
        result[name][id]=value
      end
    end
  end
  return result
end
local function modeAllowed(node,mode)
  if not integer(mode,0,2) then error('Invalid native allocation mode: '..tostring(node.id)) end
  if mode~=0 and (node.type=='ClassStart' or node.type=='AscendClassStart' or node.type=='Keystone' or node.type=='Socket' or node.containJewelSocket or node.ascendancyName or node.isFreeAllocate~=nil) then
    error('This node must use shared points, not a weapon allocation mode: '..node.id)
  end
end
local attributeNames={str='Strength',dex='Dexterity',int='Intelligence'}
local function apply(trial,p)
  local spec=trial.spec
  for id in pairs(p.removeNodes) do
    local node=spec.nodes[id]
    if node.type=='ClassStart' or node.type=='AscendClassStart' or node.isGrantedPassive then error('Cannot remove a class start or item-granted passive') end
    node.alloc=false;node.allocMode=0;spec.allocNodes[id]=nil;spec.masterySelections[id]=nil;spec.hashOverrides[id]=nil
  end
  for id in pairs(p.addNodes) do
    local node=spec.nodes[id]
    if not spec.allocNodes[id] then
      if node.type=='ClassStart' or node.type=='AscendClassStart' or node.isGrantedPassive then error('Cannot add a class start or item-granted passive') end
      if node.ascendancyName and node.ascendancyName~=spec.curAscendClassName and node.ascendancyName~=spec.curSecondaryAscendClassName then error('Node belongs to a different ascendancy') end
      if node.isAttribute and not p.attributeOverrides[id] and not spec.hashOverrides[id] then error('An added attribute node requires an explicit attribute choice: '..id) end
      node.alloc=true;node.allocMode=p.weaponSets[id] or 0;spec.allocNodes[id]=node
    end
  end
  for id,mode in pairs(p.weaponSets) do
    local node=spec.allocNodes[id]
    if not node then error('Weapon assignment targets an unallocated node: '..id) end
    if node.isGrantedPassive then error('Cannot change an item-granted passive allocation') end
    modeAllowed(node,mode);node.allocMode=mode
  end
  for id,choice in pairs(p.attributeOverrides) do
    if not spec.allocNodes[id] then error('Attribute choice targets an unallocated node: '..id) end
    local options=spec.tree.nodes[id] and spec.tree.nodes[id].options
    local index
    for i,option in ipairs(options or {}) do if (option.dn or option.name)==attributeNames[choice] then
      if index then error('Ambiguous native attribute option') end;index=i
    end end
    if not index then error('Native attribute option unavailable: '..id) end
    spec:SwitchAttributeNode(id,index)
  end
  for id,effect in pairs(p.masteryEffects) do
    if not spec.allocNodes[id] then error('Mastery must be allocated or included in addNodes') end
    spec.masterySelections[id]=effect
  end
  local intended={}
  for id,node in pairs(spec.allocNodes) do intended[id]=node.allocMode or 0;modeAllowed(node,node.allocMode or 0) end
  spec:BuildAllDependsAndPaths()
  for id,mode in pairs(intended) do
    local node=spec.allocNodes[id]
    if not node then error('Disconnected or invalid passive proposal; native path building removed node '..id) end
    if (node.allocMode or 0)~=mode then error('Native path building changed a requested weapon allocation') end
  end
  for id in pairs(spec.allocNodes) do if intended[id]==nil then error('Native path building added an unrequested passive: '..id) end end
end
local function numeric(output)
  local result={}
  for key,value in pairs(output or {}) do
    if finite(value) then result[key]=value
    elseif key=='Minion' and type(value)=='table' then
      for name,n in pairs(value) do if finite(n) then result['Minion'..name]=n end end
    end
  end
  return result
end
local function calculate(trial,weapon,full)
  local calcs=trial.calcsTab.calcs
  -- Stock PoB2 reads this item-set flag and has no env/override.weaponSet ABI.
  -- This is a detached table; the live selection is never switched.
  if weapon then trial.itemsTab.activeItemSet.useSecondWeaponSet=weapon==2 end
  local override={weaponSet=weapon}
  -- MAIN reconciles passive-granted skills on the detached graph.
  local env,playerDB,enemyDB,minionDB=calcs.initEnv(trial,'MAIN',override)
  env.override=override;calcs.perform(env)
  trial.calcsTab.mainEnv=env;trial.calcsTab.mainOutput=env.player.output
  -- Acknowledge what the native engine actually selected, not the input flag.
  -- Both stock and newer source engines emit exactly one of these conditions.
  local one=env.modDB:Flag(nil,'Condition:WeaponSet1') and true or false
  local two=env.modDB:Flag(nil,'Condition:WeaponSet2') and true or false
  if one==two then error('Native weapon-set acknowledgement is missing or ambiguous') end
  local observedWeapon=one and 1 or 2
  if env.weaponSet~=nil and env.weaponSet~=observedWeapon then error('Native weapon-set metadata disagrees with calculated conditions') end
  if weapon and observedWeapon~=weapon then error('Native calculation did not honor the requested weapon set') end
  local out=numeric(env.player.output)
  out.ExtraPoints=env.modDB:Sum('BASE',nil,'ExtraPoints')
  out.PassivePointsToWeaponSetPoints=env.modDB:Sum('BASE',nil,'PassivePointsToWeaponSetPoints')
  out.CharmLimit=math.min(env.modDB:Override(nil,'CharmLimit') or env.modDB:Sum('BASE',nil,'CharmLimit'),3)
  if full then
    local dps=calcs.calcFullDPS(trial,'CALCULATOR',override,{cachedPlayerDB=playerDB,cachedEnemyDB=enemyDB,cachedMinionDB=minionDB,env=nil})
    out.FullDPS=dps.combinedDPS;out.FullDotDPS=dps.TotalDotDPS
  end
  out.calculationContext={weaponSet=observedWeapon,treeVersion=trial.spec.treeVersion}
  return out
end
local function budget(trial,outputs)
  local used,asc,secondary,_,one,two=trial.spec:CountAllocNodes()
  local level=integer(trial.characterLevel,1,100)
  local quests=integer(trial.maxWeaponSets,0)
  if not level or not quests then error('Native passive budget metadata unavailable') end
  if asc>8 or secondary>8 then error('Native ascendancy point budget exceeded') end
  -- Native PoB's ceiling includes all quest rewards; it cannot establish which
  -- rewards the game character has actually earned. Both weapon contexts count.
  for weapon,out in ipairs(outputs) do
    local extra=integer(out.ExtraPoints,0)
    local converted=integer(out.PassivePointsToWeaponSetPoints,0)
    if not extra or not converted then error('Native extra/converted point budget is unavailable') end
    local points=used-(weapon==1 and two or one)
    if points>level-1+quests+extra then error('Passive point budget exceeded in weapon set '..weapon) end
    if (weapon==1 and one or two)>quests+converted then error('Weapon set '..weapon..' point budget exceeded') end
  end
end
function M.evaluate(b,params)
  if busy then return nil,'tree evaluator is busy' end
  if not b or not b.spec or not b.spec.tree or not b.itemsTab or not b.skillsTab or not b.calcsTab or not b.calcsTab.calcs or type(main)~='table' or type(data)~='table' then
    return nil,'Ready native PoB2 build and calculator required'
  end
  if type(b.spec.treeVersion)~='string' or not b.spec.treeVersion:match('^0_%d+$') then return nil,'PoE2 tree version required' end
  local valid,p=pcall(request,b,params==nil and {} or params)
  if not valid then return nil,tostring(p) end
  if not debug or not debug.gethook or not debug.sethook then return nil,'Native tree deadline hook unavailable' end
  local originalHook,originalMask,originalCount=debug.gethook()
  if originalHook~=nil and type(originalHook)~='function' then return nil,'Cannot preserve an external native debug hook' end
  busy=true
  local originalBuild,originalData,originalMain,originalLaunch=build,data,main,launch
  local originalCache,originalAssignments=GlobalCache,GlobalGemAssignments
  local records
  local clock=os.clock
  local started=clock()
  local wallClock=type(GetTime)=='function' and GetTime or function() return 0 end
  local wallStarted=wallClock()
  local running=true
  local function checkTime()
    if not running then return end
    local wallNow=wallClock()
    if clock()-started>TIME_BUDGET_SECONDS or finite(wallStarted) and finite(wallNow) and (wallNow-wallStarted)/1000>TIME_BUDGET_SECONDS then
      running=false;debug.sethook()
      error('Tree evaluation exceeded its 15-second time budget; no partial result returned',0)
    end
  end
  local ok,out,baseline=xpcall(function()
    debug.sethook(checkTime,'',200000)
    records=audit({build=b,data=originalData,main=originalMain,launch=originalLaunch,cache=originalCache,assignments=originalAssignments,parser=modLib.parseModCache})
    checkTime()
    local trial,shadowData,shadowMain,shadowLaunch=detached(b,originalData,originalMain,originalLaunch)
    checkTime()
    build,data,main,launch=trial,shadowData,shadowMain,shadowLaunch
    -- SaveDB reparses items and synchronizes loadouts. Run the real serializer
    -- only on the detached graph; a mismatch never falls back to echoed input.
    if p.expectedXml~=nil and not sameNativeXml(trial:SaveDB('api-tree-binding'),p.expectedXml) then error('Selected build XML changed; retry the tree read') end
    checkTime()
    local function resetCaches() GlobalCache=freshCache(originalCache);GlobalGemAssignments={} end
    resetCaches()
    local before=calculate(trial,p.weaponSet,p.useFullDPS)
    checkTime()
    apply(trial,p)
    checkTime()
    local results={}
    for weapon=1,2 do
      resetCaches()
      results[weapon]=calculate(trial,weapon,p.useFullDPS and weapon==(p.weaponSet or before.calculationContext.weaponSet))
      checkTime()
    end
    budget(trial,results)
    running=false;debug.sethook()
    return results[p.weaponSet or before.calculationContext.weaponSet],before
  end,function(err) running=false;debug.sethook();return tostring(err) end)
  build,data,main,launch=originalBuild,originalData,originalMain,originalLaunch
  GlobalCache,GlobalGemAssignments=originalCache,originalAssignments
  local restored,restoreError=pcall(function()
    if records then restore(records) end
    -- Do not retain dead catalog/spec copies across a long sequence of calls.
    -- Results contain only numbers and context scalars, so no graph escapes.
    records=nil
    collectgarbage('collect')
  end)
  debug.sethook(originalHook,originalMask,originalCount)
  busy=false
  if not restored then return nil,'Tree evaluator restoration failed: '..tostring(restoreError) end
  if not ok then return nil,tostring(out) end
  return out,baseline
end
return M
