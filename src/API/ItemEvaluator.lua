-- Native equipment comparisons. All calculator writes target detached build graphs.
-- No item is added to the live inventory, no set is switched, and no undo entry is made.
local M, busy = {}, false
local moduleSource=debug and debug.getinfo and debug.getinfo(1,'S').source or ''
local XmlSemantics=moduleSource:sub(1,1)=='@'
  and dofile(moduleSource:sub(2):gsub('[^/\\]+$','')..'XmlSemantics.lua')
  or require('API.XmlSemantics')
local function number(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function copy(value, seen)
  if type(value)~='table' then return value end
  seen=seen or {}; if seen[value] then return seen[value] end
  local out={}; seen[value]=out
  for k,v in pairs(value) do out[copy(k,seen)]=copy(v,seen) end
  return setmetatable(out,getmetatable(value))
end
local function equal(a,b,seen)
  if a==b then return true end
  if type(a)~='table' or type(b)~='table' then return false end
  seen=seen or {}; if seen[a]==b then return true end; seen[a]=b
  for k,v in pairs(a) do if not equal(v,b[k],seen) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function array(t,lo,hi,name)
  if type(t)~='table' or #t<lo or #t>hi then error(name..' has invalid size') end
  for k in pairs(t) do if not number(k) or k~=math.floor(k) or k<1 or k>#t then error(name..' must be a dense array') end end
end
local function identity(s) return type(s)=='string' and s:gsub('\\','/'):gsub('%.xml$',''):lower() end
local function outputs(out)
  local result={}
  for key,value in pairs(out or {}) do
    if number(value) then result[key]=value
    elseif key=='Minion' and type(value)=='table' then
      for name,n in pairs(value) do if number(n) then result['Minion'..name]=n end end
    end
  end
  return result
end
local function selection(b)
  local result={itemSetId=b.itemsTab.activeItemSetId,skillSetId=b.skillsTab.activeSkillSetId,
    configSetId=b.configTab.activeConfigSetId,treeSpecId=b.treeTab and b.treeTab.activeSpec,
    mainSocketGroup=b.mainSocketGroup,viewMode=b.viewMode,activeLoadout=b.activeLoadout,
    level=b.characterLevel,autoLevel=b.characterLevelAutoMode,modFlag=b.modFlag,buildFlag=b.buildFlag,
    weaponSet=b.itemsTab.activeItemSet.useSecondWeaponSet and 2 or 1,
    slots={},calcsInput=copy(b.calcsTab.input),configInput=copy(b.configTab.input)}
  for name,slot in pairs(b.itemsTab.slots) do
    result.slots[name]={itemId=slot.selItemId,active=slot.controls and slot.controls.activate and slot.controls.activate.state}
  end
  return result
end
local function history(b)
  local result={}
  for _,key in ipairs({'itemsTab','skillsTab','treeTab','configTab','calcsTab'}) do
    local tab=b[key]; if tab then result[key]={undo=tab.undo,redo=tab.redo,modFlag=tab.modFlag} end
  end
  return result
end
-- Keep original table keys/references in an audit ledger. Deep-copy equality is
-- incorrect for native maps keyed by granted-effect or class objects.
local function audit(root)
  local ledger,seen={},{}
  local function visit(t,path)
    if type(t)~='table' or seen[t] then return end;seen[t]=true
    local values={};ledger[#ledger+1]={ref=t,values=values,meta=getmetatable(t),path=path}
    for k,v in pairs(t) do values[k]=v;visit(k,path..'.<key>');visit(v,(path..'.'..tostring(k)):sub(1,400)) end
  end
  visit(root,'root');return ledger
end
local function auditUnchanged(ledger)
  for _,record in ipairs(ledger) do
    if getmetatable(record.ref)~=record.meta then return false,record.path..' metatable' end
    for k,v in pairs(record.values) do
      local current=rawget(record.ref,k)
      -- NaN is unequal to itself; an unchanged cached undefined number is not a mutation.
      local sameNaN=type(v)=='number' and type(current)=='number' and v~=v and current~=current
      if current~=v and not sameNaN then return false,record.path..'.'..tostring(k)..' ('..type(v)..' to '..type(current)..')' end
    end
    for k in pairs(record.ref) do if record.values[k]==nil then return false,record.path..'.'..tostring(k)..' added' end end
  end
  return true
end
-- MAIN reconciliation can change public granted-effect costs and passive nodes.
-- Copy catalogs and trees in the SAME graph so gemForSkill's table keys and all
-- Item/ModDB references point into the detached catalog, never the live one.
local function detached(b,originalData,originalMain,originalLaunch)
  local shadowMain,shadowLaunch={},{};local seen={[originalMain]=shadowMain}
  if originalLaunch then
    seen[originalLaunch]=shadowLaunch
    for key,value in pairs(originalLaunch) do shadowLaunch[key]=value end
  end
  for k,v in pairs(originalMain) do shadowMain[k]=v end
  shadowMain.tree=copy(originalMain.tree,seen)
  local shadowData=copy(originalData,seen)
  local trial=copy(b,seen)
  local function block() error('UI callback is forbidden during detached item calculation') end
  for _,name in ipairs({'SetMode','CallMode','OnFrame','OpenPopup','ClosePopup','SetWindowTitleSubtext','SaveSettings','SaveModCache','ChangeUserPath'}) do shadowMain[name]=block end
  for _,name in ipairs({'ShowErrMsg','DownloadPage','RegisterSubScript','ApplyUpdate','CheckForUpdate','OnFrame','OnInit','CanExit'}) do shadowLaunch[name]=block end
  -- Callback fields may close over the original UI object. Calculations consume
  -- control state and native class methods, never these per-instance callbacks.
  local visited={}
  local function guard(control)
    if type(control)~='table' or visited[control] then return end;visited[control]=true
    for key,value in pairs(control) do
      if type(value)=='function' then control[key]=block
      elseif key=='controls' then for _,child in pairs(value) do guard(child) end end
    end
  end
  for _,tab in ipairs({trial,trial.itemsTab,trial.skillsTab,trial.calcsTab,trial.configTab,trial.treeTab}) do
    for _,control in pairs(tab.controls or {}) do guard(control) end
  end
  for _,control in pairs(trial.itemsTab.slots) do guard(control) end
  for _,control in pairs(trial.itemsTab.runeSlots or {}) do guard(control) end
  return trial,shadowData,shadowMain,shadowLaunch
end
local function freshCache(saved)
  local result={}; for key,value in pairs(saved or {}) do if key~='cachedData' then result[key]=copy(value) end end
  result.cachedData={MAIN={},CALCS={},CALCULATOR={}}
  return result
end
-- ModParser's name-only lookup cannot distinguish a staff Lightning Bolt from
-- Choir's inbuilt trigger. Resolve duplicate names against native item context
-- and skill types, retaining the literal item text and the native skill tables.
local function resolveGrants(b,item,slotName)
  local triggers,grants={},{}
  for _,line in ipairs(item.explicitModLines or {}) do
    local name=line.line and line.line:match('^Trigger (.+) Skill on Critical Hit$')
    if name then triggers[name]=line end
  end
  for _,line in ipairs(item.implicitModLines or {}) do
    local level,name=(line.line or ''):match('^Grants Skill: Level (%d+) (.+)$')
    if level then
      local baseGrant=item.base.implicit and item.base.implicit:find(name,1,true)
      local wantsTrigger=triggers[name]~=nil
      if baseGrant or wantsTrigger then
        local matches={}
        for id,effect in pairs(data.skills) do
          local triggered=effect.skillTypes and effect.skillTypes[SkillType.InbuiltTrigger]==true
          if effect.fromItem and (effect.name==name or effect.baseTypeName==name) and triggered==wantsTrigger then matches[#matches+1]=id end
        end
        if #matches~=1 then error('native granted-skill identity is ambiguous for '..name) end
        local id=matches[1];local oldId
        line.modList=copy(line.modList or {})
        for _,mod in ipairs(line.modList) do if mod.name=='ExtraSkill' then
          oldId=mod.value.skillId;mod.value.skillId=id;mod.value.level=tonumber(level)
          if wantsTrigger then
            local chance
            for _,set in ipairs(data.skills[id].statSets or {}) do for _,stat in ipairs(set.constantStats or {}) do
              if stat[1]=='triggered_on_critical_strike_%' then chance=stat[2] end
            end end
            if not number(chance) then error('native critical trigger chance is unavailable for '..name) end
            mod.value.triggered=true;mod.value.triggerChance=chance
            local trigger=triggers[name]
            trigger.extra=nil
            trigger.modList={modLib.createMod('ExtraSkillMod','LIST',{
              mod=modLib.createMod('SkillData','LIST',{key='triggerOnCrit',value=true})
            },{type='SkillId',skillId=id})}
          end
        end end
        if not oldId then error('native grant modifier missing for '..name) end
        grants[#grants+1]={oldId=oldId,id=id}
      end
    end
  end
  if #grants>0 then
    item:BuildModList()
    for _,group in ipairs(b.skillsTab.socketGroupList) do
      if group.slot==slotName and group.source==item.modSource then
        local gem=group.gemList[1]
        for _,grant in ipairs(grants) do if gem and gem.skillId==grant.oldId then
          gem.skillId=grant.id;gem.gemId=nil;gem.gemData=nil;gem.grantedEffect=nil
          for _,key in ipairs({'statSet','statSetCalcs'}) do
            if gem[key] and gem[key][grant.oldId] and not gem[key][grant.id] then gem[key][grant.id]=gem[key][grant.oldId] end
          end
        end end
      end
    end
  end
end
local function resolveLoadout(b)
  for name,slot in pairs(b.itemsTab.slots) do
    local item=b.itemsTab.items[slot.selItemId]
    if item then resolveGrants(b,item,name) end
  end
end
local function parsed(b, replacement, id)
  local slot=b.itemsTab.slots[replacement.slotName]
  if not slot then error('unknown equipment slot: '..tostring(replacement.slotName)) end
  if replacement.remove==true then
    if replacement.text~=nil then error('removal must not include item text') end
    return nil
  end
  if type(replacement.text)~='string' or #replacement.text==0 or #replacement.text>32768 then error('item text required (maximum 32 KB)') end
  -- Both native constructor ABIs delegate to ParseRaw, but stock has no Item
  -- method and the source factory rejects arguments. Use their shared parser.
  local item=new('Item')
  item.id=id
  item:ParseRaw(sanitiseText(replacement.text))
  if not item.base or not item.baseName then error('item base is not recognized by native PoB2') end
  resolveGrants(b,item,replacement.slotName)
  -- Offhand legality depends on the complete replacement set, not the old mainhand.
  if not replacement.slotName:match('^Weapon 2') and not b.itemsTab:IsItemValidForSlot(item,replacement.slotName) then error('item is not valid for slot '..replacement.slotName) end
  for _,name in ipairs({'enchantModLines','implicitModLines','explicitModLines','runeModLines','classRequirementModLines','buffModLines'}) do
    for _,line in ipairs(item[name] or {}) do
      if line.extra and line.extra~='' then error('unparsed native item modifier: '..tostring(line.line)) end
    end
  end
  local expected=replacement.expected or {}
  local actual={baseType=item.baseName,rarity=item.rarity,quality=item.quality,itemLevel=item.itemLevel,
    requiredLevel=item.requirements and item.requirements.level,socketCount=item.itemSocketCount or 0,corrupted=item.corrupted==true}
  for key,wanted in pairs(expected) do
    if key=='weapon' then
      local weapon=item.weaponData and (item.weaponData[slot.slotNum or 1] or item.weaponData[1])
      for stat,n in pairs(wanted) do if not weapon or weapon[stat]~=n then error('native weapon conversion mismatch: '..stat) end end
    elseif wanted~=actual[key] then error('native item conversion mismatch: '..key) end
  end
  for _,name in ipairs(item.runes or {}) do if name~='None' and not data.itemMods.Runes[name] then error('incomplete item conversion: unknown rune '..name) end end
  if item.base.quality and not replacement.text:match('\nQuality:') then error('incomplete item conversion: quality is unknown') end
  return item
end
local function delta(out,baseline)
  local result={}
  for key,value in pairs(out) do if number(baseline[key]) then
    local change=value-baseline[key]
    if number(change) then
      result[key]={absolute=change}
      local percent=baseline[key]~=0 and change/math.abs(baseline[key])*100 or nil
      if number(percent) then result[key].percent=percent end
    end
  end end
  return result
end
-- Public profiles can contain a manual copy of an item-only skill beside its
-- generated group. Native stock leaves that manual level frozen; converting it
-- to a generated group would discard its supports. Project only an exact native
-- skill ID with one equipped owner, into the detached manual gem itself.
local function projectItemSkills(trial)
  local owners={}
  for slotName,slot in pairs(trial.itemsTab.slots) do
    local item=trial.itemsTab.items[slot.selItemId]
    for _,grant in ipairs(item and item.grantedSkills or {}) do
      owners[grant.skillId]=owners[grant.skillId] or {}
      table.insert(owners[grant.skillId],{item=item,grant=grant,slotName=slotName})
    end
  end
  local bindings,claimed={},{}
  for index,group in ipairs(trial.skillsTab.socketGroupList) do
    if not group.source and not group.sourceItem and not group.sourceNode and group.enabled~=false then
      local changed=false
      for gemIndex,gem in ipairs(group.gemList) do
        local effect=data.skills[gem.skillId]
        if effect and effect.fromItem and not effect.support and gem.enabled~=false then
          local matches={}
          for _,owner in ipairs(owners[gem.skillId] or {}) do
            if not group.slot or group.slot==owner.slotName then matches[#matches+1]=owner end
          end
          if #matches~=1 then
            error((#matches==0 and 'unresolved' or 'ambiguous')..' item-granted skill projection: '..gem.skillId..' in group '..index..' has '..#matches..' equipped owners')
          end
          local owner=matches[1]
          local key=owner.slotName..':'..gem.skillId
          if claimed[key] then error('ambiguous item-granted skill projection: multiple manual groups for '..gem.skillId..' from '..owner.slotName) end
          claimed[key]=true
          bindings[#bindings+1]={group=group,gem=gem,gemIndex=gemIndex,skillId=gem.skillId,slotName=owner.slotName,
            itemId=owner.item.id,sourceLevel=owner.grant.level,previousLevel=gem.level,method='unique-equipped-item-grant'}
          gem.level=owner.grant.level;gem.sourceLevel=owner.grant.level;gem.fromItem=true
          gem.triggered=owner.grant.triggered;gem.triggerChance=owner.grant.triggerChance
          gem.noSupports=owner.grant.noSupports;gem.noReservation=owner.grant.noReservation
          -- Keep native gem metadata: stock's raw skill-ID lookup cannot find
          -- effect-keyed gemForSkill entries and would lose +Spell Skill Levels.
          local gemData=gem.gemId and data.gems[gem.gemId]
          if not gemData or gemData.grantedEffectId~=gem.skillId then
            gem.gemId=data.gemForSkill[effect] or data.gemForSkill[gem.skillId]
          end
          -- Leave source/slot unset so stock retains the manual supports.
          changed=true
        end
      end
      if changed then trial.skillsTab:ProcessSocketGroup(group) end
    end
  end
  return bindings
end
local function skillState(trial,bindings)
  local groups={}
  for index,group in ipairs(trial.skillsTab.socketGroupList) do
    local gems={}
    for _,gem in ipairs(group.gemList) do gems[#gems+1]={skillId=gem.skillId,gemId=gem.gemId,name=gem.nameSpec,
      level=gem.level,quality=gem.quality,enabled=gem.enabled,sourceLevel=gem.sourceLevel} end
    groups[#groups+1]={index=index,source=group.source,slot=group.slot,enabled=group.enabled,
      includeInFullDPS=group.includeInFullDPS,gems=gems}
  end
  local skill=trial.calcsTab.mainEnv.player.mainSkill
  local projected={}
  for _,binding in ipairs(bindings or {}) do
    for index,group in ipairs(trial.skillsTab.socketGroupList) do if group==binding.group then
      projected[#projected+1]={groupIndex=index,gemIndex=binding.gemIndex,skillId=binding.skillId,slotName=binding.slotName,
        itemId=binding.itemId,sourceLevel=binding.sourceLevel,previousLevel=binding.previousLevel,method=binding.method}
    end end
  end
  return {groups=groups,itemSkillBindings=projected,mainSkill=skill and skill.activeEffect and skill.activeEffect.grantedEffect.id,
    mainSocketGroup=trial.mainSocketGroup}
end

function M.evaluate(b,p)
  if busy then return nil,'item evaluator is busy' end
  busy=true
  local originalCache,originalAssignments=GlobalCache,GlobalGemAssignments
  local originalData,originalMain,originalLaunch,originalGlobalBuild=data,main,launch,build
  local parserCache=modLib and modLib.parseModCache
  local parserEntries={};for k,v in pairs(parserCache or {}) do parserEntries[k]=v end
  local function restoreGlobals()
    GlobalCache,GlobalGemAssignments=originalCache,originalAssignments
    data,main,launch,build=originalData,originalMain,originalLaunch,originalGlobalBuild
  end
  local function restoreParserCache()
    if parserCache then
      for k in pairs(parserCache) do if parserEntries[k]==nil then parserCache[k]=nil end end
      for k,v in pairs(parserEntries) do parserCache[k]=v end
    end
  end
  -- Native ItemsTab:Save reparses every live item. Serialize only a detached
  -- graph: an apparently read-only SaveDB call otherwise rewrites undo/cache aliases.
  local function snapshot()
    restoreGlobals()
    local trial,shadowData,shadowMain,shadowLaunch=detached(b,originalData,originalMain,originalLaunch)
    data,main,launch,build=shadowData,shadowMain,shadowLaunch,trial
    local xml=trial:SaveDB('api-item-evaluation-snapshot')
    restoreGlobals()
    return xml
  end
  local ok,result=xpcall(function()
    if not b or not b.calcsTab or not b.itemsTab or not b.skillsTab then error('ready PoB2 build required') end
    if type(p)~='table' or identity(p.expectedBuildName)~=identity(b.buildName) or type(p.expectedBuildName)~='string' then error('loaded build does not match expectedBuildName') end
    if type(p.expectedXml)~='string' or #p.expectedXml>20*1024*1024 then error('expectedXml snapshot required (maximum 20 MB)') end
    if not p.expectedXml:find('<PathOfBuilding2[%s>]') then error('PathOfBuilding2 snapshot required') end
    local expectedCanonical,xmlError=XmlSemantics.canonical(p.expectedXml)
    if not expectedCanonical then error('invalid expectedXml snapshot: '..tostring(xmlError)) end
    if XmlSemantics.canonical(snapshot())~=expectedCanonical then error('build XML changed since the snapshot; retry') end
    if tostring(p.itemSetId)~=tostring(b.itemsTab.activeItemSetId) then error('active item set changed') end
    if tostring(p.skillSetId)~=tostring(b.skillsTab.activeSkillSetId) then error('active skill set changed') end
    if type(p.snapshotId)~='string' or #p.snapshotId==0 or #p.snapshotId>128 then error('snapshotId required') end
    array(p.scenarios,1,12,'scenarios')
    local calcs=b.calcsTab.calcs
    if not calcs or type(calcs.getMiscCalculator)~='function' then error('native misc calculator factory unavailable') end
    local originalOutputs={main=outputs(b.calcsTab.mainOutput),calcs=outputs(b.calcsTab.calcsOutput)}
    local originalSelection=selection(b)
    local originalHistory=audit(history(b))
    local catalogAudit=audit(originalData)
    local treeAudit=audit(originalMain.tree)
    local cacheAudit=audit({originalCache,originalAssignments})
    local historyRefs=history(b)
    local function isolate()
      restoreGlobals()
      local trial,shadowData,shadowMain,shadowLaunch=detached(b,originalData,originalMain,originalLaunch)
      GlobalCache=freshCache(originalCache);GlobalGemAssignments={};data,main,launch,build=shadowData,shadowMain,shadowLaunch,trial
      return trial
    end
    local function calculate(trial)
      resolveLoadout(trial)
      local bindings=projectItemSkills(trial)
      local env=calcs.buildOutput(trial,'MAIN')
      trial.calcsTab.mainEnv=env;trial.calcsTab.mainOutput=env.player.output
      local calculator=calcs.getMiscCalculator(trial)
      return outputs(calculator({},true)),skillState(trial,bindings)
    end
    local baseline,baselineSkills=calculate(isolate())
    restoreGlobals()
    if not next(baseline) then error('native baseline outputs unavailable') end
    local comparisons={};local deadline=os.clock()+30
    for _,scenario in ipairs(p.scenarios) do
      local row={id=scenario.id,valid=false,inputs={},warnings={}}
      comparisons[#comparisons+1]=row
      local success,value=pcall(function()
        if os.clock()>deadline then error('native comparison time limit reached; remaining scenarios unevaluated') end
        if type(scenario.id)~='string' or #scenario.id==0 then error('scenario id required') end
        array(scenario.replacements,1,32,'replacements')
        local trial=isolate();resolveLoadout(trial)
        local changes={};local seenSlots={}
        for i,replacement in ipairs(scenario.replacements) do
          if type(replacement.slotName)~='string' or seenSlots[replacement.slotName] then error('duplicate or invalid replacement slot') end
          for _,key in ipairs({'candidateId','entryId','listingId'}) do
            if type(replacement[key])~='string' or #replacement[key]==0 or #replacement[key]>512 then error('replacement '..key..' is required (maximum 512 bytes)') end
          end
          seenSlots[replacement.slotName]=true
          local item=parsed(trial,replacement,-100000-i)
          changes[#changes+1]={input=replacement,item=item}
          row.inputs[#row.inputs+1]={slotName=replacement.slotName,text=replacement.text,remove=replacement.remove,
            candidateId=replacement.candidateId,entryId=replacement.entryId,listingId=replacement.listingId}
        end
        for _,change in ipairs(changes) do
          local slot=trial.itemsTab.slots[change.input.slotName];local id=change.item and change.item.id or 0
          local old=trial.itemsTab.items[slot.selItemId]
          -- Native generated-group identity includes item ID/name. A replacement
          -- gets a fresh inventory ID, but the same granted skill in the same
          -- slot should retain the user's supports, selections and Full DPS flag.
          -- MAIN still owns skill level, trigger and cost reconciliation.
          for _,group in ipairs(trial.skillsTab.socketGroupList) do
            if old and change.item and group.slot==change.input.slotName and group.source~='Default Attack'
              and (group.sourceItem==old or group.source==old.modSource) then
              for _,grant in ipairs(change.item.grantedSkills or {}) do
                if group.gemList[1] and group.gemList[1].skillId==grant.skillId then
                  group.source=change.item.modSource;group.sourceItem=change.item
                  -- Stock matches generated groups by level as well as source.
                  group.gemList[1].level=grant.level;group.gemList[1].sourceLevel=grant.level
                  break
                end
              end
            end
          end
          if change.item then trial.itemsTab.items[id]=change.item end
          slot:SetSelItemId(id)
        end
        local out,skills=calculate(trial)
        local removed={}
        for _,name in ipairs({'Weapon 2','Weapon 2 Swap'}) do
          local slot=trial.itemsTab.slots[name];local item=slot and trial.itemsTab.items[slot.selItemId]
          if item then
            local env=calcs.initEnv(trial,'CALCULATOR',{weaponSet=name:match(' Swap$') and 2 or 1,skipWeaponSetContexts=true})
            local flags={giantsBlood=env.modDB:Flag(nil,'GiantsBlood'),instrumentsOfPower=env.modDB:Flag(nil,'InstrumentsOfPower'),lordOfTheWilds=env.modDB:Flag(nil,'LordOfTheWilds')}
            if not trial.itemsTab:IsItemValidForSlot(item,name,trial.itemsTab.activeItemSet,flags) then
              if seenSlots[name] then error('replacement offhand is incompatible with the resulting weapon set: '..name) end
              slot:SetSelItemId(0);removed[#removed+1]=name
            end
          end
        end
        if #removed>0 then out,skills=calculate(trial) end
        row.implicitRemovals=removed
        for _,change in ipairs(changes) do
          if change.item then
            local slot=trial.itemsTab.slots[change.input.slotName]
            if slot.selItemId~=change.item.id then error('native reconciliation removed the requested item: '..change.input.slotName) end
            -- Flasks/charms live in activation-specific native collections, not
            -- necessarily player.itemList. Inactive activation is retained.
            if change.item.type~='Charm' and change.item.type~='Flask' and (not slot.weaponSet or slot.weaponSet==trial.calcsTab.mainEnv.weaponSet) then
              local name=change.input.slotName:gsub(' Swap$','')
              if trial.calcsTab.mainEnv.player.itemList[name]~=change.item then error('native calculator excluded the requested item from active equipment: '..name) end
            end
          end
        end
        row.skills=skills
        for _,flag in ipairs({'ManaCostWarning','LifeCostWarning','ESCostWarning','RageCostWarning','EternalLifeWarning'}) do
          if trial.calcsTab.mainOutput[flag]==true then row.warnings[#row.warnings+1]=flag end
        end
        if skills.mainSkill~=baselineSkills.mainSkill then row.warnings[#row.warnings+1]='Selected main skill changed after native equipment reconciliation; damage totals describe a different skill' end
        if not next(out) then error('native comparison outputs unavailable') end
        for _,change in ipairs(changes) do
          local level=change.item and change.item.requirements and tonumber(change.item.requirements.level)
          if level and level>b.characterLevel then row.warnings[#row.warnings+1]='Required character level '..level..' for '..change.input.slotName end
        end
        for _,attr in ipairs({'Str','Dex','Int'}) do
          if number(out['Req'..attr]) and number(out[attr]) and out['Req'..attr]>out[attr] then row.warnings[#row.warnings+1]='Insufficient '..attr end
        end
        if number(out.SpiritUnreserved) and out.SpiritUnreserved<0 then row.warnings[#row.warnings+1]='Spirit reservation exceeds available Spirit' end
        row.output=out;row.deltas=delta(out,baseline);row.valid=#row.warnings==0
      end)
      if not success then row.error=tostring(value);row.output=nil;row.deltas=nil end
      restoreGlobals();collectgarbage('step',1000)
    end
    restoreGlobals();restoreParserCache()
    local unchanged={xmlUnchanged=XmlSemantics.canonical(snapshot())==expectedCanonical,
      statsUnchanged=equal(originalOutputs,{main=outputs(b.calcsTab.mainOutput),calcs=outputs(b.calcsTab.calcsOutput)}),
      selectionsUnchanged=equal(originalSelection,selection(b)),undoUnchanged=auditUnchanged(originalHistory),
      catalogUnchanged=auditUnchanged(catalogAudit),treeUnchanged=auditUnchanged(treeAudit),cacheUnchanged=auditUnchanged(cacheAudit)}
    for key,refs in pairs(historyRefs) do
      if refs.undo~=b[key].undo or refs.redo~=b[key].redo then unchanged.undoUnchanged=false end
    end
    for key,value in pairs(unchanged) do if not value then
      local ledger=({undoUnchanged=originalHistory,catalogUnchanged=catalogAudit,treeUnchanged=treeAudit,cacheUnchanged=cacheAudit})[key]
      local reason
      if ledger then local _,detail=auditUnchanged(ledger);reason=detail end
      error('native item comparison preservation failed: '..key..(reason and ': '..reason or ''))
    end end
    return {snapshotId=p.snapshotId,baseline=baseline,baselineSkills=baselineSkills,comparisons=comparisons,preservation=unchanged,
      conditions={buildName=b.buildName,itemSetId=b.itemsTab.activeItemSetId,skillSetId=b.skillsTab.activeSkillSetId,
        weaponSet=originalSelection.weaponSet,mainSocketGroup=b.mainSocketGroup,characterLevel=b.characterLevel,
        configInput=copy(b.configTab.input),calcsInput=copy(b.calcsTab.input),calculationMode='CALCULATOR',
        method='detached native MAIN reconciliation and GetMiscCalculator; complete equipment set'}}
  end,function(error) return tostring(error) end)
  restoreGlobals();restoreParserCache();busy=false
  if not ok then return nil,result end
  return result
end
return M
