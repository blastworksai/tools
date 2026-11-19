# Generated from shared/report-files-v1 by sync.py; edit the canonical source.
# Closed worker report/reply schemas, kept in step with wire/codec.luau. The caller
# checks strict JSON, provisioned binding and exact message hashes separately.
def id: type=="string" and test("^[A-Za-z0-9_-]{1,96}\\z");
def token: type=="string" and test("^[A-Za-z0-9_-]{16,128}\\z");
def positive: type=="number" and .>=1 and .<=9007199254740991 and .==floor;
def percent: type=="number" and .>=0 and .<=100 and .==floor;
def sha: type=="string" and test("^[0-9a-f]{64}\\z");
def text($n): type=="string" and (utf8bytelength>=1) and (utf8bytelength<=$n);
# Explain mode (--arg explain 1, run only after a refusal) evaluates the same rules but raises
# "<field path>: <rule>" at the first one that fails, so the sender learns which field broke.
# Without it every rule below is the plain boolean it always was.
def explain: $ARGS.named.explain=="1";
# A sentence (raised as ": ...") or an index joins without a dot; a field name joins with one.
def under($path): if startswith("[") or startswith(": ") then $path+. else $path+"."+. end;
def at($name;check;$rule):
 if explain then (try (.[$name]|check) catch error(under($name))) as $ok | if $ok then true else error($name+": "+$rule) end
 else .[$name]|check end;
def rule(condition;$message): condition as $ok | if $ok or (explain|not) then $ok else error(": "+$message) end;
def shape($required;$optional):
 if explain then
  if type!="object" then error(": must be an object")
  else ($required-keys) as $missing | (keys-($required+$optional)) as $extra |
   if ($missing|length)>0 then error(": missing field "+$missing[0]) elif ($extra|length)>0 then error(": unknown field "+$extra[0]) else true end end
 else type=="object" and (($required-keys)|length)==0 and ((keys-($required+$optional))|length)==0 end;
def fields($names): shape($names;[]);
def optional($name;check): if has($name) then at($name;check;"invalid value") else true end;
def optional($name;check;$rule): if has($name) then at($name;check;$rule) else true end;
def entries($minimum;$maximum;check):
 if explain then
  if type!="array" then error(": must be a list")
  elif length<$minimum or length>$maximum then error(": must hold \($minimum) to \($maximum) entries, has \(length)")
  else . as $list | all(range(0;$list|length); . as $i |
   (try ($list[$i]|check) catch error("[\($i)]"+(if startswith("[") or startswith(": ") then . else "."+. end))) as $ok |
   if $ok then true else error("[\($i)]: invalid entry") end) end
 else type=="array" and length>=$minimum and length<=$maximum and all(.[];check) end;
def references: entries(0;256;text(1024));
def texts: entries(0;256;text(32768));
def nonnegative: type=="number" and .>=0 and .<=9007199254740991 and .==floor;
def context_snapshot:
 shape(["current_tokens","window_tokens","observed_at_ms"];["first_turn_tokens"]) and
 (.current_tokens|nonnegative) and (.window_tokens|positive) and (.observed_at_ms|nonnegative) and
 .current_tokens<=.window_tokens and optional("first_turn_tokens";nonnegative) and
 ((has("first_turn_tokens")|not) or .first_turn_tokens<=.window_tokens);
def measured:
 optional("context_used_pct";percent) and optional("context_snapshot";context_snapshot) and
 ((has("context_used_pct") and has("context_snapshot"))|not);
def exit_code: type=="number" and .>=-2147483648 and .<=4294967295 and .==floor;
def absolute: text(4096) and test("^(/|[A-Za-z]:[/\\\\]|\\\\\\\\)");
def class: type=="string" and test("^[a-z][a-z0-9-]{0,31}\\z");
def family: type=="string" and test("^[a-z][a-z0-9-]{0,23}\\z");
def revision: type=="string" and test("^[0-9a-f]{40}([0-9a-f]{24})?\\z");
def relative_path($n): text($n) and (startswith("/")|not) and (test("\\\\|^[A-Za-z]:|(^|/)\\.\\.(/|\\z)")|not);
def finding: shape(["finding_id","path","summary"];["line"]) and (.finding_id|id) and (.path|text(1024)) and optional("line";positive) and (.summary|text(400));
def findings: entries(0;32;finding) and ((map(.finding_id)|unique|length)==length);
def bounded($n): text($n) and (contains("\u0000")|not);
def nonblank($n): bounded($n) and test("[^ \t\r\n\u000b\u000c]");
def project_choice:
 rule(has("orch_project_id")!=has("new_project_name");"give exactly one of orch_project_id or new_project_name") and
 optional("orch_project_id";id) and optional("new_project_name";nonblank(160));
def template_fields:
 type=="object" and length<=16 and all(to_entries[];
  (.key|class and .!="input") and (.value|type=="string" and utf8bytelength<=2048 and (contains("\u0000")|not)));
def proposed_source:
 if .kind|IN("plan_file","board") then
  fields(["kind","path","revision"]) and (.path|absolute and bounded(4096)) and (.revision|nonblank(1024))
 else shape(["kind","template_id","revision","input"];["custom_fields"]) and .kind=="template" and (.template_id|id) and (.revision|nonblank(1024)) and (.input|nonblank(32768)) and optional("custom_fields";template_fields) end;
def project_start:
 fields(["owner_id","owner_generation","activation_token","orch_project_id","project_revision","decision_context"]) and
 (.owner_id|id) and (.owner_generation|positive) and (.activation_token|sha) and
 (.orch_project_id|id) and (.project_revision|positive) and (.decision_context|sha);
def report_payload:
 .kind as $kind | at("payload";
 if $kind=="REGISTER" then
  fields(["capabilities"]) and (.capabilities|entries(1;8;IN("report-files-v1","native-ask-v1","worker-poll-v1","argv-v1","coordinator-control-v1","project-start-v1","check-runner-v1","release-manager-v1")) and (length==(unique|length)) and index("report-files-v1")!=null)
 elif $kind=="READY" then shape(["state"];["summary","context_used_pct","context_snapshot"]) and .state=="idle" and optional("summary";text(1024)) and measured
 elif $kind=="ACCEPTED" then fields(["assignment_sha256"]) and (.assignment_sha256|sha)
 elif $kind=="HEARTBEAT" then shape(["state"];["summary","request_id","context_used_pct","context_snapshot"]) and (.state|IN("working","idle","waiting","blocked")) and optional("summary";text(1024)) and optional("request_id";id) and measured
 elif $kind=="WAITING" then shape(["reason"];["request_id"]) and (.reason|text(1024)) and optional("request_id";id)
 elif $kind=="BLOCKED" then shape(["reason"];["evidence"]) and (.reason|text(32768)) and optional("evidence";references)
 elif $kind=="ASK" then
  shape(["question","options"];["evidence"]) and (.question|text(32768)) and optional("evidence";references) and
  (.options|entries(1;16;fields(["id","label"]) and (.id|id) and (.label|text(1024))) and ((map(.id)|unique|length)==length))
 elif $kind=="CHECKPOINT" then
  shape(["checkpoint_id","task_ref","project_id","worktree_ref","artifact_revision","completed","remaining","holds","checks"];["plan_ref","plan_revision","request_id","context_used_pct","context_snapshot"]) and optional("request_id";id) and measured and
  (.checkpoint_id|id) and (.task_ref|text(1024)) and (.project_id|id) and (.worktree_ref|text(1024)) and (.artifact_revision|text(1024)) and
  (.completed|texts) and (.remaining|texts) and (.holds|texts) and
  (.checks|entries(0;256;fields(["check_id","artifact_revision","outcome","evidence_ref"]) and (.check_id|id) and (.artifact_revision|text(1024)) and (.outcome|IN("passed","failed","not_run")) and (.evidence_ref|text(1024)))) and
  (has("plan_ref")==has("plan_revision")) and optional("plan_ref";text(1024)) and optional("plan_revision";text(1024))
 elif $kind=="REVIEW_READY" then
  shape(["checkpoint_id","artifact_revision"];["summary"]) and (.checkpoint_id|id) and (.artifact_revision|text(1024)) and optional("summary";text(1024))
 elif $kind=="REVIEW_RESULT" then
  shape(["review_id","round","artifact_revision","outcome","findings"];["summary"]) and (.review_id|id) and (.round|positive) and (.artifact_revision|text(1024)) and
  (.outcome|IN("approved","changes_required")) and (.findings|findings) and optional("summary";text(1024))
 elif $kind=="DONE" then shape(["checkpoint_id","artifact_revision","summary"];["output_ref"]) and (.checkpoint_id|id) and (.artifact_revision|text(1024)) and (.summary|text(32768)) and optional("output_ref";relative_path(256))
 elif $kind=="CHECK_RESULT" then
  fields(["check_id","argv_sha256","exit_code","output_sha256","head","ran_at_ms"]) and (.check_id|id) and (.argv_sha256|sha) and
  (.exit_code|exit_code) and (.output_sha256|sha) and (.head|revision) and (.ran_at_ms|nonnegative)
 elif $kind=="CHECKOUT" then
  shape(["worktree_path","common_dir","branch","head","changed_files","changed_overflow","changed_total","dirty"];["base"]) and
  (.worktree_path|absolute) and (.common_dir|absolute) and (.branch|text(256)) and (.head|revision) and optional("base";revision) and
  (.changed_files|entries(0;512;text(4096) and (contains("\u0000")|not)) and length==(unique|length)) and (.changed_overflow|type=="boolean") and (.changed_total|nonnegative) and (.dirty|type=="boolean") and
  .changed_total>=(.changed_files|length) and .changed_overflow==(.changed_total>(.changed_files|length))
 elif $kind=="LABEL" then shape(["work_ref","class"];["reason"]) and (.work_ref|text(1024)) and (.class|class) and optional("reason";text(1024))
 elif $kind=="DEPLOY_RESULT" then
  shape(["deploy_id","attempt_id","landing_id","outcome","revision","evidence"];["reason"]) and (.deploy_id|id) and (.attempt_id|id) and (.landing_id|id) and
  (.outcome|IN("deployed","held","not_applicable","failed")) and (.revision|text(1024)) and (.evidence|entries(0;16;text(1024))) and optional("reason";text(1024))
 elif $kind=="ROLLOVER_REQUEST" then fields(["checkpoint_id","reason"]) and (.checkpoint_id|id) and (.reason|text(1024))
 elif $kind=="LANDING_REQUEST" then
  shape(["checkpoint_id","project_id","repo_ref","target_ref","target_revision","source_ref","source_revision"];["summary"]) and
  (.checkpoint_id|id) and (.project_id|id) and (.repo_ref|text(1024)) and (.target_ref|text(1024)) and (.target_revision|text(1024)) and
  (.source_ref|text(1024)) and (.source_revision|text(1024)) and optional("summary";text(1024))
 elif $kind=="LANDING_RESULT" then
  shape(["landing_id","grant_id","project_id","repo_ref","target_ref","target_revision","source_revision","outcome","evidence"];["result_revision","observed_target_revision","reason","pr_ref","summary"]) and
  (.landing_id|id) and (.grant_id|id) and (.project_id|id) and (.repo_ref|text(1024)) and (.target_ref|text(1024)) and (.target_revision|text(1024)) and
  (.source_revision|text(1024)) and (.outcome|IN("landed","rejected","stale_target","uncertain")) and (.evidence|references) and
  optional("result_revision";text(1024)) and optional("observed_target_revision";text(1024)) and optional("reason";text(1024)) and
  optional("pr_ref";text(1024)) and optional("summary";text(1024)) and
  ((.outcome=="landed")==has("result_revision")) and ((.outcome=="stale_target")==has("observed_target_revision")) and
  (.outcome!="stale_target" or .observed_target_revision!=.target_revision) and
  (if .outcome=="landed" then has("reason")|not elif .outcome=="stale_target" then true else has("reason") end)
 elif $kind=="COORDINATOR_PROPOSAL" then
  rule(type=="object";"must be an object") and
  at("owner_id";id;"copy owner_id verbatim from coordinator activation") and at("owner_generation";positive;"whole number from 1") and
  at("activation_token";sha;"64 lowercase hex characters from coordinator activation") and at("proposal_id";id;"1-96 of A-Z a-z 0-9 _ -") and
  (if .kind=="new_work" then
   shape(["owner_id","owner_generation","activation_token","proposal_id","kind","record_id","record_revision","prompt","scope","checks"];["orch_project_id","new_project_name","base_ref","repository_id","target_ref","target_revision"]) and project_choice and
   at("record_id";text(1024);"1-1024 bytes, from the eligible records list") and at("record_revision";nonnegative;"whole number from 0") and
   at("prompt";nonblank(32768);"non-blank text up to 32768 bytes") and
   at("scope";fields(["paths","systems"]) and at("paths";entries(0;64;bounded(256));"up to 64 paths of at most 256 bytes") and
    at("systems";entries(0;16;bounded(80));"up to 16 systems of at most 80 bytes");"{paths,systems}") and
   at("checks";entries(0;16;fields(["check_id","argv"]) and at("check_id";id;"1-96 of A-Z a-z 0-9 _ -") and
    at("argv";entries(1;16;bounded(512));"1 to 16 arguments of at most 512 bytes")) and
    rule((map(.check_id)|unique|length)==length;"check_id values must be unique");"up to 16 checks") and
   optional("base_ref";bounded(256);"text of 1 to 256 bytes") and optional("repository_id";id;"1-96 of A-Z a-z 0-9 _ -") and
   optional("target_ref";bounded(256);"text of 1 to 256 bytes") and optional("target_revision";revision;"40 or 64 lowercase hex characters") and
   rule(has("target_ref")==has("target_revision");"target_ref and target_revision go together") and
   rule((has("target_ref")|not) or has("repository_id");"target_ref needs repository_id")
  elif .kind=="add_source" then
   shape(["owner_id","owner_generation","activation_token","proposal_id","kind","source"];["orch_project_id","new_project_name"]) and project_choice and
   at("source";proposed_source;"{kind=plan_file|board,path,revision} or {kind=template,template_id,revision,input}")
  else
   rule(.kind|IN("dispatch","report","review","rollover","landing");"kind must be new_work, add_source, dispatch, report, review, rollover or landing") and
   shape(["owner_id","owner_generation","activation_token","proposal_id","kind","work_id","project_id"];["checkpoint_id","record_id","record_revision","prompt"]) and at("work_id";id;"1-96 of A-Z a-z 0-9 _ -") and at("project_id";id;"1-96 of A-Z a-z 0-9 _ -") and
   (if .kind=="dispatch" then (has("checkpoint_id")|not) and (.record_id|text(1024)) and (.record_revision|nonnegative) and (.prompt|text(32768))
    else (.kind|IN("report","review","rollover","landing")) and (has("record_id")|not) and (has("record_revision")|not) and (has("prompt")|not) and
     (if .kind=="report" then has("checkpoint_id")|not else .checkpoint_id|id end) end)
  end)
 elif $kind=="PROJECT_START_CLAIM" then project_start
 elif $kind=="COORDINATOR_RELEASE" then
  fields(["owner_id","owner_generation","activation_token","quiescent"]) and (.owner_id|id) and (.owner_generation|positive) and (.activation_token|sha) and .quiescent==true
 elif $kind=="reply_ack" then
  fields(["message_id","reply_seq","reply_sha256","status"]) and (.message_id|id) and (.reply_seq|positive) and (.reply_sha256|sha) and .status=="recorded"
 else false end;"invalid payload for this kind");
def correlations:
 rule(has("action_id")==has("action_revision");"action_id and action_revision go together") and optional("action_id";id) and optional("action_revision";positive) and
 (if .kind|IN("REVIEW_RESULT","LANDING_RESULT","LABEL","DEPLOY_RESULT","reply_ack","COORDINATOR_RELEASE","PROJECT_START_CLAIM") then rule(has("action_id");"this kind needs the issued action_id and action_revision")
  elif .kind|IN("CHECKPOINT","DONE","WAITING","BLOCKED") then true else rule(has("action_id")|not;"this kind takes no action_id or action_revision") end) and
 (has("handover_id")==has("handover_token")) and optional("handover_id";id) and optional("handover_token";token) and
 (.kind=="ACCEPTED" or (has("handover_id")|not));
def binding:
 (.logical_session_id|id) and (.worker_id|id) and (.worker_generation|positive) and (.launch_request_id|id) and (.work_id|id);
def report:
 shape(["version","logical_session_id","worker_id","worker_generation","launch_request_id","work_id","enrolment_token","event_id","seq","kind","payload"];["action_id","action_revision","handover_id","handover_token"]) and
 .version==3 and binding and (.enrolment_token|token) and (.event_id|id) and (.seq|positive) and correlations and report_payload;
def reply:
 .version==1 and binding and (.message_id|id) and (.reply_seq|positive) and (.action_id|id) and (.action_revision|positive) and
 fields(["version","logical_session_id","worker_id","worker_generation","launch_request_id","work_id","message_id","reply_seq","action_id","action_revision","kind","payload"]+(if .kind|IN("owner_decision","record_ruling") then ["gate_id","gate_revision"] else [] end)) and
 (if .kind=="assignment" then
  .payload|fields(["assignment_ref","assignment_sha256","instructions"]) and (.assignment_ref|text(1024)) and (.assignment_sha256|sha) and (.instructions|text(32768))
 elif .kind=="report_request" then
  .payload|fields(["request_id","requested_kind","reason"]) and (.request_id|id) and (.requested_kind|IN("HEARTBEAT","CHECKPOINT")) and (.reason|text(1024))
 elif .kind=="owner_decision" then
  (.gate_id|id) and (.gate_revision|positive) and (.payload|fields(["choice_id","answer"]) and (.choice_id|id) and (.answer|text(32768)))
 elif .kind=="record_ruling" then
  (.gate_id|id) and (.gate_revision|positive) and
  (.payload|fields(["path","marker","entry","expected_document_sha256","expected_non_rulings_sha256"]) and
   (.path|absolute and (test("\\x00")|not)) and
   (.marker|text(256) and test("^orchplus-ruling:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\\z")) and
   (.entry|text(8192) and (test("[\\r\\x00]")|not) and (endswith("\n")|not) and
    (split("\n")|all(.[];startswith("> ") and (.[2:]|test("[<>`]")|not)))) and
   (.expected_document_sha256|sha) and (.expected_non_rulings_sha256|sha)) and
  ((.payload.marker|split(":")|last)==.gate_id)
 elif .kind=="landing_grant" then
  .payload|shape(["landing_id","grant_id","project_id","checkpoint_id","repo_ref","target_ref","target_revision","source_ref","source_revision","builder_work_id","proof"];["review_id","reviewer_family"]) and
  (.landing_id|id) and (.grant_id|id) and (.project_id|id) and (.checkpoint_id|id) and (.repo_ref|text(1024)) and (.target_ref|text(1024)) and
  (.target_revision|text(1024)) and (.source_ref|text(1024)) and (.source_revision|text(1024)) and
  (.builder_work_id|id) and optional("review_id";id) and optional("reviewer_family";family) and
  (.proof|shape(["mode","artifact_revision","check_refs"];["review_id"]) and (.mode|IN("cross_family_review","helper_checks","review_disabled")) and (.artifact_revision|text(1024)) and optional("review_id";id) and (.check_refs|entries(0;16;text(1024)))) and
  (if .proof.mode=="review_disabled" then (has("review_id")|not) and (has("reviewer_family")|not) and (.proof|has("review_id")|not)
   else has("review_id") and has("reviewer_family") and (.proof.review_id==.review_id) end)
 elif .kind=="review_request" then
  .payload|shape(["review_id","round","question_id","builder_work_id","task_ref","source_ref","artifact_revision","scope_paths","findings_prev"];["plan_ref","plan_revision"]) and
  (.review_id|id) and (.round|positive) and .question_id=="implements_task_v1" and (.builder_work_id|id) and (.task_ref|text(1024)) and
  (.source_ref|text(1024)) and (.artifact_revision|text(1024)) and (.scope_paths|entries(0;64;text(256))) and (.findings_prev|findings) and
  (has("plan_ref")==has("plan_revision")) and optional("plan_ref";text(1024)) and optional("plan_revision";text(1024))
 elif .kind=="rework" then
  .payload|shape(["round","artifact_revision","failed_checks","findings"];["review_id"]) and optional("review_id";id) and (.round|positive) and (.artifact_revision|text(1024)) and
  (.failed_checks|entries(0;16;fields(["check_id","exit_code"]) and (.check_id|id) and (.exit_code|exit_code))) and (.findings|findings)
 elif .kind=="deploy_grant" then
  .payload|fields(["deploy_id","attempt_id","landing_id","revision","target_ref"]) and (.deploy_id|id) and (.attempt_id|id) and (.landing_id|id) and (.revision|text(1024)) and (.target_ref|text(1024))
 elif .kind=="label_request" then
  .payload|fields(["work_ref","classes","text"]) and (.work_ref|text(1024)) and (.classes|entries(1;32;class) and (length==(unique|length))) and (.text|text(32768))
 elif .kind=="landing_refresh" then
  .payload|fields(["landing_id","project_id","repo_ref","target_ref","expected_revision","current_revision","reason"]) and
  (.landing_id|id) and (.project_id|id) and (.repo_ref|text(1024)) and (.target_ref|text(1024)) and
  (.expected_revision|text(1024)) and (.current_revision|text(1024)) and (.reason|text(1024))
 elif .kind=="project_start" then .payload|project_start
 elif .kind=="coordinator_activation" then
  .payload|fields(["owner_id","owner_generation","activation_token","instructions"]) and (.owner_id|id) and (.owner_generation|positive) and (.activation_token|sha) and (.instructions|text(32768))
 elif .kind=="coordinator_retirement" then
  .payload|fields(["owner_id","owner_generation","activation_token","reason"]) and (.owner_id|id) and (.owner_generation|positive) and (.activation_token|sha) and (.reason|text(1024))
 else false end);
try (
if $ARGS.named.schema=="report_input" then
 shape(["kind","payload"];["action_id","action_revision","handover_id","handover_token"]) and correlations and report_payload
elif $ARGS.named.schema=="report" then report
else reply end
) catch (if explain and type=="string" then error(ltrimstr(": ")) else error end)
