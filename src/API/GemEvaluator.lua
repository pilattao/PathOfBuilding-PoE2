-- Native PoB2 gem comparisons. No build is loaded, saved to disk or added to undo.
-- The gem dropdown edits instances before calling MiscCalculator: CalcSetup has
-- no gem-list override. We instead use isolated native skill undo snapshots and
-- calcs.buildOutput(MAIN), which also exposes applied supports and Full DPS.
local M = {}
local busy = false
local MAX_SETUPS, MAX_GEMS, MAX_EVALUATIONS = 20, 64, 160
local function number(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
local function integer(n,low,high)
  return number(n) and n==math.floor(n) and n>=low and (not high or n<=high) and n or nil
end
local function array(t,low,high,label)
  if type(t)~='table' or #t<low or #t>high then error(label..' has invalid size') end
  for k in pairs(t) do if not integer(k,1,#t) then error(label..' must be a dense array') end end
end
local function shallow(t) local r={} for k,v in pairs(t or {}) do r[k]=v end return r end
local function plain(t,seen)
  if type(t)~='table' then return t end
  seen=seen or {};if seen[t] then return seen[t] end
  local r={};seen[t]=r;for k,v in pairs(t) do r[k]=plain(v,seen) end;return r
end
local function equal(a,b,seen)
  if a==b then return true end
  if type(a)~='table' or type(b)~='table' then return false end
  seen=seen or {};if seen[a]==b then return true end;seen[a]=b
  for k,v in pairs(a) do if not equal(v,b[k],seen) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function replace(t,values) for k in pairs(t) do t[k]=nil end;for k,v in pairs(values) do t[k]=v end end
local function identity(s) return type(s)=='string' and s:gsub('\\','/'):gsub('%.xml$',''):lower() end
-- XML selections are nested tables; native CreateUndoState intentionally copies
-- gem instances shallowly. Copy these maps before any trial can rewrite them.
local function gemCopy(g)
  local c=shallow(g)
  for k,v in pairs(g) do
    if type(v)=='table' and (k:match('^statSet') or k:match('^skillMinion')) then c[k]=plain(v) end
  end
  return c
end
local function stateCopy(s)
  local c=shallow(s);c.skillSets={};c.skillSetOrderList=shallow(s.skillSetOrderList)
  for id,set in pairs(s.skillSets) do
    local newSet=shallow(set);c.skillSets[id]=newSet;newSet.socketGroupList={}
    for i,g in ipairs(set.socketGroupList) do
      local newGroup=shallow(g);newSet.socketGroupList[i]=newGroup;newGroup.gemList={}
      for j,gem in ipairs(g.gemList) do newGroup.gemList[j]=gemCopy(gem) end
    end
  end
  return c
end
local function historyCopy(history)
  local c={};for i,state in pairs(history or {}) do c[i]=stateCopy(state) end;return c
end
local function effect(g) return g.grantedEffect or g.gemData and g.gemData.grantedEffect end
local function isSupport(g) local e=effect(g);return e and e.support==true end
local function gemInfo(g,index)
  local r={index=index,gemId=g.gemData and g.gemData.id or g.gemId,skillId=g.skillId,name=g.nameSpec,
    level=g.level,quality=g.quality,count=g.count,enabled=g.enabled,corrupted=g.corrupted,
    enableGlobal1=g.enableGlobal1,enableGlobal2=g.enableGlobal2,support=isSupport(g),
    statSet=plain(g.statSet),statSetCalcs=plain(g.statSetCalcs),skillPart=g.skillPart,skillPartCalcs=g.skillPartCalcs}
  return r
end
local fields={'CombinedDPS','TotalDPS','FullDPS','FullDotDPS','AverageDamage','Speed','HitSpeed',
  'ManaCost','ManaCostPerSecond','ManaPercentCost','LifeCost','LifeCostPerSecond','LifePercentCost','ESCost','RageCost',
  'Life','LifeUnreserved','Mana','ManaUnreserved','Spirit','SpiritUnreserved','NetManaRegen','EnergyShield','TotalEHP',
  'Armour','Evasion','BlockChance','DeflectChance','FireResist','ColdResist','LightningResist','ChaosResist',
  'PhysicalMaximumHitTaken','FireMaximumHitTaken','ColdMaximumHitTaken','LightningMaximumHitTaken','ChaosMaximumHitTaken',
  'LifeRegenRecovery','EnergyShieldRegenRecovery','EnergyShieldRecharge','ReqStr','ReqDex','ReqInt','Str','Dex','Int'}
local metrics={CombinedDPS=true,TotalDPS=true,FullDPS=true,MinionCombinedDPS=true,TotalEHP=true,AverageDamage=true,Speed=true}
local function outputs(output)
  local r={}
  for _,k in ipairs(fields) do if number(output[k]) then r[k]=output[k] end end
  for _,k in ipairs({'CombinedDPS','TotalDPS','AverageDamage'}) do
    local n=output.Minion and output.Minion[k]
    if number(n) then r['Minion'..k]=n end
  end
  return r
end
local function allScalars(output)
  local r={};for k,v in pairs(output or {}) do
    if number(v) or type(v)=='string' or type(v)=='boolean' then r[k]=v
    elseif k=='Minion' and type(v)=='table' then r[k]=allScalars(v) end
  end;return r
end
local function deltas(output,baseline)
  local r={};for k,v in pairs(output) do if number(baseline[k]) then
    r[k]={absolute=v-baseline[k]}
    if baseline[k]~=0 then r[k].percent=(v-baseline[k])/math.abs(baseline[k])*100 end
  end end;return r
end
local function scalarMap(t)
  local r={};for k,v in pairs(t or {}) do if number(v) or type(v)=='string' or type(v)=='boolean' then r[k]=v end end;return r
end
local function conditions(b,group,evaluationGroup)
  return {buildName=b.buildName,characterLevel=b.characterLevel,skillSetId=b.skillsTab.activeSkillSetId,
    groupIndex=group,evaluationGroupIndex=evaluationGroup,mainSocketGroup=b.mainSocketGroup,
    calcsInput=scalarMap(b.calcsTab.input),configSetId=b.configTab.activeConfigSetId,
    configInput=scalarMap(b.configTab.input),configPlaceholder=scalarMap(b.configTab.placeholder),
    itemSetId=b.itemsTab.activeItemSetId,useSecondWeaponSet=b.itemsTab.activeItemSet.useSecondWeaponSet==true,
    treeSpecId=b.treeTab and b.treeTab.activeSpec,treeVersion=b.spec and b.spec.treeVersion}
end
local function issues(group,env,b)
  local supports,warnings={},{}
  for i,g in ipairs(group.gemList) do
    if isSupport(g) then
      local display=g.displayEffect or g.supportEffect
      local status=g.enabled==false and 'disabled' or g.errMsg and 'unresolved' or
        display and display.superseded and 'superseded' or
        display and next(display.isSupporting or {}) and 'applied' or 'incompatible'
      local targets={}
      for skill,applies in pairs(display and display.isSupporting or {}) do
        if applies and type(skill)=='table' and skill.activeEffect then
          targets[#targets+1]={name=skill.activeEffect.grantedEffect.name,skillId=skill.activeEffect.grantedEffect.id}
        end
      end
      supports[#supports+1]={gemIndex=i,gemId=g.gemData and g.gemData.id,name=g.nameSpec,status=status,description=effect(g).description,targets=targets,error=g.errMsg}
    end
    if g.enabled~=false and number(g.reqLevel) and g.reqLevel>b.characterLevel then warnings[#warnings+1]=g.nameSpec..': character level requirement '..g.reqLevel end
  end
  local out=env.player.output
  for _,key in ipairs({'ManaCostWarning','LifeCostWarning','ESCostWarning','RageCostWarning','EternalLifeWarning'}) do
    if out[key]==true then warnings[#warnings+1]=key end
  end
  if number(out.SpiritUnreserved) and out.SpiritUnreserved<0 then warnings[#warnings+1]='Spirit reservation exceeds available Spirit' end
  for _,attr in ipairs({'Str','Dex','Int'}) do
    if number(out['Req'..attr]) and number(out[attr]) and out['Req'..attr]>out[attr] then warnings[#warnings+1]='Insufficient '..attr end
  end
  local valid=#warnings==0 and group.enabled~=false and group.slotEnabled~=false and env.player.mainSkill~=nil
  for _,s in ipairs(supports) do if s.status~='applied' and s.status~='disabled' then valid=false end end
  return supports,warnings,valid
end

local function evaluate(b,p,ops)
  if type(p)~='table' or not b or not b.skillsTab or not b.calcsTab or not b.configTab or not b.itemsTab then error('ready PoB2 build required') end
  if type(p.expectedBuildName)~='string' or identity(p.expectedBuildName)~=identity(b.buildName) then error('loaded build does not match expectedBuildName') end
  if type(p.expectedXml)~='string' or #p.expectedXml>20*1024*1024 then error('expectedXml snapshot required (maximum 20 MB)') end
  local tab,ct=b.skillsTab,b.calcsTab
  if tostring(p.skillSetId)~=tostring(tab.activeSkillSetId) then error('active skill set changed; only the current loaded skill set can be evaluated') end
  if not tab.CreateUndoState or not tab.RestoreUndoState or not ct.calcs or not ct.calcs.buildOutput then error('native PoB2 calculation/undo interface unavailable') end
  local groupIndex=integer(p.groupIndex,1);local originalGroup=groupIndex and tab.socketGroupList[groupIndex]
  if not originalGroup then error('invalid groupIndex') end
  if originalGroup.enabled==false then error('selected group is disabled') end
  if p.metric and not metrics[p.metric] then error('unsupported native ranking metric') end
  if p.setups and p.search then error('provide setups or search, not both') end
  if p.search then
    if type(p.search)~='table' or (p.search.mode~='suggest' and p.search.mode~='optimize') then error('invalid search mode') end
    if p.search.maxEvaluations and not integer(p.search.maxEvaluations,1,MAX_EVALUATIONS) then error('invalid maxEvaluations') end
    if p.search.limit and not integer(p.search.limit,1,20) then error('invalid result limit') end
    if p.search.mode=='optimize' and not integer(p.search.targetGemCount,1,MAX_GEMS) then error('invalid targetGemCount') end
  else array(p.setups,1,MAX_SETUPS,'setups') end
  -- Read once without rebuilding: callers supply a freshly exported, calculated XML.
  local originalXml=b:SaveDB('api-gem-evaluation-check')
  if originalXml~=p.expectedXml then error('build XML changed since the evidence snapshot; retry') end
  if not ct.mainOutput then error('native outputs unavailable; export the current build first') end
  local originalStats=allScalars(ct.mainOutput);local originalCalcsStats=allScalars(ct.calcsOutput)
  local originalState=tab:CreateUndoState()
  local emergencyState=stateCopy(originalState)
  -- ProcessSocketGroup clears costs on shared granted-effect level records for
  -- raw triggered skills. Native skill undo does not include those data records.
  local effectCosts,seenCosts={},{}
  for _,set in pairs(originalState.skillSets) do for _,group in ipairs(set.socketGroupList) do for _,gem in ipairs(group.gemList) do
    local ge=gem.triggered and gem.skillId and b.data.skills[gem.skillId]
    if ge then for _,level in pairs(ge.levels or {}) do if not seenCosts[level] then
      seenCosts[level]=true;effectCosts[#effectCosts+1]={level=level,cost=level.cost}
    end end end
  end end end
  local function restoreEffectCosts() for _,saved in ipairs(effectCosts) do saved.level.cost=saved.cost end end
  local flags={tab=tab.modFlag,build=b.modFlag,buildFlag=b.buildFlag,view=b.viewMode,revision=b.outputRevision,
    level=b.characterLevel,auto=b.characterLevelAutoMode,loadout=b.activeLoadout,power=ct.powerBuildFlag}
  local inputRef,input=ct.input,plain(ct.input)
  local undoRef,redoRef=tab.undo,tab.redo
  local undo,redo=historyCopy(tab.undo),historyCopy(tab.redo)
  local undoEntries,redoEntries=shallow(tab.undo),shallow(tab.redo)
  local displayIndex=isValueInArray(tab.socketGroupList,tab.displayGroup)
  local groupSelection=tab.controls and tab.controls.groupList and tab.controls.groupList.selIndex
  local loadoutControl=b.controls and b.controls.buildLoadouts
  local loadoutState=loadoutControl and shallow(loadoutControl)
  local configRef,configInput=b.configTab.input,plain(b.configTab.input)
  local configPlaceholderRef,configPlaceholder=b.configTab.placeholder,plain(b.configTab.placeholder)
  local itemSet=b.itemsTab.activeItemSet;local weaponSet=itemSet.useSecondWeaponSet
  local itemSetId,configSetId=b.itemsTab.activeItemSetId,b.configTab.activeConfigSetId
  local oldGlobalCache,oldAssignments=GlobalCache,GlobalGemAssignments
  local evaluationIndex=p.evaluationGroupIndex and integer(p.evaluationGroupIndex,1) or groupIndex
  local invalidEvaluationGroup=p.evaluationGroupIndex~=nil and not integer(p.evaluationGroupIndex,1)
  local applied=conditions(b,groupIndex,evaluationIndex)
  local trialResults,ranking={},{}
  local baseline,metric,deadline,exhausted,coverageLimited,evaluations,eligibleCount,selectedEffectId,selectedRef
  evaluations,eligibleCount=0,0
  local limit=p.search and (p.search.maxEvaluations or 48) or MAX_SETUPS
  local maxTime=15000 -- wall-clock guard between native passes; never interrupts a pass/rollback
  local now=GetTime and function() return GetTime() end or function() return os.clock()*1000 end
  deadline=now()+maxTime

  local function freshCache()
    if oldGlobalCache then GlobalCache=shallow(oldGlobalCache);GlobalCache.cachedData={MAIN={},CALCS={},CALCULATOR={}} end
    if oldAssignments then GlobalGemAssignments={} end
  end
  local function reset()
    restoreEffectCosts()
    freshCache()
    tab:RestoreUndoState(stateCopy(originalState))
    ct.input=inputRef;replace(inputRef,plain(input))
    b.mainSocketGroup=evaluationIndex
    b.characterLevel,b.characterLevelAutoMode=flags.level,flags.auto
  end
  local function native()
    local env=ct.calcs.buildOutput(b,'MAIN')
    if not env or not env.player or not env.player.output then error('native calculator returned no output') end
    ct.mainEnv,ct.mainOutput=env,env.player.output
    return env
  end
  local function instance(spec,base,used)
    if type(spec)=='string' then spec={gemId=spec} end
    if type(spec)~='table' then error('gem specification must be an object or exact gem ID') end
    local current
    if spec.refIndex and spec.replaceIndex then error('refIndex and replaceIndex are mutually exclusive') end
    if spec.refIndex~=nil or spec.replaceIndex~=nil then
      local index=integer(spec.refIndex or spec.replaceIndex,1,#base.gemList)
      if not index or used[index] then error('invalid or repeated gem refIndex') end
      used[index]=true;current=base.gemList[index]
    end
    local resolved,err
    if spec.gemId or spec.gemName then resolved,err=ops.resolveGem(spec.gemId or spec.gemName);if not resolved then error(err) end end
    if current and resolved and not spec.replaceIndex and current.gemData~=resolved then error('refIndex does not match gem identity') end
    local gem=current and gemCopy(current) or {gemId=resolved and resolved.id,nameSpec=resolved and resolved.name,
      gemData=resolved,skillId=resolved and resolved.grantedEffectId,level=resolved and resolved.naturalMaxLevel,
      quality=0,count=1,enabled=true,enableGlobal1=true,enableGlobal2=true,corrupted=false,corruptLevel=0}
    if spec.replaceIndex then
      if not resolved then error('replacement requires a gem identity') end
      if base.source and not isSupport(current) then error('item-granted active skill cannot be replaced') end
      gem.gemData,gem.grantedEffect,gem.gemId,gem.skillId,gem.nameSpec=resolved,nil,resolved.id,resolved.grantedEffectId,resolved.name
      gem.level=resolved.grantedEffect.levels[gem.level] and gem.level or resolved.naturalMaxLevel
      gem.statSet,gem.statSetCalcs={},{}
      gem.skillPart,gem.skillPartCalcs=nil,nil
      for key in pairs(gem) do if key:match('^skillMinion') then gem[key]=nil end end
      gem.errMsg,gem.displayEffect,gem.supportEffect=nil,nil,nil
    end
    if not current and not resolved then error('gemId, gemName or refIndex required') end
    local ge=effect(gem)
    if not ge or ge.hideFromSideBar and not current then error('gem cannot be used in a PoB2 group') end
    for _,key in ipairs({'level','quality','count','skillPart','skillPartCalcs'}) do
      if spec[key]~=nil then
        local n=integer(spec[key],key=='quality' and 0 or 1,key=='quality' and 99 or key=='count' and 1000 or nil)
        if not n or key=='level' and not ge.levels[n] then error('invalid gem '..key) end
        if key:match('^skillPart') and (not ge.parts or not ge.parts[n]) then error('skill part unavailable') end
        gem[key]=n
      end
    end
    for _,key in ipairs({'enabled','enableGlobal1','enableGlobal2'}) do
      if spec[key]~=nil then if type(spec[key])~='boolean' then error(key..' must be boolean') end;gem[key]=spec[key] end
    end
    for _,key in ipairs({'statSet','statSetCalcs'}) do
      if spec[key]~=nil then
        if type(spec[key])~='table' then error(key..' must be a map') end
        local maps={}
        for id,index in pairs(spec[key]) do
          local target=b.data.skills[id]
          local n=integer(index,1)
          if type(id)~='string' or not n or not target or not target.statSets or not target.statSets[n] then error('stat set unavailable') end
          local owned=id==ge.id
          for _,additional in ipairs(gem.gemData and gem.gemData.additionalGrantedEffects or {}) do if additional.id==id then owned=true end end
          if not owned then error('stat set must belong to a gem granted effect') end
          maps[id]=n
        end
        gem[key]=maps
      end
    end
    if not ge.levels[gem.level] then error('gem level unavailable in native data') end
    return gem
  end
  local function install(specs)
    array(specs,0,MAX_GEMS,'gems')
    local base=tab.socketGroupList[groupIndex]
    local gems,used={},{}
    for _,spec in ipairs(specs) do gems[#gems+1]=instance(spec,base,used) end
    if base.source then
      local supports={}
      for _,g in ipairs(gems) do if isSupport(g) then supports[#supports+1]=g end end
      for i,g in ipairs(base.gemList) do
        if not isSupport(g) and not used[i] then error('item-granted active skill must be retained with refIndex') end
      end
      for _,g in ipairs(gems) do if not isSupport(g) then
        local found=false
        for _,original in ipairs(base.gemList) do if equal(gemInfo(g),gemInfo(original)) then found=true end end
        if not found then error('item-granted active skill cannot be changed') end
      end end
      if #supports==0 then return base,gems end
      if base.noSupports then error('item-granted skill does not accept supports') end
      if not base.slot then error('item-granted skill has no supporting equipment slot') end
      -- Dedicated temporary support group: never overwrite item-provided instances.
      local temporary={label='API gem evaluation',slot=base.slot,enabled=true,includeInFullDPS=false,
        mainActiveSkill=1,mainActiveSkillCalcs=1,gemList=supports}
      table.insert(tab.socketGroupList,temporary);tab:ProcessSocketGroup(temporary)
      return temporary,gems
    end
    if base.noSupports then for _,g in ipairs(gems) do if isSupport(g) then error('group does not accept supports') end end end
    base.gemList=gems;tab:ProcessSocketGroup(base)
    for _,g in ipairs(gems) do if g.errMsg or not effect(g) then error(g.errMsg or 'native gem processing failed') end end
    return base,gems
  end
  local function result(name,specs)
    if evaluations>=limit or now()>deadline then exhausted=true;return nil end
    evaluations=evaluations+1
    reset()
    local ok,row=pcall(function()
      local group,gems=install(specs)
      local env=native()
      local selected=tab.socketGroupList[evaluationIndex]
      local retained
      if evaluationIndex==groupIndex and not selected.source then
        for index,spec in ipairs(specs) do if type(spec)=='table' and spec.refIndex==selectedRef then retained=gems[index] end end
      end
      for index,skill in ipairs(selected.displaySkillList or {}) do
        if skill.activeEffect and skill.activeEffect.grantedEffect.id==selectedEffectId and
          (not retained or skill.activeEffect.srcInstance==retained) then
          if selected.mainActiveSkill~=index then selected.mainActiveSkill=index;env=native() end
          break
        end
      end
      local output=outputs(env.player.output)
      local supports,warnings,valid=issues(group,env,b)
      if not selected.displaySkillList or #selected.displaySkillList==0 then valid=false;warnings[#warnings+1]='No active skill in the evaluation group' end
      if group.slotEnabled==false then warnings[#warnings+1]='Group is disabled in the current weapon set' end
      local info={};for i,g in ipairs(gems) do info[i]=gemInfo(g,i) end
      local selected=tab.socketGroupList[evaluationIndex]
      return {name=name,gems=info,output=output,deltas=deltas(output,baseline),supports=supports,
        warnings=warnings,valid=valid and number(output[metric]),metric=metric,
        selection={groupIndex=evaluationIndex,mainActiveSkill=selected and selected.mainActiveSkill,
          mainActiveSkillCalcs=selected and selected.mainActiveSkillCalcs},_specs=specs}
    end)
    if not ok then row={name=name,error=tostring(row),valid=false,_specs=specs} end
    trialResults[#trialResults+1]=row
    return row
  end
  local function better(a,c)
    if a.valid~=c.valid then return a.valid==true end
    local av,cv=a.output and a.output[metric],c.output and c.output[metric]
    if av~=cv then return (av or -math.huge)>(cv or -math.huge) end
    return a.name<c.name
  end
  local ok,failure=pcall(function()
    if invalidEvaluationGroup then error('invalid evaluationGroupIndex') end
    reset()
    -- Resolve support-only groups to the corresponding native item skill.
    local group=tab.socketGroupList[groupIndex]
    local hasActive=false;for _,g in ipairs(group.gemList) do if not isSupport(g) and g.enabled~=false then hasActive=true end end
    if not hasActive and not p.evaluationGroupIndex then
      local candidates={}
      for index,source in ipairs(tab.socketGroupList) do if source.source and source.slot and source.slot==group.slot and source.enabled~=false then candidates[#candidates+1]=index end end
      if #candidates~=1 then error('support-only group requires an unambiguous item-granted skill or evaluationGroupIndex') end
      evaluationIndex=candidates[1];b.mainSocketGroup=evaluationIndex;applied.evaluationGroupIndex=evaluationIndex
    end
    if not tab.socketGroupList[evaluationIndex] then error('invalid evaluationGroupIndex') end
    local baselineEnv=native();baseline=outputs(baselineEnv.player.output)
    local mainEffect=baselineEnv.player.mainSkill and baselineEnv.player.mainSkill.activeEffect
    selectedEffectId=mainEffect and mainEffect.grantedEffect.id
    selectedRef=mainEffect and isValueInArray(tab.socketGroupList[evaluationIndex].gemList,mainEffect.srcInstance)
    metric=p.metric or (number(baseline.MinionCombinedDPS) and 'MinionCombinedDPS' or 'CombinedDPS')
    if not number(baseline[metric]) then error('native baseline metric unavailable: '..metric) end
    if not p.search then
      for _,setup in ipairs(p.setups) do
        if type(setup.name)~='string' or #setup.name==0 or #setup.name>160 then error('invalid setup name') end
        if not result(setup.name,setup.gems) then break end
      end
    else
      local base=originalState.skillSets[originalState.activeSkillSetId].socketGroupList[groupIndex]
      local refs,activeRefs,supportSlots={},{},{}
      for i,g in ipairs(base.gemList) do
        refs[#refs+1]={refIndex=i}
        if isSupport(g) then if g.enabled~=false then supportSlots[#supportSlots+1]=#refs end else activeRefs[#activeRefs+1]={refIndex=i} end
      end
      local eligibleSkills=tab.socketGroupList[evaluationIndex].displaySkillList or {}
      if p.search.mode=='suggest' or p.search.targetGemCount==#refs then result('Current setup',refs) end
      local pool={}
      if p.search.candidateGemIds then
        array(p.search.candidateGemIds,1,512,'candidateGemIds')
        local seen={}
        for _,id in ipairs(p.search.candidateGemIds) do
          local gem,err=ops.resolveGem(id);if not gem or not gem.grantedEffect.support then error(err or 'candidate is not a support') end
          if not seen[gem.id] then pool[#pool+1]=gem;seen[gem.id]=true end
        end
      else
        local activeSkills=eligibleSkills
        for _,gem in pairs(b.data.gems) do
          local ge=gem.grantedEffect
          if ge and ge.support and (tab.showLegacyGems or not ge.legacy) and
            (tab.showSupportGemTypes~='NORMAL' or not ge.isLineage) and (tab.showSupportGemTypes~='LINEAGE' or ge.isLineage) then
            for _,skill in ipairs(activeSkills) do if calcLib.canGrantedEffectSupportActiveSkill(ge,skill) then pool[#pool+1]=gem;break end end
          end
        end
        -- Deterministic coverage order. Numeric ordering is always based on evaluated output.
        table.sort(pool,function(a,c) return a.id<c.id end)
      end
      eligibleCount=#pool
      if p.search.mode=='suggest' then
        local slots=shallow(supportSlots)
        if #slots==0 then slots[1]=#refs+1 end
        for _,gem in ipairs(pool) do
          for _,slot in ipairs(slots) do
            local specs=plain(refs);specs[slot]={gemId=gem.id,replaceIndex=base.gemList[slot] and slot or nil}
            local row=result(gem.name..' @ '..slot,specs)
            if not row then break end
          end
          if exhausted then break end
        end
      else
        local needed=p.search.targetGemCount-#activeRefs
        if needed<0 then error('targetGemCount is smaller than the active-skill count') end
        local seeds=plain(activeRefs)
        for i=1,math.min(needed,#supportSlots) do seeds[#seeds+1]=refs[supportSlots[i]] end
        local beam={{_specs=seeds,name='Current seed',valid=true}}
        if needed==0 then result('Active skills only',seeds) end
        for position=1,needed do
          local round={}
          local perBeam=math.max(1,math.floor((limit-evaluations)/math.max(1,(needed-position+1)*#beam)))
          for _,seed in ipairs(beam) do
            if #pool>perBeam then coverageLimited=true end
            for i=1,math.min(#pool,perBeam) do
              local specs=plain(seed._specs);specs[#activeRefs+position]={gemId=pool[i].id,replaceIndex=supportSlots[position]}
              local row=result('Candidate '..(evaluations+1),specs)
              if row and row.valid then round[#round+1]=row end
              if exhausted then break end
            end
          end
          table.sort(round,better);beam={}
          for i=1,math.min(2,#round) do beam[i]=round[i] end
          if #beam==0 or exhausted then break end
        end
      end
    end
    for _,row in ipairs(trialResults) do
      local rightSize=not p.search or p.search.mode~='optimize' or row.gems and #row.gems==p.search.targetGemCount
      if row.valid and rightSize then ranking[#ranking+1]=row end
    end
    table.sort(ranking,better)
  end)

  -- Always restore via native undo, including after input/calculation errors.
  local restored,restoreError=pcall(function()
    freshCache();tab:RestoreUndoState(originalState)
    ct.input=inputRef;replace(inputRef,input)
    b.mainSocketGroup=originalState.activeSocketGroup
    b.characterLevel,b.characterLevelAutoMode=flags.level,flags.auto
    replace(configRef,configInput);b.configTab.input=configRef
    if configPlaceholderRef then replace(configPlaceholderRef,configPlaceholder);b.configTab.placeholder=configPlaceholderRef end
    itemSet.useSecondWeaponSet=weaponSet
    b.itemsTab.activeItemSetId,b.itemsTab.activeItemSet=itemSetId,itemSet
    b.configTab.activeConfigSetId=configSetId
    tab.undo,tab.redo=undoRef,redoRef
    -- Preserve actual history entry references when the native methods left them intact.
    if not equal(tab.undo,undo) then replace(tab.undo,undo) else replace(tab.undo,undoEntries) end
    if not equal(tab.redo,redo) then replace(tab.redo,redo) else replace(tab.redo,redoEntries) end
    tab:SetDisplayGroup(displayIndex and tab.socketGroupList[displayIndex])
    if tab.controls and tab.controls.groupList then
      tab.controls.groupList.selIndex=groupSelection
      tab.controls.groupList.selValue=groupSelection and tab.socketGroupList[groupSelection]
    end
    restoreEffectCosts()
    local output,err=ops.getOutput();if not output then error(err or 'restored native outputs unavailable') end
    if not equal(allScalars(output),originalStats) or not equal(allScalars(ct.calcsOutput),originalCalcsStats) then error('restored native stats differ') end
    if b:SaveDB('api-gem-rollback-check')~=originalXml then error('restored XML differs') end
    if not equal(tab.undo,undo) or not equal(tab.redo,redo) then error('restored undo history differs') end
  end)
  if not restored then
    -- An exception in native undo UI synchronization must not leave trial gems
    -- installed. Recover the persistent structure from its native snapshot, but
    -- still reject all results: normal rollback could not be verified.
    pcall(function()
      replace(tab.skillSets,emergencyState.skillSets)
      replace(tab.skillSetOrderList,emergencyState.skillSetOrderList)
      tab.activeSkillSetId=emergencyState.activeSkillSetId
      tab.socketGroupList=tab.skillSets[tab.activeSkillSetId].socketGroupList
      tab.displayGroup=displayIndex and tab.socketGroupList[displayIndex]
      if tab.controls and tab.controls.groupList then
        tab.controls.groupList.list=tab.socketGroupList
        tab.controls.groupList.selIndex=groupSelection
        tab.controls.groupList.selValue=groupSelection and tab.socketGroupList[groupSelection]
      end
      ct.input=inputRef;replace(inputRef,input)
      b.mainSocketGroup=emergencyState.activeSocketGroup
      b.characterLevel,b.characterLevelAutoMode=flags.level,flags.auto
      replace(configRef,configInput);b.configTab.input=configRef
      if configPlaceholderRef then replace(configPlaceholderRef,configPlaceholder);b.configTab.placeholder=configPlaceholderRef end
      itemSet.useSecondWeaponSet=weaponSet
    b.itemsTab.activeItemSetId,b.itemsTab.activeItemSet=itemSetId,itemSet
    b.configTab.activeConfigSetId=configSetId
      tab.undo,tab.redo=undoRef,redoRef;replace(undoRef,undo);replace(redoRef,redo)
    end)
  end
  -- These flags/UI values are outside native skill undo and must be restored too.
  tab.modFlag,b.modFlag,b.buildFlag=flags.tab,flags.build,flags.buildFlag
  b.viewMode,b.outputRevision,b.activeLoadout=flags.view,flags.revision,flags.loadout
  ct.powerBuildFlag=flags.power
  if loadoutControl then replace(loadoutControl,loadoutState) end
  restoreEffectCosts()
  GlobalCache,GlobalGemAssignments=oldGlobalCache,oldAssignments
  if not restored then
    -- Cached calculation closures can still refer to a failed trial. Fail closed.
    ct.mainOutput,ct.mainEnv,ct.calcsOutput,ct.calcsEnv,ct.miscCalculator,ct.nodeCalculator=nil,nil,nil,nil,nil,nil
    error((not ok and tostring(failure)..'; ' or '')..'gem evaluation rollback failed: '..tostring(restoreError))
  end
  if not ok then error(failure) end
  local returned={}
  for _,row in ipairs(ranking) do
    local duplicate=false
    if p.search then for _,previous in ipairs(returned) do
      if equal(row.gems,previous.gems) and equal(row.selection,previous.selection) then duplicate=true;break end
    end end
    if not duplicate then returned[#returned+1]=row end
    if #returned>=(p.search and (p.search.limit or 5) or MAX_SETUPS) then break end
  end
  for _,row in ipairs(trialResults) do row._specs=nil end
  return {baseline=baseline,metric=metric,setups=trialResults,ranking=returned,conditions=applied,
    search={evaluations=evaluations,eligibleCandidates=eligibleCount,budget=limit,truncated=exhausted==true or coverageLimited==true,
      algorithm=p.search and (p.search.mode=='suggest' and 'bounded single-support replacements' or 'bounded beam search') or 'explicit setups',
      scope='best evaluated setups under unchanged build/configuration; not a global optimum or market-price estimate'},
    rollback={xmlUnchanged=true,statsUnchanged=true,selectionsUnchanged=true,undoUnchanged=true}}
end
function M.evaluate(b,p,ops)
  if busy then return nil,'native gem evaluation is already running' end
  busy=true
  local ok,result=pcall(evaluate,b,p,ops)
  busy=false
  if not ok then return nil,tostring(result) end
  return result
end
return M
