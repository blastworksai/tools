# Closed worker report/reply schemas, kept in step with codec.luau. The caller
# checks strict JSON, provisioned binding and exact message hashes separately.
def id: type=="string" and test("^[A-Za-z0-9_-]{1,96}\\z");
def token: type=="string" and test("^[A-Za-z0-9_-]{16,128}\\z");
def positive: type=="number" and .>=1 and .<=9007199254740991 and .==floor;
def percent: type=="number" and .>=0 and .<=100 and .==floor;
def sha: type=="string" and test("^[0-9a-f]{64}\\z");
def text($n): type=="string" and (utf8bytelength>=1) and (utf8bytelength<=$n);
def shape($required;$optional):
 type=="object" and (($required-keys)|length)==0 and ((keys-($required+$optional))|length)==0;
def fields($names): shape($names;[]);
def optional($name;check): if has($name) then .[$name]|check else true end;
def entries($minimum;$maximum;check): type=="array" and length>=$minimum and length<=$maximum and all(.[];check);
def references: entries(0;256;text(1024));
def texts: entries(0;256;text(32768));
def report_payload:
 .kind as $kind | .payload |
 if $kind=="REGISTER" then
  fields(["capabilities"]) and (.capabilities|entries(1;5;IN("report-files-v1","native-ask-v1","worker-poll-v1","argv-v1","coordinator-control-v1")) and (length==(unique|length)) and index("report-files-v1")!=null)
 elif $kind=="READY" then shape(["state"];["summary","context_used_pct"]) and .state=="idle" and optional("summary";text(1024)) and optional("context_used_pct";percent)
 elif $kind=="ACCEPTED" then fields(["assignment_sha256"]) and (.assignment_sha256|sha)
 elif $kind=="HEARTBEAT" then shape(["state"];["summary","request_id","context_used_pct"]) and (.state|IN("working","idle","waiting","blocked")) and optional("summary";text(1024)) and optional("request_id";id) and optional("context_used_pct";percent)
 elif $kind=="WAITING" then shape(["reason"];["request_id"]) and (.reason|text(1024)) and optional("request_id";id)
 elif $kind=="BLOCKED" then shape(["reason"];["evidence"]) and (.reason|text(32768)) and optional("evidence";references)
 elif $kind=="ASK" then
  shape(["question","options"];["evidence"]) and (.question|text(32768)) and optional("evidence";references) and
  (.options|entries(1;16;fields(["id","label"]) and (.id|id) and (.label|text(1024))) and ((map(.id)|unique|length)==length))
 elif $kind=="CHECKPOINT" then
  shape(["checkpoint_id","task_ref","project_id","worktree_ref","artifact_revision","completed","remaining","holds","checks"];["plan_ref","plan_revision","request_id"]) and optional("request_id";id) and
  (.checkpoint_id|id) and (.task_ref|text(1024)) and (.project_id|id) and (.worktree_ref|text(1024)) and (.artifact_revision|text(1024)) and
  (.completed|texts) and (.remaining|texts) and (.holds|texts) and
  (.checks|entries(0;256;fields(["check_id","artifact_revision","outcome","evidence_ref"]) and (.check_id|id) and (.artifact_revision|text(1024)) and (.outcome|IN("passed","failed","not_run")) and (.evidence_ref|text(1024)))) and
  (has("plan_ref")==has("plan_revision")) and optional("plan_ref";text(1024)) and optional("plan_revision";text(1024))
 elif $kind=="REVIEW_READY" then
  shape(["checkpoint_id","artifact_revision"];["summary"]) and (.checkpoint_id|id) and (.artifact_revision|text(1024)) and optional("summary";text(1024))
 elif $kind=="REVIEW_RESULT" then
  shape(["artifact_revision","outcome","evidence"];["summary"]) and (.artifact_revision|text(1024)) and (.outcome|IN("approved","changes_required")) and (.evidence|references) and optional("summary";text(1024))
 elif $kind=="DONE" then fields(["checkpoint_id","artifact_revision","summary"]) and (.checkpoint_id|id) and (.artifact_revision|text(1024)) and (.summary|text(32768))
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
  shape(["owner_id","owner_generation","activation_token","proposal_id","kind","work_id","project_id"];["checkpoint_id","record_id","record_revision","prompt"]) and
  (.owner_id|id) and (.owner_generation|positive) and (.activation_token|sha) and (.proposal_id|id) and (.work_id|id) and (.project_id|id) and
  (if .kind=="dispatch" then (has("checkpoint_id")|not) and (.record_id|text(1024)) and (.record_revision|type=="number" and .>=0 and .<=9007199254740991 and .==floor) and (.prompt|text(32768))
   else (.kind|IN("report","review","rollover","landing")) and (has("record_id")|not) and (has("record_revision")|not) and (has("prompt")|not) and
    (if .kind=="report" then has("checkpoint_id")|not else .checkpoint_id|id end) end)
 elif $kind=="COORDINATOR_RELEASE" then
  fields(["owner_id","owner_generation","activation_token","quiescent"]) and (.owner_id|id) and (.owner_generation|positive) and (.activation_token|sha) and .quiescent==true
 elif $kind=="reply_ack" then
  fields(["message_id","reply_seq","reply_sha256","status"]) and (.message_id|id) and (.reply_seq|positive) and (.reply_sha256|sha) and .status=="recorded"
 else false end;
def correlations:
 (has("action_id")==has("action_revision")) and optional("action_id";id) and optional("action_revision";positive) and
 (if .kind|IN("REVIEW_RESULT","LANDING_RESULT","reply_ack","COORDINATOR_RELEASE") then has("action_id")
  elif .kind|IN("CHECKPOINT","DONE","WAITING","BLOCKED") then true else has("action_id")|not end) and
 (has("handover_id")==has("handover_token")) and optional("handover_id";id) and optional("handover_token";token) and
 (.kind=="ACCEPTED" or (has("handover_id")|not));
def binding:
 (.logical_session_id|id) and (.worker_id|id) and (.worker_generation|positive) and (.launch_request_id|id) and (.work_id|id);
def report:
 shape(["version","logical_session_id","worker_id","worker_generation","launch_request_id","work_id","enrolment_token","event_id","seq","kind","payload"];["action_id","action_revision","handover_id","handover_token"]) and
 .version==3 and binding and (.enrolment_token|token) and (.event_id|id) and (.seq|positive) and correlations and report_payload;
def reply:
 .version==1 and binding and (.message_id|id) and (.reply_seq|positive) and (.action_id|id) and (.action_revision|positive) and
 fields(["version","logical_session_id","worker_id","worker_generation","launch_request_id","work_id","message_id","reply_seq","action_id","action_revision","kind","payload"]+(if .kind=="owner_decision" then ["gate_id","gate_revision"] else [] end)) and
 (if .kind=="assignment" then
  .payload|fields(["assignment_ref","assignment_sha256","instructions"]) and (.assignment_ref|text(1024)) and (.assignment_sha256|sha) and (.instructions|text(32768))
 elif .kind=="report_request" then
  .payload|fields(["request_id","requested_kind","reason"]) and (.request_id|id) and (.requested_kind|IN("HEARTBEAT","CHECKPOINT")) and (.reason|text(1024))
 elif .kind=="owner_decision" then
  (.gate_id|id) and (.gate_revision|positive) and (.payload|fields(["choice_id","answer"]) and (.choice_id|id) and (.answer|text(32768)))
 elif .kind=="landing_grant" then
  .payload|fields(["landing_id","grant_id","project_id","checkpoint_id","repo_ref","target_ref","target_revision","source_ref","source_revision"]) and
  (.landing_id|id) and (.grant_id|id) and (.project_id|id) and (.checkpoint_id|id) and (.repo_ref|text(1024)) and (.target_ref|text(1024)) and
  (.target_revision|text(1024)) and (.source_ref|text(1024)) and (.source_revision|text(1024))
 elif .kind=="landing_refresh" then
  .payload|fields(["landing_id","project_id","repo_ref","target_ref","expected_revision","current_revision","reason"]) and
  (.landing_id|id) and (.project_id|id) and (.repo_ref|text(1024)) and (.target_ref|text(1024)) and
  (.expected_revision|text(1024)) and (.current_revision|text(1024)) and (.reason|text(1024))
 elif .kind=="coordinator_activation" then
  .payload|fields(["owner_id","owner_generation","activation_token","instructions"]) and (.owner_id|id) and (.owner_generation|positive) and (.activation_token|sha) and (.instructions|text(32768))
 elif .kind=="coordinator_retirement" then
  .payload|fields(["owner_id","owner_generation","activation_token","reason"]) and (.owner_id|id) and (.owner_generation|positive) and (.activation_token|sha) and (.reason|text(1024))
 else false end);
if $ARGS.named.schema=="report_input" then
 shape(["kind","payload"];["action_id","action_revision","handover_id","handover_token"]) and correlations and report_payload
elif $ARGS.named.schema=="report" then report
else reply end
