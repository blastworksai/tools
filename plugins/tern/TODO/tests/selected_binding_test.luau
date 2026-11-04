local binding=require("../lib/selected_binding")
local function inventory()
    return {sessions={{id=1,tabs={{id=2,blocks={{id=10,live=true,focused=true},{id=11,live=true,focused=false}},splits={Split={axis="Row",a={Leaf=10},b={Leaf=11}}}}}}}}
end
return {
    {"native host split resolves independently of client-side pane handles",function()
        local found=binding.resolve(inventory(),11)
        assert(found.target==10 and found.session==1 and found.tab==2)
        assert(binding.windowPair({split="right",{pane=4500000000000001},{pane=4500000000000002}},4500000000000001,4500000000000002))
    end},
    {"moved, closed, unfocused and ambiguous native targets fail closed",function()
        local d=inventory();d.sessions[1].tabs[1].splits.Split.a={Split={axis="Row",a={Leaf=10},b={Leaf=12}}}
        assert(binding.resolve(d,11)==nil)
        d=inventory();d.sessions[1].tabs[1].blocks[1].exited=0;assert(binding.resolve(d,11)==nil)
        d=inventory();d.sessions[1].tabs[1].blocks[1].focused=false;assert(binding.resolve(d,11)==nil)
        d=inventory();table.insert(d.sessions,d.sessions[1]);assert(binding.resolve(d,11)==nil)
        assert(not binding.windowPair({split="down",{pane=10},{pane=11}},10,11))
    end},
    {"native fences reject a different target without comparing mutable labels",function()
        local a=binding.resolve(inventory(),11)
        local d=inventory();d.sessions[1].tabs[1].blocks[1].id=12;d.sessions[1].tabs[1].splits.Split.a.Leaf=12
        local b=binding.resolve(d,11);assert(not binding.same(a,b))
    end},
}
