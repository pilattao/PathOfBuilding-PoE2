-- PoB2 snapshot equality using PoB's own parser. In particular, literal attribute
-- newlines/tabs must survive: standard XML whitespace normalization is unsafe.
-- Keep these rules aligned with scripts/poe2_xml_semantics.py.
local M = {}
local xml = common and common.xml or require('xml')
local base64 = common and common.base64 or require('base64')
local nodeLists = {nodes=true,strNodes=true,dexNodes=true,intNodes=true}
local function atom(value) return #value..':'..value end
local function hex(value)
  return (value:gsub('.',function(byte) return string.format('%02x',byte:byte()) end))
end

local function sortedNodeList(value)
  local members={}
  -- The appended delimiter retains empty members, including a trailing comma.
  for member in (value..','):gmatch('(.-),') do members[#members+1]=member end
  table.sort(members)
  return table.concat(members,',')
end

local function treeLink(value)
  if not value:find('/passive-skill-tree/',1,true) then return nil end
  local prefix,encoded=value:match('^(.*)/([^/]*)$')
  if not encoded or #encoded==0 then return nil end
  encoded=encoded:gsub('-','+'):gsub('_','/')
  -- Only the complete native v6 encoding is understood. Unknown/malformed links
  -- remain literal; they must never be discarded or compared as empty trees.
  if #encoded%4~=0 or not encoded:match('^[A-Za-z0-9+/]*=?=?$') then return nil end
  local ok,raw=pcall(base64.decode,encoded)
  if not ok or raw:sub(1,4)~='\0\0\0\6' or #raw<9 then return nil end
  local parts={'U',atom(prefix),atom(hex(raw:sub(1,6)))}
  local pos=7
  for _,width in ipairs({2,2,4}) do
    local count=raw:byte(pos)
    if not count then return nil end
    pos=pos+1
    local finish=pos+count*width
    if finish-1>#raw then return nil end
    local members={}
    for i=pos,finish-1,width do members[#members+1]=hex(raw:sub(i,i+width-1)) end
    table.sort(members)
    parts[#parts+1]=tostring(count)..':'
    for _,member in ipairs(members) do parts[#parts+1]=atom(member) end
    pos=finish
  end
  if pos~=#raw+1 then return nil end
  return table.concat(parts)
end

local function sortableChildren(node)
  local root=node.elem=='PathOfBuilding2'
  if not root and node.elem~='ItemSet' and node.elem~='ConfigSet' then return false end
  local seen={}
  for _,child in ipairs(node) do
    if type(child)~='table' then return false end
    local key=atom(child.elem)
    if not root then
      local name=child.attrib and child.attrib.name
      if name==nil then return false end
      key=key..atom(name)
    end
    if seen[key] then return false end
    seen[key]=true
  end
  return true
end

local function sortCalcsInputs(node,children)
  if node.elem~='Calcs' then return end
  -- Stock CalcsTab.Save writes pairs(self.input), then ordered Section entries.
  -- Sort only that unique Input prefix; unknown layouts/repeated keys stay literal.
  local count,seen,inputs=0,{},{}
  for index,child in ipairs(node) do
    if type(child)=='table' and child.elem=='Input' then
      local name=child.attrib and child.attrib.name
      if index~=count+1 or not name or seen[name] then return end
      seen[name]=true;count=count+1;inputs[count]=children[index]
    end
  end
  table.sort(inputs)
  for index,value in ipairs(inputs) do children[index]=value end
end

local function visit(node)
  local names={}
  for name in pairs(node.attrib or {}) do names[#names+1]=name end
  table.sort(names)
  local parts={'E',atom(node.elem),'A',tostring(#names),':'}
  for _,name in ipairs(names) do
    local value=node.attrib[name]
    if nodeLists[name] then value=sortedNodeList(value) end
    parts[#parts+1]=atom(name);parts[#parts+1]=atom(value)
  end
  local children={}
  for _,child in ipairs(node) do
    if type(child)=='table' then children[#children+1]=visit(child)
    else children[#children+1]=(node.elem=='URL' and treeLink(child)) or ('S'..atom(child)) end
  end
  if sortableChildren(node) then table.sort(children) else sortCalcsInputs(node,children) end
  parts[#parts+1]='C'..#children..':'
  for _,child in ipairs(children) do parts[#parts+1]=atom(child) end
  return table.concat(parts)
end

-- Return an opaque, length-delimited canonical string, or nil plus a parse error.
-- No sections/attributes are omitted. Only the explicitly named maps are sorted.
function M.canonical(source)
  if type(source)~='string' then return nil,'Native XML source must be a string' end
  local document,err=xml.ParseXML(source)
  if not document then return nil,'Native XML parse failed: '..tostring(err) end
  if #document~=1 or type(document[1])~='table' or document[1].elem~='PathOfBuilding2' then
    return nil,'Expected one native PathOfBuilding2 document'
  end
  return visit(document[1])
end

function M.equivalent(a,b)
  local first,firstError=M.canonical(a)
  if not first then return false,firstError end
  local second,secondError=M.canonical(b)
  if not second then return false,secondError end
  return first==second
end
return M
