-- Active view contract: explicit current/blocked state and no stale success on error.
-- CodexBWAI, COMMANDER-993.
local view = require("../lib/plan_view")
local polling = require("../lib/polling")
local ui = {
    node=function(kind,props,children) return {kind=kind,props=props,children=children} end,
    text=function(value) return {text=value} end,
    span=function(text,style) return {text=text,style=style} end,
    col=function(children) return {children=children} end,
}
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
        assert(card.main.children[2].kind=="checklist" and card.main.children[2].props.mode=="full")
        assert(item.text=="Current · Review")
        assert(item.status=="blocked")
        assert(item.note=="Owner approval required")
    end},
    {"failed source does not draw prior success",function()
        local plan={title="Old success",checkpoints={{id="cp1",text="Old work",state="done"}}}
        local row=view.draw(ui,plan,"Local","Source lost",nil).main.props.phases[1].items[1]
        assert(row.text=="Plan unavailable")
        assert(row.status=="blocked")
        assert(row.note=="Source lost")
    end},
}
