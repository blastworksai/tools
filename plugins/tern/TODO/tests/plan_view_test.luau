-- Active view contract: explicit current/blocked state and no stale success on error.
-- CodexBWAI, COMMANDER-993.
local view = require("../lib/plan_view")
local polling = require("../lib/polling")
local ui = {
    node=function(kind,props,children) return {kind=kind,props=props,children=children} end,
    text=function(value) return {text=value} end,
    span=function(text,style) return {text=text,style=style} end,
    col=function(children) return {children=children} end,
    section=function(head,children) return {head=head,children=children} end,
}
local function detailed(tweak)
    local p={schema=2,plan_id="plan-0123456789ab",title="Detailed",current="impl",checkpoints={
        {id="model",text="Model",state="done",tasks={{id="parse",text="Parser",state="done",items={
            {id="parse-file",kind="file",path="bin/todo.py",text="Edit validate",state="done"},
            {id="parse-step",kind="step",text="Nest ids",state="done"},
            {id="parse-check",kind="validation",text="Tests pass",state="done"}}}}},
        {id="ui",text="UI",state="pending",tasks={{id="impl",text="Implement",state="active",items={
            {id="impl-file",kind="file",path="window.luau",text="Segment",state="pending"},
            {id="impl-wait",kind="step",text="Owner choice",state="blocked",reason="Waiting for owner"}}}}},
        {id="ship",text="Ship",state="pending"}}}
    if tweak then tweak(p) end
    return p
end
-- Every checklist row of a drawn view, by stable id; fails on a duplicate id.
local function rows(card)
    local seen,order={},{}
    local function visit(node)
        for _,phase in (node.props and node.props.phases) or {} do
            for _,item in phase.items do
                assert(seen[item.id]==nil,"duplicate row "..item.id)
                seen[item.id]=item; table.insert(order,item.id)
            end
        end
        for _,child in node.children or {} do visit(child) end
    end
    for _,child in card.main.children do visit(child) end
    return seen,order
end
return {
    {"SSH errors back off without penalizing local or recovered sources",function()
        assert(polling.delay(false, 20) == 1500 and polling.delay(true, 0) == 15000)
        assert(polling.delay(true, 1) >= 60000 and polling.delay(true, 2) > polling.delay(true, 1))
        assert(polling.delay(true, 1000) == 300000 and polling.delay(true, 0) == 15000)
    end},
    {"current blocked checkpoint remains visible",function()
        local plan={title="Task",current="cp1",checkpoints={{id="cp1",text="Review",state="blocked",reason="Owner approval required"}}}
        local card=view.draw(ui,plan,"Local",nil,"now")
        local item=card.main.children[2].props.phases[1].items[1]
        assert(item.text=="Current · Review")
        assert(item.status=="blocked")
        assert(item.note=="Owner approval required")
    end},
    {"parallel builders: several active entities are valid and all draw as active",function()
        local plan=detailed(function(p)
            p.checkpoints[2].tasks[1].items[1].state="active"
            p.checkpoints[3].state="active"
        end)
        assert(view.validate(plan)==nil,tostring(view.validate(plan)))
        local seen=rows(view.draw(ui,plan,"Local",nil,"now"))
        assert(seen["impl"].status=="active" and seen["impl-file"].status=="active" and seen["ship"].status=="active")
        assert(seen["impl"].text:find("Current · ",1,true)==1 and seen["ship"].text:find("Current",1,true)==nil)
        plan.current=nil
        assert(view.validate(plan)==nil,"current may be null while entities are active")
        plan.current="parse"
        assert(view.validate(plan)~=nil,"current naming a done entity is refused")
        plan.current="ghost"
        assert(view.validate(plan)~=nil,"current naming an unknown id is refused")
    end},
    {"failed source does not draw prior success",function()
        local plan={title="Old success",checkpoints={{id="cp1",text="Old work",state="done"}}}
        local region=view.draw(ui,plan,"Local","Source lost",nil).main
        local visible={}
        local function visit(node)
            for _,phase in (node.props and node.props.phases) or {} do
                for _,item in phase.items do visible[item.id]=item end
            end
            for _,child in node.children or {} do visit(child) end
        end
        -- Block region roots are not drawn; only their children reach the UI.
        for _,child in region.children or {} do visit(child) end
        assert(visible.error and visible.error.status=="blocked")
        assert(visible.error.note=="Source lost")
        assert(visible.cp1==nil, "Failed source retained an old success checkpoint")
    end},
    {"detailed plan renders every entity once, in plan order, by stable id",function()
        local seen,order=rows(view.draw(ui,detailed(),"Local",nil,"now"))
        local want={"model","parse","parse-file","parse-step","parse-check","ui","impl","impl-file","impl-wait","ship"}
        assert(#order==#want,#order)
        for i,id in want do assert(order[i]==id,order[i]..":"..id) end
        assert(seen["parse-file"].status=="done" and seen["impl"].status=="active" and seen["impl-wait"].status=="blocked" and seen["impl-file"].status=="pending")
    end},
    {"hierarchy keeps ownership: tasks and items sit under their checkpoint's group, current and reasons show",function()
        local card=view.draw(ui,detailed(),"Local",nil,"now")
        local groups={}
        for _,child in card.main.children do if child.head then table.insert(groups,child) end end
        assert(#groups==3 and groups[2].head[1].text=="UI")
        local items=groups[2].children[1].props.phases[1].items
        assert(#items==4 and items[1].id=="ui" and items[2].id=="impl" and items[3].id=="impl-file")
        assert(items[2].text:find("Current · ",1,true)==1 and items[3].text:find("File · Segment",1,true))
        assert(items[3].note=="window.luau" and items[4].note=="Waiting for owner")
        local progress=card.main.children[1].text
        assert(progress[1].text:find("Checkpoints 1/3",1,true) and progress[1].text:find("Tasks 1/2",1,true) and progress[1].text:find("Files 1/2",1,true) and progress[1].text:find("Checks 1/1",1,true))
    end},
    {"rename and reorder update rows in place: same ids, no stale or duplicate rows",function()
        local _,before=rows(view.draw(ui,detailed(),"L",nil,"t"))
        local renamed=detailed(function(p) p.checkpoints[2].tasks[1].text="Implement v2" end)
        local seen,after=rows(view.draw(ui,renamed,"L",nil,"t"))
        assert(#after==#before and seen["impl"].text:find("Implement v2",1,true))
        local reordered=detailed(function(p) local i=p.checkpoints[2].tasks[1].items; i[1],i[2]=i[2],i[1] end)
        local _,order=rows(view.draw(ui,reordered,"L",nil,"t"))
        assert(#order==#before and order[8]=="impl-wait" and order[9]=="impl-file")
        local removed=detailed(function(p) table.remove(p.checkpoints[2].tasks[1].items,1) end)
        local gone=rows(view.draw(ui,removed,"L",nil,"t"))
        assert(gone["impl-file"]==nil)
    end},
    {"a failed read never leaves the detailed plan on screen",function()
        local seen=rows(view.draw(ui,detailed(),"L","Source lost",nil))
        assert(seen.error and seen.error.note=="Source lost" and seen.model==nil and seen["parse-file"]==nil)
    end},
    {"validate accepts schema 1 and 2 and every kind and state",function()
        assert(view.validate(detailed())==nil)
        local legacy={schema=1,plan_id="plan-4d31a4dc1f2e",title="Old",checkpoints={{id="a",text="A",state="pending"},{id="b",text="B",state="blocked",reason="r"}},current="b"}
        assert(view.validate(legacy)==nil)
        assert(view.validate({schema=1,plan_id="plan-123456abcdef",title="T",current=false,checkpoints={}})~=nil)
    end},
    {"validate refuses duplicates, bad states, bad nesting, multiple active, unreasoned blocks, unknown fields",function()
        local function bad(tweak,why) local r=view.validate(detailed(tweak)); assert(r~=nil,why) end
        bad(function(p) p.checkpoints[3].id="parse" end,"duplicate id across levels")
        bad(function(p) p.checkpoints[1].tasks[1].state="finished" end,"state")
        bad(function(p) p.checkpoints[1].tasks[1].items[1].kind="note" end,"kind")
        bad(function(p) p.checkpoints[1].tasks[1].items[2].path="x" end,"path on a step")
        bad(function(p) p.checkpoints[1].tasks[1].items[1].path=nil end,"file without path")
        bad(function(p) p.checkpoints[1].tasks[1].items[1].items={} end,"item children")
        bad(function(p) p.checkpoints[1].tasks[1].tasks={} end,"task children")
        bad(function(p) p.checkpoints[2].tasks[1].items[2].reason=nil end,"blocked without reason")
        bad(function(p) p.checkpoints[2].tasks[1].items[1].reason="x" end,"reason without block")
        bad(function(p) p.current="ship" end,"current names a pending entity")
        bad(function(p) p.current="model" end,"current names a done entity")
        bad(function(p) p.extra=1 end,"unknown top-level field")
        bad(function(p) p.schema=3 end,"schema")
        bad(function(p) p.plan_id="plan-xyz" end,"plan id")
        bad(function(p) p.checkpoints[1].text=string.rep("x",241) end,"long text")
        bad(function(p) p.checkpoints[1].tasks[1].items[1].path=string.rep("x",241) end,"long path")
        bad(function(p) local t={} for i=1,21 do t[i]={id="t"..i,text="t",state="pending"} end p.checkpoints[3].tasks=t end,"task count")
    end},
    {"validate counts characters, not bytes, and caps total entities",function()
        assert(view.validate(detailed(function(p) p.checkpoints[3].text=string.rep("\u{1F600}",240) end))==nil)
        -- Python str.strip() removes Unicode whitespace: edge U+00A0/U+3000/U+2003 must not count as content.
        local nb="\u{00A0}"
        assert(view.validate(detailed(function(p) p.checkpoints[3].text=nb..string.rep("a",240)..nb end))==nil)
        assert(view.validate(detailed(function(p) p.checkpoints[3].text="\u{3000}\u{2003}"..string.rep("a",240).."\u{2028}" end))==nil)
        assert(view.validate(detailed(function(p) p.checkpoints[3].text=nb..string.rep("a",241)..nb end))~=nil)
        assert(view.validate(detailed(function(p) p.checkpoints[3].text=nb..nb end))~=nil)
        assert(view.validate(detailed(function(p) p.checkpoints[3].text=string.rep("\u{1F600}",241) end))~=nil)
        local p=detailed(function(p) p.checkpoints={} for c=1,30 do local t={} for i=1,20 do t[i]={id="t"..c.."x"..i,text="t",state="pending"} end p.checkpoints[c]={id="c"..c,text="c",state="pending",tasks=t} end p.current=nil end)
        assert(view.validate(p)~=nil)
    end},
    {"ids that look like the validator's own bookkeeping ('count', 'seen') are valid and render",function()
        local legacy={schema=1,plan_id="plan-4d31a4dc1f2e",title="Old",current="count",checkpoints={{id="count",text="Count",state="blocked",reason="r"},{id="seen",text="Seen",state="pending"}}}
        assert(view.validate(legacy)==nil,view.validate(legacy))
        local seen=rows(view.draw(ui,legacy,"L",nil,"t"))
        assert(seen.count~=nil and seen.seen~=nil)
        legacy.checkpoints[2].id="count"
        assert(view.validate(legacy)~=nil,"a real duplicate is still refused")
    end},
}
