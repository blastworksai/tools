-- Active TODO view contracts in an isolated real Tern Luau VM. CodexBWAI; MIT.
local tests=require("./plan_view_test")
local passed,failures=0,{}
for _,test in tests do
    local ok,reason=pcall(test[2])
    if ok then passed+=1 else table.insert(failures,tostring(test[1])..": "..tostring(reason)) end
end
return {passed=passed,failures=failures}
