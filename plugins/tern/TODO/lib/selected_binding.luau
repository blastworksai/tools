-- Native split is the cross-namespace link; never decode a window pane handle.
-- CodexBWAI; MIT.
local binding = {}
local function integer(value)
    return type(value)=="number" and value>=1 and value<=9007199254740991 and value%1==0
end
local function sibling(tree, panel, found)
    if type(tree)~="table" then return end
    local split=tree.Split
    if type(split)~="table" then return end
    if split.axis=="Row" and type(split.b)=="table" and split.b.Leaf==panel and type(split.a)=="table" and integer(split.a.Leaf) then
        table.insert(found,split.a.Leaf)
    end
    sibling(split.a,panel,found);sibling(split.b,panel,found)
end
function binding.resolve(inventory, panel)
    if type(inventory)~="table" or type(inventory.sessions)~="table" or not integer(panel) then return nil,"Invalid native inventory" end
    local matches={}
    for _,session in inventory.sessions do
        if type(session)=="table" and type(session.tabs)=="table" then
            for _,tab in session.tabs do
                if type(tab)=="table" and type(tab.blocks)=="table" then
                    local own, blocks=0,{}
                    for _,block in tab.blocks do
                        if type(block)=="table" and integer(block.id) then
                            blocks[block.id]=block
                            if block.id==panel then own+=1 end
                        end
                    end
                    if own>0 then
                        local targets={};sibling(tab.splits,panel,targets)
                        local target=if #targets==1 then blocks[targets[1]] else nil
                        if own~=1 or not target or target.exited~=nil or target.live~=true or target.focused~=true or not integer(session.id) or not integer(tab.id) then
                            return nil,"The selected panel or its native split changed. Attach again."
                        end
                        table.insert(matches,{session=session.id,tab=tab.id,target=target.id,panel=panel})
                    end
                end
            end
        end
    end
    if #matches==0 then return nil,"pending" end
    if #matches~=1 then return nil,"The TODO panel has ambiguous native membership." end
    return matches[1],nil
end
function binding.same(a,b)
    return a~=nil and b~=nil and a.session==b.session and a.tab==b.tab and a.target==b.target and a.panel==b.panel
end
-- Window SDK layout uses safe handles, not host CLI ids. Compare only here.
function binding.windowPair(tree,target,panel)
    if type(tree)~="table" then return false end
    if tree.split=="right" and type(tree[1])=="table" and tree[1].pane==target and type(tree[2])=="table" and tree[2].pane==panel then return true end
    return binding.windowPair(tree[1],target,panel) or binding.windowPair(tree[2],target,panel)
end
return binding
