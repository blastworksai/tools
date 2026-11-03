local request=require("../lib/plan_request")
local function reply(value,id) return request.reply("TODO_PLAN_REPLY v1 "..tern.json.encode(value),id,tern.json.decode) end
return {
    {"plan replies require the current request and absolute canonical identity",function()
        assert(reply({request_id="old",state="none"},"new")==nil)
        assert(reply({request_id="new",state="active",path="relative.md",plan_id="plan-abcdef"},"new")==nil)
        assert(reply({request_id="new",state="active",path="/plan.md"},"new")==nil)
        local value=reply({request_id="new",state="active",path="C:\\Plans\\Current.md",plan_id="plan-abcdef"},"new")
        assert(value and value.path=="C:\\Plans\\Current.md")
    end},
    {"an explicit no-plan reply differs from unsupported, echoed prompt and malformed text",function()
        assert(reply({request_id="new",state="none"},"new").state=="none")
        assert(reply({request_id="new",state="unsupported"},"new").state=="unsupported")
        assert(request.reply("# Query: reply TODO_PLAN_REPLY v1 followed by JSON", "new", tern.json.decode)==nil)
        assert(request.reply("TODO_PLAN_REPLY v1 {broken}","new",tern.json.decode)==nil)
    end},
}
