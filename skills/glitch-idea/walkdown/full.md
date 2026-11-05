# glitch-idea-tools: full report

skills/glitch-idea | retrieved 2026-11-05 | sha256 cfec54fcd4b7ec29585a3f6b649cccf1a22a1d1b3b49e4faddf7e09e003c4023
Run 2026-11-05_cfec54f | Walkdown 0.3.1+blastworks.1
Static examination only. Nothing executed. Every finding below is a location to look at; none is a verdict. Stage order; nothing is ranked.

## 1 What ships

280 files, 17 formats, 2 script languages. 0 hooks (0 host configs). 0 agent or command definitions. 0 platform manifests.

Validation: PASS (gate 26/26, negative 7/7; measured 2026-11-02, same code and fixtures)

Pin: sha256 cfec54fcd4b7ec29585a3f6b649cccf1a22a1d1b3b49e4faddf7e09e003c4023, 280 files, 6,081,545 bytes.

Formats: py 149, md 53, mjs 36, js 11, png 9, json 5, txt 3, woff2 3, (none) 2, css 2, gitignore 1, gitkeep 1, html 1, luau 1, svg 1, toml 1, yaml 1.

Script languages: JavaScript: glitch-idea/web/api.js, glitch-idea/web/app.js, glitch-idea/web/folds.js, glitch-idea/web/ideas.js, glitch-idea/web/setup.js, glitch-idea/web/steps/assess.js, glitch-idea/web/steps/discovery.js, glitch-idea/web/steps/exploration.js, glitch-idea/web/steps/method.js, glitch-idea/web/steps/review.js, glitch-idea/web/steps/visualize.js, tests/browser_flow_smoke.mjs, tests/web/accept-reasons.test.mjs, tests/web/app-render.test.mjs, tests/web/assess-clarity.test.mjs, tests/web/assess.test.mjs, tests/web/assessment-controller.test.mjs, tests/web/attachment-api.test.mjs, tests/web/backlog.test.mjs, tests/web/binding.test.mjs, tests/web/capture-attachments.test.mjs, tests/web/conversation.test.mjs, tests/web/cp3-review-fixes.test.mjs, tests/web/discovery-proposals.test.mjs, tests/web/discovery.test.mjs, tests/web/exploration-proposals.test.mjs, tests/web/exploration.test.mjs, tests/web/folds.test.mjs, tests/web/handoff-api.test.mjs, tests/web/handoff-controller.test.mjs, tests/web/handoff.test.mjs, tests/web/idea-markdown-api.test.mjs, tests/web/locks.test.mjs, tests/web/method-cards.test.mjs, tests/web/method.test.mjs, tests/web/moved-ideas.test.mjs, tests/web/pairing.test.mjs, tests/web/plain-words.test.mjs, tests/web/prior-art.test.mjs, tests/web/proposals.test.mjs, tests/web/rerank-api.test.mjs, tests/web/review-summary.test.mjs, tests/web/selected-state.test.mjs, tests/web/setup.test.mjs, tests/web/upload-api.test.mjs, tests/web/visualize-controller.test.mjs, tests/web/visualize.test.mjs; Python: glitch-idea/scripts/idea.py, glitch-idea/scripts/idea_agent_client.py, glitch-idea/scripts/idea_agent_memory.py, glitch-idea/scripts/idea_agent_source.py, glitch-idea/scripts/idea_assessment.py, glitch-idea/scripts/idea_asset_evidence.py, glitch-idea/scripts/idea_assets.py, glitch-idea/scripts/idea_bridge.py, glitch-idea/scripts/idea_chain.py, glitch-idea/scripts/idea_chain_v2.py, glitch-idea/scripts/idea_domain.py, glitch-idea/scripts/idea_handoff.py, glitch-idea/scripts/idea_handoff_evidence.py, glitch-idea/scripts/idea_launch.py, glitch-idea/scripts/idea_markdown.py, glitch-idea/scripts/idea_migration.py, glitch-idea/scripts/idea_native.py, glitch-idea/scripts/idea_platform.py, glitch-idea/scripts/idea_proposal_evidence.py, glitch-idea/scripts/idea_proposals.py, glitch-idea/scripts/idea_prototype.py, glitch-idea/scripts/idea_runtime.py, glitch-idea/scripts/idea_service.py, glitch-idea/scripts/idea_sessions.py, glitch-idea/scripts/idea_ssh.py, glitch-idea/scripts/idea_steps/__init__.py, glitch-idea/scripts/idea_steps/assess.py, glitch-idea/scripts/idea_steps/discovery.py, glitch-idea/scripts/idea_steps/exploration.py, glitch-idea/scripts/idea_steps/method.py, glitch-idea/scripts/idea_steps/visualize.py, glitch-idea/scripts/idea_store.py, glitch-idea/scripts/idea_transactions.py, glitch-idea/scripts/idea_workflow.py, glitch-idea/scripts/idea_workflow_api.py, glitch-idea/scripts/idea_workflow_v2.py, install.py, tests/fake_workflow_api.py, tests/fixtures/handoff_plan_validator.py, tests/fixtures/make_store_v2.py, tests/fixtures/scrub_store.py, tests/hermetic_cli.py, tests/native_probe.py, tests/test_activity_log.py, tests/test_agent_bridge.py, tests/test_agent_cli.py, tests/test_agent_client.py, tests/test_agent_idle_fill.py, tests/test_agent_launch.py, tests/test_agent_lease_after_supersede.py, tests/test_agent_lease_while_composing.py, tests/test_agent_memory.py, tests/test_agent_policy.py, tests/test_agent_resume.py, tests/test_agent_source.py, tests/test_agent_transport.py, tests/test_agent_v3_protocol.py, tests/test_assessment.py, tests/test_assessment_source.py, tests/test_asset_agent_door.py, tests/test_asset_evidence.py, tests/test_asset_links.py, tests/test_asset_modes.py, tests/test_asset_projection.py, tests/test_asset_store.py, tests/test_assets.py, tests/test_brand_static.py, tests/test_bridge.py, tests/test_bridge_control.py, tests/test_chain.py, tests/test_chain_cli.py, tests/test_chain_fixtures.py, tests/test_chain_store.py, tests/test_chain_store_held_edit.py, tests/test_chain_v2.py, tests/test_cli_service.py, tests/test_discovery_exploration.py, tests/test_encode_state_unchanged.py, tests/test_exploration_method.py, tests/test_external_edits.py, tests/test_fixed_ports.py, tests/test_fixed_prototype_port.py, tests/test_fragment_pairing.py, tests/test_hand_release.py, tests/test_handoff.py, tests/test_handoff_evidence.py, tests/test_handoff_links.py, tests/test_handoff_service.py, tests/test_handoff_store.py, tests/test_hermetic_config.py, tests/test_idea.py, tests/test_import_cli.py, tests/test_import_idea.py, tests/test_install.py, tests/test_late_pairing_keeps_agent.py, tests/test_launch.py, tests/test_launcher_cli.py, tests/test_legacy_prior_art.py, tests/test_link_mode.py, tests/test_link_mode_cli.py, tests/test_markdown.py, tests/test_markdown_store.py, tests/test_middle_flow.py, tests/test_migration.py, tests/test_move_cli.py, tests/test_move_store.py, tests/test_native.py, tests/test_native_probe.py, tests/test_navigation.py, tests/test_orca_pages_prune.py, tests/test_own_fills_reply.py, tests/test_platform.py, tests/test_port_config_contract.py, tests/test_proposal_evidence.py, tests/test_proposal_links.py, tests/test_proposal_store.py, tests/test_prototype_road.py, tests/test_prototype_server.py, tests/test_rebuilt_tab_repair.py, tests/test_remove_cli.py, tests/test_remove_idea.py, tests/test_remove_idea_in_use.py, tests/test_restore_parks_orphaned_session.py, tests/test_resume_closes_old_tab.py, tests/test_runtime.py, tests/test_runtime_identity.py, tests/test_runtime_root_fallback.py, tests/test_service.py, tests/test_service_start_warms_store.py, tests/test_session_security.py, tests/test_session_slots.py, tests/test_session_superseded.py, tests/test_session_verbs.py, tests/test_shared_store_modes.py, tests/test_skill_text.py, tests/test_ssh_mode.py, tests/test_store_load_cache.py, tests/test_store_requests.py, tests/test_store_write_then_read_warm.py, tests/test_tab_secret.py, tests/test_tern_plugin.py, tests/test_transactions.py, tests/test_tunnel_probe.py, tests/test_two_sessions.py, tests/test_visualize_step.py, tests/test_web_assets.py, tests/test_workflow.py, tests/test_workflow_api.py, tests/test_workflow_schema.py.

### Entry points (4)

- README.md (readme)
- docs/history/pull-requests/README.md (readme)
- glitch-idea/SKILL.md (skill)
- glitch-idea/tern-plugin/README.md (readme)

### Structural census (67)

- docs/asset-format.md:9: long-line: line 9: 692 characters (limit 500)
- docs/asset-format.md:11: long-line: line 11: 918 characters (limit 500)
- docs/asset-format.md:13: long-line: line 13: 607 characters (limit 500)
- docs/asset-format.md:19: long-line: line 19: 828 characters (limit 500)
- docs/browser-api.md: reader-window: 53807 bytes exceeds the 50000-byte (50 KB) window
- docs/history/pull-requests/PR-002.md:44: long-line: line 44: 669 characters (limit 500)
- docs/history/pull-requests/PR-002.md:46: long-line: line 46: 770 characters (limit 500)
- docs/history/pull-requests/PR-003.md:11: long-line: line 11: 536 characters (limit 500)
- docs/history/pull-requests/PR-003.md:33: long-line: line 33: 984 characters (limit 500)
- docs/history/pull-requests/PR-004.md:17: long-line: line 17: 687 characters (limit 500)
- docs/history/pull-requests/PR-005.md:42: long-line: line 42: 1032 characters (limit 500)
- docs/history/pull-requests/PR-006.md:14: long-line: line 14: 526 characters (limit 500)
- docs/history/pull-requests/PR-006.md:18: long-line: line 18: 528 characters (limit 500)
- docs/history/pull-requests/PR-006.md:34: long-line: line 34: 1458 characters (limit 500)
- docs/markdown-format.md:136: long-line: line 136: 680 characters (limit 500)
- docs/workflow-api.md:79: long-line: line 79: 816 characters (limit 500)
- glitch-idea/SKILL.md:20: long-line: line 20: 541 characters (limit 500)
- glitch-idea/SKILL.md:24: long-line: line 24: 763 characters (limit 500)
- glitch-idea/SKILL.md:74: long-line: line 74: 668 characters (limit 500)
- glitch-idea/SKILL.md:76: long-line: line 76: 914 characters (limit 500)
- glitch-idea/SKILL.md:134: long-line: line 134: 1413 characters (limit 500)
- glitch-idea/SKILL.md:150: long-line: line 150: 1056 characters (limit 500)
- glitch-idea/SKILL.md:160: long-line: line 160: 924 characters (limit 500)
- glitch-idea/SKILL.md:178: long-line: line 178: 996 characters (limit 500)
- glitch-idea/SKILL.md:184: long-line: line 184: 1429 characters (limit 500)
- glitch-idea/SKILL.md:216: long-line: line 216: 563 characters (limit 500)
- glitch-idea/SKILL.md:220: long-line: line 220: 507 characters (limit 500)
- glitch-idea/SKILL.md:232: long-line: line 232: 694 characters (limit 500)
- glitch-idea/SKILL.md:234: long-line: line 234: 945 characters (limit 500)
- glitch-idea/SKILL.md:241: long-line: line 241: 523 characters (limit 500)
- glitch-idea/SKILL.md:243: long-line: line 243: 562 characters (limit 500)
- glitch-idea/references/commands.md:10: long-line: line 10: 697 characters (limit 500)
- glitch-idea/references/commands.md:23: long-line: line 23: 2123 characters (limit 500)
- glitch-idea/references/commands.md:25: long-line: line 25: 833 characters (limit 500)
- glitch-idea/references/commands.md:32: long-line: line 32: 531 characters (limit 500)
- glitch-idea/references/commands.md:50: long-line: line 50: 935 characters (limit 500)
- glitch-idea/references/commands.md:52: long-line: line 52: 1052 characters (limit 500)
- glitch-idea/references/commands.md:54: long-line: line 54: 673 characters (limit 500)
- glitch-idea/references/commands.md:64: long-line: line 64: 908 characters (limit 500)
- glitch-idea/references/commands.md:77: long-line: line 77: 1544 characters (limit 500)
- glitch-idea/references/commands.md:111: long-line: line 111: 1263 characters (limit 500)
- glitch-idea/references/commands.md:136: long-line: line 136: 1074 characters (limit 500)
- glitch-idea/references/commands.md:181: long-line: line 181: 704 characters (limit 500)
- glitch-idea/references/commands.md:197: long-line: line 197: 935 characters (limit 500)
- glitch-idea/references/commands.md:230: long-line: line 230: 555 characters (limit 500)
- glitch-idea/references/commands.md:248: long-line: line 248: 504 characters (limit 500)
- glitch-idea/references/commands.md:267: long-line: line 267: 642 characters (limit 500)
- glitch-idea/references/commands.md:281: long-line: line 281: 529 characters (limit 500)
- glitch-idea/references/commands.md:309: long-line: line 309: 652 characters (limit 500)
- glitch-idea/references/methods.md:35: long-line: line 35: 533 characters (limit 500)
- glitch-idea/scripts/idea_markdown.py: reader-window: 62404 bytes exceeds the 50000-byte (50 KB) window
- glitch-idea/scripts/idea_runtime.py: reader-window: 52600 bytes exceeds the 50000-byte (50 KB) window
- glitch-idea/scripts/idea_service.py: reader-window: 70762 bytes exceeds the 50000-byte (50 KB) window
- glitch-idea/scripts/idea_store.py: reader-window: 2715 lines exceeds the 2000-line window; 170007 bytes exceeds the 50000-byte (50 KB) window
- glitch-idea/web/app.js: reader-window: 52972 bytes exceeds the 50000-byte (50 KB) window
- glitch-idea/web/assets/logo.svg:1: long-line: line 1: 7896 characters (limit 500)
- glitch-idea/web/assets/logo.svg:4: long-line: line 4: 507 characters (limit 500)
- glitch-idea/web/folds.js: reader-window: 104432 bytes exceeds the 50000-byte (50 KB) window
- glitch-idea/web/folds.js:395: long-line: line 395: 548 characters (limit 500)
- tests/browser_flow_smoke.mjs: reader-window: 144152 bytes exceeds the 50000-byte (50 KB) window
- tests/browser_flow_smoke.mjs:854: long-line: line 854: 598 characters (limit 500)
- tests/browser_flow_smoke.mjs:1229: long-line: line 1229: 596 characters (limit 500)
- tests/native_probe.py:301: long-line: line 301: 836 characters (limit 500)
- tests/test_assessment_source.py:67: long-line: line 67: 586 characters (limit 500)
- tests/test_assets.py: reader-window: 55449 bytes exceeds the 50000-byte (50 KB) window
- tests/test_bridge.py: reader-window: 62368 bytes exceeds the 50000-byte (50 KB) window
- tests/web/visualize.test.mjs: reader-window: 55525 bytes exceeds the 50000-byte (50 KB) window

### Descriptions (always-on text) (1)

- glitch-idea/SKILL.md:3: `Use when capturing a new software idea, aligning it through questions and an exploration before planning, prioritising a local idea backlog, or resuming an idea and its next slice by permanent ID. Handles newly captured ideas and their saved lifecycle; existing backlogs are outside this skill.`

### Agent and command tool grants (0)

None.

### Hooks (0)

None.

### Platform manifests (0)

None.

### Licenses (license files and declared license fields) (3)

- LICENSE: MIT; license file, matched by text
- glitch-idea/SKILL.md:4: MIT; declared in license
- glitch-idea/tern-plugin/LICENSE: MIT; license file, matched by text


### What it needs

Programs are the ones Walkdown recognizes (`stages/04-phrases/tools.yaml`); declared means named in a dependency file, a skill's compatibility field, or an install line.

- `pip`: not declared; used at glitch-idea/references/commands.md:3 (instructions)
- `py`: declared in glitch-idea/SKILL.md (compatibility); used at glitch-idea/SKILL.md:232 (instructions)
- `python3`: declared in glitch-idea/SKILL.md (compatibility); used at glitch-idea/references/commands.md:7 (instructions), glitch-idea/references/commands.md:19 (instructions), glitch-idea/references/commands.md:20 (instructions), glitch-idea/references/commands.md:41 (instructions), glitch-idea/references/commands.md:47 (instructions), glitch-idea/references/commands.md:59 (instructions), glitch-idea/references/commands.md:93 (instructions), glitch-idea/references/commands.md:94 (instructions), glitch-idea/references/commands.md:95 (instructions), glitch-idea/references/commands.md:165 (instructions), glitch-idea/references/commands.md:176 (instructions), glitch-idea/references/commands.md:177 (instructions), glitch-idea/references/commands.md:190 (instructions), glitch-idea/references/commands.md:191 (instructions), glitch-idea/references/commands.md:192 (instructions), glitch-idea/references/commands.md:224 (instructions), glitch-idea/references/commands.md:225 (instructions), glitch-idea/references/commands.md:226 (instructions), glitch-idea/references/commands.md:227 (instructions), glitch-idea/references/commands.md:253 (instructions), glitch-idea/references/commands.md:254 (instructions), glitch-idea/references/commands.md:255 (instructions), glitch-idea/references/commands.md:256 (instructions), glitch-idea/references/commands.md:298 (instructions), glitch-idea/references/commands.md:299 (instructions)
- `ssh`: declared in glitch-idea/SKILL.md (compatibility); used at glitch-idea/SKILL.md:51 (instructions), glitch-idea/SKILL.md:66 (instructions), glitch-idea/SKILL.md:206 (instructions), glitch-idea/SKILL.md:234 (instructions), glitch-idea/references/commands.md:36 (instructions), glitch-idea/references/commands.md:170 (instructions)
- `PyYAML` (python): declared in glitch-idea/requirements.txt (requirements), glitch-idea/SKILL.md (compatibility); imported in `glitch-idea/scripts/idea_markdown.py`

### What ties it to one machine

Scripts or commands for one system only (1): the other systems do not have them.
- glitch-idea/SKILL.md:232: runs py

## 2 What the model actually reads

267/280 files (95.4%). 27 divergences (10 alt, 9 comment, 6 aria-label, 1 metadata, 1 noscript). 76 lines changed by folding. 0 non-Latin runs. 0 passages in a language other than English. Validation INCOMPLETE: see 7.

Validation: INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-02, same code and fixtures)

### Divergences (reading A versus reading B) (27)

- README.md:19: A-only, carrier alt, method static-style: `Capture`
- README.md:23: A-only, carrier alt, method static-style: `Priorities`
- README.md:27: A-only, carrier alt, method static-style: `Methods`
- README.md:31: A-only, carrier alt, method static-style: `Discovery`
- README.md:35: A-only, carrier alt, method static-style: `Exploration`
- README.md:39: A-only, carrier alt, method static-style: `Visualize`
- README.md:43: A-only, carrier alt, method static-style: `Assess`
- README.md:47: A-only, carrier alt, method static-style: `Review`
- README.md:51: A-only, carrier alt, method static-style: `Planning prompt`
- glitch-idea/web/assets/logo.svg:1: A-only, carrier metadata, method static-style: `AAAWgmp1bWIAAAAeanVtZGMycGEAEQAQgAAAqgA4m3EDYzJwYQAAABZcanVtYgAAAEdqdW1kYzJtYQARABCAAACqADibcQN1cm46YzJwYTo0ZjIyOTBjNy02NWNjLTQzMGMtOGZjOC1jNDcwOTAzYmU1NzAAAAADl2p1bWIAAAApanVtZGMyYXMAEQAQgAAAqgA4m3EDYzJwYS5hc3NlcnRpb25zAAAAALxqdW1iAAAARGp1bWRjYm9yABEAEIAAAKoAOJtxE2MycGEuaW5ncmVkaWVudC52MwAAAAAYYzJzaM1jBLi6MR++W1TDKgUPZl0AAABwY2JvcqNpZGM6Zm9ybWF0bWltYWdlL3N2Zyt4bWxqaW5zdGFuY2VJRHgseG1wOmlpZDpiMmZjMmU3Zi1iMDUxLTQwZTItODc0Mi04ZGFkNzRhMDMwYzNscmVsYXRpb25zaGlwaHBhcmVudE9mAAAB4mp1bWIAAABBanVtZGNib3IAEQAQgAAAqgA4m3ETYzJwYS5hY3Rpb25zLnYyAAAAABhjMnNo019BH0MF0wkQUboQS0OB+wAAAZljYm9yomdhY3Rpb25zgqJmYWN0aW9ua2MycGEub3BlbmVkanBhcmFtZXRlcnOha2luZ3JlZGllbnRzgaJjdXJseC1zZWxmI2p1bWJmPWMycGEuYXNzZXJ0aW9ucy9jMnBhLmluZ3JlZGllbnQudjNkaGFzaFggmA9nF5R1wHwB4wm/lQqdz6d0ccipwAJ1dGKzcxzgrOGkZmFjdGlvbngdY29tLmFudGhyb3BpYy5jbGF1ZGUucHJvdmlkZWRqcGFyYW1ldGVyc6F4H2NvbS5hbnRocm9waWMub3JpZ2luLWNvbmZpZGVuY2VndW5rbm93bmtkZXNjcmlwdGlvbnhmQ2xhdWRlIHByb3ZpZGVkIHRoaXMgZmlsZSBhdCB0aGUgcmVxdWVzdCBvZiBhIHVzZXIgYW5kIG1heSBoYXZlIGNyZWF0ZWQgb3IgbW9kaWZpZWQgdGhlIGZpbGUgY29udGVudHMubXNvZnR3YXJlQWdlbnShZG5hbWVmQ2xhdWRlcmFsbEFjdGlvbnNJbmNsdWRlZPUAAADIanVtYgAAAEBqdW1kY2JvcgARABCAAACqADibcRNjMnBhLmhhc2guZGF0YQAAAAAYYzJzaA1Yq1d3VTEVwnlM8neMTDAAAACAY2JvcqVjYWxnZnNoYTI1NmNwYWRNAAAAAAAAAAAAAAAAAGRoYXNoWCB+hgJWqi2791rA59qbAELJzG7iy6zVh+s2OVlFvnzq3WRuYW1lbmp1bWJmIG1hbmlmZXN0amV4Y2x1c2lvbnOBomVzdGFydBjLZmxlbmd0aBkeBAAAAj5qdW1iAAAAJ2p1bWRjMmNsABEAEIAAAKoAOJtxA2MycGEuY2xhaW0udjIAAAACD2Nib3KlY2FsZ2ZzaGEyNTZpc2lnbmF0dXJleE1zZWxmI2p1bWJmPS9jMnBhL3VybjpjMnBhOjRmMjI5MGM3LTY1Y2MtNDMwYy04ZmM4LWM0NzA5MDNiZTU3MC9jMnBhLnNpZ25hdHVyZWppbnN0YW5jZUlEeCx4bXA6aWlkOmQ3OGRiYmRjLWVkZTctNGYwYy1hZmNiLTkzNmZmZDlhYWVlNXJjcmVhdGVkX2Fzc2VydGlvbnODomN1cmx4LXNlbGYjanVtYmY9YzJwYS5hc3NlcnRpb25zL2MycGEuaW5ncmVkaWVudC52M2RoYXNoWCCYD2cXlHXAfAHjCb+VCp3Pp3RxyKnAAnV0YrNzHOCs4aJjdXJseCpzZWxmI2p1bWJmPWMycGEuYXNzZXJ0aW9ucy9jMnBhLmFjdGlvbnMudjJkaGFzaFgg3D5LTHx4r/0zA8HpKDXdFcSIdweRxfvTnTyJDN692yKiY3VybHgpc2VsZiNqdW1iZj1jMnBhLmFzc2VydGlvbnMvYzJwYS5oYXNoLmRhdGFkaGFzaFggBHZ8SJ0sZdP3zV7SZM6hudKn2HOOPDW5dr9dQ2KHTcV0Y2xhaW1fZ2VuZXJhdG9yX2luZm+jZG5hbWVvQW50aHJvcGljIEZpbGVzZ3ZlcnNpb25lMS4wLjBrc3BlY1ZlcnNpb25lMi40LjAAABA4anVtYgAAAChqdW1kYzJjcwARABCAAACqADibcQNjMnBhLnNpZ25hdHVyZQAAABAIY2JvctKEWQISogEmGCFZAgowggIGMIIBjaADAgECAhRA5aAK7sI50L64g/oGQgU9Z1UTADAKBggqhkjOPQQDAzBJMRcwFQYDVQQKEw5BbnRocm9waWMsIFBCQzEuMCwGA1UEAxMlQW50aHJvcGljIENvbnRlbnQgQ3JlZGVudGlhbHMgUm9vdCBDQTAeFw0yNjA4MDcxODQzNTZaFw0yODA4MDYxOTQzNTZaMEQxFzAVBgNVBAoTDkFudGhyb3BpYywgUEJDMSkwJwYDVQQDEyBBbnRocm9waWMgQ2xhdWRlIENvbnRlbnQgU2lnbmluZzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABJh6CmvLUBgFFNU0vUKlOVtE6djd17L5SuwX0LemFisBM3dkd/3cyjxFA3Qo5S46fX0/ihY0VZ7mfb9KF703t5OjWDBWMA4GA1UdDwEB/wQEAwIHgDAVBgNVHSUEDjAMBgorBgEEAYPoXgIBMAwGA1UdEwEB/wQCMAAwHwYDVR0jBBgwFoAUzlHiBIFOZFsj+OPEz5o+nMHXXMIwCgYIKoZIzj0EAwMDZwAwZAIwMXMdFJ4BetLLVY7ORuE9noqbbAZOZn/aArXyTwFAZfKrPzxF2vPoJNf1+UCdg1XGAjBwX1zd9WGqYkqmL5SFqw1QySjr1zJfpJM9+1rdDwSPLMOPOjKuiXjoU/pUUeG9RwmhY3BhZFkNngAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPZYQF90XJpy35fl+fhN0Gp/DuzifQK7WKTIHHQsem5GSDlsQceVN7fYEqdkicaVldvuNeYjZIyewD6yeQ3n2ylyc5E=`
- glitch-idea/web/index.html:2: A-only, carrier comment, method static-style: `glitch-idea browser shell; Blastworks Applications look.`
- glitch-idea/web/index.html:17: A-only, carrier alt, method static-style: `Blastworks`
- glitch-idea/web/index.html:18: A-only, carrier aria-label, method static-style: `Main`
- glitch-idea/web/index.html:24: A-only, carrier aria-label, method static-style: `APIV: Align, Plan, Implement, Verify`
- glitch-idea/web/index.html:29: A-only, carrier aria-label, method static-style: `Connect this browser`
- glitch-idea/web/index.html:31: A-only, carrier aria-label, method static-style: `Idea steps`
- glitch-idea/web/index.html:37: A-only, carrier aria-label, method static-style: `Idea steps`
- glitch-idea/web/index.html:41: A-only, carrier aria-label, method static-style: `Idea workflow`
- glitch-idea/web/index.html:45: A-only, carrier noscript, method static-style: `This local guided workflow requires JavaScript.`
- tests/fixtures/markdown/idea_00000000000000000000000000000001.md:62: A-only, carrier comment, method static-style: `glitch-idea:notes:start`
- tests/fixtures/markdown/idea_00000000000000000000000000000001.md:63: A-only, carrier comment, method static-style: `glitch-idea:notes:end`
- tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md:638: A-only, carrier comment, method static-style: `glitch-idea:notes:start`
- tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md:639: A-only, carrier comment, method static-style: `glitch-idea:notes:end`
- tests/fixtures/store-v2/idea_11111111111111111111111111111111.md:435: A-only, carrier comment, method static-style: `glitch-idea:notes:start`
- tests/fixtures/store-v2/idea_11111111111111111111111111111111.md:436: A-only, carrier comment, method static-style: `glitch-idea:notes:end`
- tests/fixtures/store-v2/idea_22222222222222222222222222222222.md:210: A-only, carrier comment, method static-style: `glitch-idea:notes:start`
- tests/fixtures/store-v2/idea_22222222222222222222222222222222.md:214: A-only, carrier comment, method static-style: `glitch-idea:notes:end`

### Lines changed by folding (76)

- docs/asset-format.md:13: removed or replaced U+2013
- docs/browser-api.md:126: removed or replaced U+2019
- docs/browser-api.md:132: removed or replaced U+2019
- docs/browser-api.md:140: removed or replaced U+2019
- docs/browser-api.md:277: removed or replaced U+2013
- docs/browser-api.md:341: removed or replaced U+2013
- docs/browser-api.md:644: removed or replaced U+2013
- docs/cp3-validation.md:84: removed or replaced U+2013, U+2013
- docs/cp4-validation.md:14: removed or replaced U+2013
- docs/markdown-format.md:88: removed or replaced U+2013
- docs/markdown-format.md:250: removed or replaced U+2013
- docs/orca-contract.md:144: removed or replaced U+2013
- docs/orca-contract.md:353: removed or replaced U+201C, U+201D
- docs/workflow-api.md:20: removed or replaced U+2013
- glitch-idea/SKILL.md:26: removed or replaced U+2013, U+2013, U+201C, U+201D
- glitch-idea/references/commands.md:248: removed or replaced U+2013
- glitch-idea/references/commands.md:324: removed or replaced U+2026
- glitch-idea/references/methods.md:46: removed or replaced U+2013
- glitch-idea/scripts/idea_asset_evidence.py:151: removed or replaced U+2013
- glitch-idea/scripts/idea_assets.py:308: removed or replaced U+2013
- glitch-idea/scripts/idea_domain.py:176: removed or replaced U+2028, U+2029
- glitch-idea/web/app.js:430: removed or replaced U+2026
- glitch-idea/web/app.js:466: removed or replaced U+2026
- glitch-idea/web/app.js:585: removed or replaced U+2026
- glitch-idea/web/app.js:590: removed or replaced U+2026
- glitch-idea/web/app.js:694: removed or replaced U+2019
- glitch-idea/web/folds.js:52: removed or replaced U+2212
- glitch-idea/web/folds.js:430: removed or replaced U+2026, U+2026
- glitch-idea/web/folds.js:540: removed or replaced U+2026
- glitch-idea/web/folds.js:1297: removed or replaced U+2026
- glitch-idea/web/ideas.js:43: removed or replaced U+2026
- glitch-idea/web/ideas.js:83: removed or replaced U+2019
- glitch-idea/web/ideas.js:166: removed or replaced U+2026
- glitch-idea/web/ideas.js:208: removed or replaced U+2026
- glitch-idea/web/ideas.js:218: removed or replaced U+2026
- glitch-idea/web/ideas.js:252: removed or replaced U+2013
- glitch-idea/web/index.html:24: removed or replaced U+203A, U+203A, U+203A
- glitch-idea/web/index.html:27: removed or replaced U+2026
- glitch-idea/web/setup.js:52: removed or replaced U+2026
- glitch-idea/web/setup.js:83: removed or replaced U+2026
- glitch-idea/web/setup.js:122: removed or replaced U+2026
- glitch-idea/web/steps/assess.js:11: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:26: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:30: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:31: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:32: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:33: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:36: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:37: removed or replaced U+2026
- glitch-idea/web/steps/assess.js:51: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:60: removed or replaced U+00D7, U+00D7
- glitch-idea/web/steps/assess.js:140: removed or replaced U+2013
- glitch-idea/web/steps/assess.js:276: removed or replaced U+2026
- glitch-idea/web/steps/assess.js:300: removed or replaced U+2026
- glitch-idea/web/steps/discovery.js:159: removed or replaced U+2026
- glitch-idea/web/steps/discovery.js:200: removed or replaced U+2026
- glitch-idea/web/steps/exploration.js:261: removed or replaced U+2026
- glitch-idea/web/steps/exploration.js:306: removed or replaced U+2026
- glitch-idea/web/steps/method.js:93: removed or replaced U+2026
- glitch-idea/web/steps/method.js:125: removed or replaced U+2026
- glitch-idea/web/steps/review.js:109: removed or replaced U+2026
- glitch-idea/web/steps/review.js:232: removed or replaced U+2026
- glitch-idea/web/steps/visualize.js:432: removed or replaced U+2026
- tests/test_chain_v2.py:255: removed or replaced U+2026
- tests/test_move_cli.py:350: removed or replaced U+2028
- tests/web/accept-reasons.test.mjs:135: removed or replaced U+2026
- tests/web/app-render.test.mjs:293: removed or replaced U+203A
- tests/web/app-render.test.mjs:323: removed or replaced U+2026
- tests/web/assess-clarity.test.mjs:43: removed or replaced U+00D7, U+00D7
- tests/web/assess-clarity.test.mjs:57: removed or replaced U+2013
- tests/web/assess-clarity.test.mjs:62: removed or replaced U+2013
- tests/web/conversation.test.mjs:202: removed or replaced U+2026, U+2026
- tests/web/conversation.test.mjs:216: removed or replaced U+2026
- tests/web/conversation.test.mjs:228: removed or replaced U+2026
- tests/web/handoff-controller.test.mjs:308: removed or replaced U+2026
- tests/web/review-summary.test.mjs:84: removed or replaced U+2026

### Non-Latin script runs (0)

None.

### Passages in a language other than English (Latin script) (0)

None.

### Metadata carrying text (0)

None.

### Unread (13)

- docs/screenshots/01-capture.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- docs/screenshots/02-priorities.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- docs/screenshots/03-methods.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- docs/screenshots/04-discovery.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- docs/screenshots/05-exploration.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- docs/screenshots/06-visualize.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- docs/screenshots/07-assess.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- docs/screenshots/08-review.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- docs/screenshots/09-review-planning-prompt.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- glitch-idea/web/assets/fonts/BlastworksSans-ExtraBold.woff2: binary blob (does not decode as text)
- glitch-idea/web/assets/fonts/BlastworksSans-Regular.woff2: binary blob (does not decode as text)
- glitch-idea/web/assets/fonts/BlastworksSans-SemiBold.woff2: binary blob (does not decode as text)
- tests/test_assets.py: pdf parse error: PdfStreamError: Stream has ended unexpectedly

## 3 What loads what

4 entry points. 8 orphans. 770 dangling references (759 code, 11 prose; 110 of them into a folder the repository does not have). 283 dynamic loads: 115 files loaded only through one (named by nothing), 67 files reached only through a mention of a folder or wildcards. Graph incomplete by construction.

Validation: PASS (gate 11/11, negative 7/7; measured 2026-11-02, same code and fixtures)

Depth histogram (static = reached by direct references; dynamic = only through a load: a folder a config names, a code scan, wildcards in an instruction file; mention = only through a folder or wildcards named elsewhere): dynamic depth 2: 2; dynamic depth 3: 104; dynamic depth 4: 9; mention depth 1: 5; mention depth 2: 27; mention depth 3: 33; mention depth 5: 2; static depth 0: 4; static depth 1: 31; static depth 2: 18; static depth 3: 26; static depth 4: 11.

### Entry points used (4)

- README.md (readme)
- docs/history/pull-requests/README.md (readme)
- glitch-idea/SKILL.md (skill)
- glitch-idea/tern-plugin/README.md (readme)

### Orphans (reachable from no entry point) (8)

- docs/acceptance-browser-flow.md
- docs/asset-format.md
- docs/browser-api.md
- docs/cp1-validation.md
- docs/cp2-validation.md
- docs/cp3-validation.md
- docs/orca-contract.md
- src/.gitkeep

### Files loaded only through a dynamic load (named by nothing) (115)

- .gitignore (depth 2, from install.py)
- capability.json (depth 2, from install.py)
- docs/design-provenance.md (depth 4, from tests/test_web_assets.py)
- glitch-idea/scripts/idea_platform.py (depth 4, from tests/test_platform.py)
- glitch-idea/scripts/idea_service.py (depth 4, from tests/test_cli_service.py)
- glitch-idea/scripts/idea_steps/method.py (depth 4, from tests/test_web_assets.py)
- glitch-idea/scripts/idea_store.py (depth 4, from tests/test_web_assets.py)
- glitch-idea/tern-plugin/plugin.toml (depth 4, from tests/test_tern_plugin.py)
- glitch-idea/tern-plugin/window.luau (depth 4, from tests/test_tern_plugin.py)
- glitch-idea/web/assets/NOTICE.md (depth 4, from tests/test_web_assets.py)
- glitch-idea/web/assets/fonts/BlastworksSans-UNLICENSE.txt (depth 4, from tests/test_web_assets.py)
- tests/browser_flow_smoke.mjs (depth 3, from tests/test_legacy_prior_art.py)
- tests/hermetic_cli.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/native_probe.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_activity_log.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_bridge.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_cli.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_client.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_idle_fill.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_launch.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_lease_after_supersede.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_lease_while_composing.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_memory.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_policy.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_resume.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_source.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_transport.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_agent_v3_protocol.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_assessment.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_assessment_source.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_asset_agent_door.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_asset_evidence.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_asset_links.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_asset_modes.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_asset_projection.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_asset_store.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_assets.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_brand_static.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_bridge.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_bridge_control.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_chain.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_chain_cli.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_chain_fixtures.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_chain_store.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_chain_store_held_edit.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_chain_v2.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_cli_service.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_discovery_exploration.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_encode_state_unchanged.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_exploration_method.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_external_edits.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_fixed_ports.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_fixed_prototype_port.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_fragment_pairing.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_hand_release.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_handoff_evidence.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_handoff_links.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_handoff_service.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_handoff_store.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_hermetic_config.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_idea.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_import_cli.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_import_idea.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_install.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_late_pairing_keeps_agent.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_launch.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_launcher_cli.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_link_mode.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_link_mode_cli.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_markdown.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_markdown_store.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_middle_flow.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_migration.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_move_cli.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_move_store.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_native.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_native_probe.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_navigation.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_orca_pages_prune.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_own_fills_reply.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_platform.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_port_config_contract.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_proposal_evidence.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_proposal_links.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_proposal_store.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_prototype_road.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_prototype_server.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_remove_cli.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_remove_idea.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_resume_closes_old_tab.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_runtime.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_runtime_identity.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_runtime_root_fallback.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_service.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_service_start_warms_store.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_session_security.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_session_slots.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_session_superseded.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_session_verbs.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_shared_store_modes.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_skill_text.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_ssh_mode.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_store_load_cache.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_store_requests.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_store_write_then_read_warm.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_tab_secret.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_tern_plugin.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_transactions.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_tunnel_probe.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_two_sessions.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_visualize_step.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_web_assets.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_workflow.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_workflow_api.py (depth 3, from tests/test_legacy_prior_art.py)
- tests/test_workflow_schema.py (depth 3, from tests/test_legacy_prior_art.py)

### Files reached only through a mention of a folder or wildcards (not a load) (67)

- glitch-idea/agents/openai.yaml (depth 5, from docs/design-provenance.md)
- glitch-idea/scripts/idea_agent_client.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_agent_memory.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_agent_source.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_assessment.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_asset_evidence.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_assets.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_bridge.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_chain_v2.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_domain.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_handoff.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_launch.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_markdown.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_migration.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_native.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_proposal_evidence.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_proposals.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_prototype.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_runtime.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_ssh.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_steps/__init__.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_steps/assess.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_steps/discovery.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_steps/exploration.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_steps/visualize.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_transactions.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_workflow_api.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/scripts/idea_workflow_v2.py (depth 2, from tests/fixtures/scrub_store.py)
- glitch-idea/tern-plugin/LICENSE (depth 5, from docs/design-provenance.md)
- tests/fixtures/make_store_v2.py (depth 1, from README.md)
- tests/fixtures/scrub_store.py (depth 1, from README.md)
- tests/fixtures/store-v03-preprior/session-recovery/session_1331fc315b8b43ab918762cc8fc35032.json (depth 1, from README.md)
- tests/fixtures/store-v03-preprior/session-recovery/session_2b3d87b39c434b35b5fbbeb4dff2c545.json (depth 1, from README.md)
- tests/fixtures/store-v03-preprior/session-recovery/session_4f9ce081fbbd477b9b1580136f14464e.json (depth 1, from README.md)
- tests/web/accept-reasons.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/assess-clarity.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/assess.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/assessment-controller.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/attachment-api.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/backlog.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/binding.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/capture-attachments.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/conversation.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/cp3-review-fixes.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/discovery-proposals.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/discovery.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/exploration-proposals.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/exploration.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/folds.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/handoff-api.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/handoff-controller.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/handoff.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/idea-markdown-api.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/locks.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/method-cards.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/method.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/moved-ideas.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/pairing.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/prior-art.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/proposals.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/rerank-api.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/review-summary.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/selected-state.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/setup.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/upload-api.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/visualize-controller.test.mjs (depth 3, from docs/cp4-validation.md)
- tests/web/visualize.test.mjs (depth 3, from docs/cp4-validation.md)

### Dynamic loads (283)

- README.md:286: directory `tests/fixtures/` (mention) resolves to 31 files
- docs/cp1-validation.md:67: glob `tests/web/*.test.mjs` (mention) resolves to 35 files
- docs/cp2-validation.md:117: glob `tests/web/*.test.mjs` (mention) resolves to 35 files
- docs/cp4-validation.md:195: glob `tests/web/*.test.mjs` (mention) resolves to 35 files
- docs/design-provenance.md:17: directory `glitch-idea/` (mention) resolves to 66 files
- docs/design-provenance.md:21: directory `glitch-idea/web/` (mention) resolves to 20 files
- docs/design-provenance.md:32: glob `*.dc.html` (mention) resolves to 0 files
- docs/design-provenance.md:40: directory `glitch-idea/web/` (mention) resolves to 20 files
- docs/design-provenance.md:41: directory `glitch-idea/` (mention) resolves to 66 files
- docs/design-provenance.md:42: glob `*.dc.html` (mention) resolves to 0 files
- docs/design-provenance.md:42: glob `dc-runtime*.js` (mention) resolves to 0 files
- docs/markdown-format.md:238: directory `tests/fixtures/markdown/` (mention) resolves to 3 files
- docs/markdown-format.md:321: glob `history/**` (mention) resolves to 9 files
- glitch-idea/references/commands.md:310: glob `history/backlog/*` (mention) resolves to 0 files
- glitch-idea/references/commands.md:326: glob `history/backlog/*` (mention) resolves to 0 files
- glitch-idea/scripts/idea_markdown.py:400: glob `backlog/r[1-9][0-9` (mention) resolves to 0 files
- glitch-idea/scripts/idea_runtime.py:386: code `os.listdir(directory)` (load) resolves to 0 files
- glitch-idea/scripts/idea_runtime.py:395: code `os.listdir(bindings)` (load) resolves to 0 files
- glitch-idea/scripts/idea_runtime.py:456: code `os.listdir(parent)` (load) resolves to 0 files
- glitch-idea/scripts/idea_ssh.py:376: glob `}/api/v1/tunnel-probe?nonce` (mention) resolves to 0 files
- glitch-idea/scripts/idea_store.py:812: glob `history/idea_[0-9a-f]{32` (mention) resolves to 0 files
- glitch-idea/scripts/idea_store.py:2042: glob `history/backlog/*` (mention) resolves to 0 files
- glitch-idea/scripts/idea_store.py:2042: glob `session-recovery/*` (mention) resolves to 0 files
- glitch-idea/scripts/idea_transactions.py:39: glob `backlog/r[1-9][0-9` (mention) resolves to 0 files
- glitch-idea/scripts/idea_transactions.py:39: glob `metadata/[0-9a-f]{64` (mention) resolves to 0 files
- glitch-idea/scripts/idea_transactions.py:39: glob `migrations/w[1-9][0-9]*-[0-9a-f]{64` (mention) resolves to 0 files
- install.py:61: code `*` (load) resolves to 6 files
- tests/browser_flow_smoke.mjs:161: glob `e?{disabled:e.disabled` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:224: glob `?.dataset.status` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:228: glob `?.id` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:256: glob `?.dataset.status` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:261: glob `?.dataset.ideaId` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:498: glob `?.dataset.status` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:699: glob `?.dataset.status` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:854: glob `?.disabled` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:916: glob `?.id` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:920: glob `?.id` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:965: glob `?.dataset.status` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1000: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1003: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1021: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1023: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1125: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1126: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1127: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1143: glob `?.disabled` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1144: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1147: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1150: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1152: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1155: glob `?.value` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1234: code `readdirSync(historyDir)` (load) resolves to 0 files
- tests/browser_flow_smoke.mjs:1296: glob `?.disabled` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1330: glob `?.disabled` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1398: glob `?.dataset.status` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1450: glob `?.dataset.ideaId` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1459: glob `?.dataset.ideaId` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1462: glob `?.tagName` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1509: glob `?.hidden` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1511: glob `?.dataset.ideaId` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1537: glob `?.type` (mention) resolves to 0 files
- tests/browser_flow_smoke.mjs:1664: glob `?.id` (mention) resolves to 0 files
- tests/fixtures/scrub_store.py:30: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/fixtures/scrub_store.py:98: code `*` (load) resolves to 3 files
- tests/fixtures/scrub_store.py:162: code `*.json` (load) resolves to 2 files
- tests/fixtures/scrub_store.py:168: code `*` (load) resolves to 3 files
- tests/fixtures/scrub_store.py:170: code `*` (load) resolves to 3 files
- tests/hermetic_cli.py:25: glob `*.pyc` (mention) resolves to 0 files
- tests/test_agent_bridge.py:10: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_cli.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_client.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_idle_fill.py:11: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_launch.py:15: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_lease_after_supersede.py:11: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_lease_while_composing.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_memory.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_policy.py:11: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_resume.py:8: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_source.py:11: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_transport.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_agent_v3_protocol.py:6: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_assessment.py:11: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_assessment_source.py:10: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_asset_agent_door.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_asset_evidence.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_asset_links.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_asset_links.py:279: code `*` (load) resolves to 110 files
- tests/test_asset_links.py:290: code `*` (load) resolves to 110 files
- tests/test_asset_links.py:296: code `*` (load) resolves to 110 files
- tests/test_asset_projection.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_asset_store.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_asset_store.py:98: code `*` (load) resolves to 110 files
- tests/test_assets.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_assets.py:85: code `*` (load) resolves to 110 files
- tests/test_bridge.py:18: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_bridge.py:567: code `*` (load) resolves to 110 files
- tests/test_bridge.py:594: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/test_bridge.py:941: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/test_bridge_control.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_chain.py:8: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_chain.py:71: code `*` (load) resolves to 110 files
- tests/test_chain_cli.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_chain_cli.py:19: directory `tests/fixtures/store-v2/` (mention) resolves to 11 files
- tests/test_chain_fixtures.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_chain_fixtures.py:18: directory `tests/fixtures/store-v03-preprior/` (mention) resolves to 14 files
- tests/test_chain_fixtures.py:25: code `*` (load) resolves to 110 files
- tests/test_chain_fixtures.py:67: code `*` (load) resolves to 110 files
- tests/test_chain_store.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_chain_store.py:18: directory `tests/fixtures/store-v2/` (mention) resolves to 11 files
- tests/test_chain_store.py:31: code `*` (load) resolves to 110 files
- tests/test_chain_v2.py:11: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_chain_v2.py:20: directory `tests/fixtures/store-v2/` (mention) resolves to 11 files
- tests/test_chain_v2.py:28: code `r*.md` (load) resolves to 0 files
- tests/test_cli_service.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_cli_service.py:216: code `*` (load) resolves to 110 files
- tests/test_cli_service.py:219: code `*` (load) resolves to 110 files
- tests/test_cli_service.py:237: code `*` (load) resolves to 110 files
- tests/test_cli_service.py:240: code `*` (load) resolves to 110 files
- tests/test_discovery_exploration.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_encode_state_unchanged.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_exploration_method.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_exploration_method.py:196: code `*.md` (load) resolves to 1 file
- tests/test_exploration_method.py:205: code `*.md` (load) resolves to 1 file
- tests/test_external_edits.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_fixed_ports.py:16: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_fixed_prototype_port.py:15: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_fragment_pairing.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_handoff.py:11: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_handoff.py:33: code `*` (load) resolves to 110 files
- tests/test_handoff.py:188: code `*` (load) resolves to 110 files
- tests/test_handoff.py:201: code `*` (load) resolves to 110 files
- tests/test_handoff_evidence.py:10: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_handoff_links.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_handoff_service.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_handoff_service.py:69: code `*` (load) resolves to 110 files
- tests/test_handoff_store.py:15: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_handoff_store.py:81: code `*` (load) resolves to 110 files
- tests/test_handoff_store.py:223: code `*` (load) resolves to 110 files
- tests/test_handoff_store.py:328: code `*` (load) resolves to 110 files
- tests/test_handoff_store.py:584: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_idea.py:47: code `*` (load) resolves to 110 files
- tests/test_import_cli.py:16: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_import_cli.py:25: code `*` (load) resolves to 110 files
- tests/test_import_cli.py:105: directory `tests/fixtures/store-v2/` (mention) resolves to 11 files
- tests/test_import_idea.py:17: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_import_idea.py:53: code `*` (load) resolves to 110 files
- tests/test_import_idea.py:58: code `*` (load) resolves to 110 files
- tests/test_import_idea.py:324: code `glob('history/'+self.key+'/metadata/*.md')` (load) resolves to 0 files
- tests/test_install.py:37: code `*` (load) resolves to 110 files
- tests/test_install.py:62: code `*` (load) resolves to 110 files
- tests/test_install.py:70: code `*` (load) resolves to 110 files
- tests/test_install.py:73: code `*` (load) resolves to 110 files
- tests/test_install.py:117: code `*` (load) resolves to 110 files
- tests/test_install.py:120: code `*` (load) resolves to 110 files
- tests/test_install.py:271: code `lib/python*/site-packages` (load) resolves to 0 files
- tests/test_late_pairing_keeps_agent.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_launch.py:18: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_launch.py:122: code `*.json` (load) resolves to 2 files
- tests/test_launch.py:126: code `*.json` (load) resolves to 2 files
- tests/test_launch.py:258: code `*.json` (load) resolves to 2 files
- tests/test_launch.py:261: code `*.json` (load) resolves to 2 files
- tests/test_launch.py:265: code `*.json` (load) resolves to 2 files
- tests/test_launcher_cli.py:17: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_legacy_prior_art.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_legacy_prior_art.py:59: code `*` (load) resolves to 110 files
- tests/test_link_mode.py:17: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_link_mode.py:101: code `*` (load) resolves to 110 files
- tests/test_link_mode_cli.py:15: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_link_mode_cli.py:146: code `binding_*.json` (load) resolves to 0 files
- tests/test_markdown.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_markdown.py:266: directory `tests/fixtures/markdown/` (mention) resolves to 3 files
- tests/test_markdown.py:267: code `*.md` (load) resolves to 1 file
- tests/test_markdown.py:362: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_markdown_store.py:15: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_middle_flow.py:465: code `*` (load) resolves to 110 files
- tests/test_middle_flow.py:598: code `*` (load) resolves to 110 files
- tests/test_middle_flow.py:618: code `*` (load) resolves to 110 files
- tests/test_middle_flow.py:728: code `*` (load) resolves to 110 files
- tests/test_migration.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_migration.py:195: code `*/manifest.json` (load) resolves to 0 files
- tests/test_move_cli.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_move_cli.py:69: code `*` (load) resolves to 110 files
- tests/test_move_cli.py:72: code `*` (load) resolves to 110 files
- tests/test_move_cli.py:397: code `*.json` (load) resolves to 2 files
- tests/test_move_cli.py:458: code `*.py` (load) resolves to 109 files
- tests/test_move_store.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_move_store.py:73: code `*` (load) resolves to 110 files
- tests/test_move_store.py:118: code `os.listdir(self.root/'.transactions')` (load) resolves to 0 files
- tests/test_move_store.py:422: code `os.listdir(self.root/'.transactions')` (load) resolves to 0 files
- tests/test_native.py:8: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_navigation.py:8: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_navigation.py:58: code `*.md` (load) resolves to 1 file
- tests/test_orca_pages_prune.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_own_fills_reply.py:6: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_platform.py:15: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_port_config_contract.py:11: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_proposal_evidence.py:10: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_proposal_links.py:8: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_proposal_store.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_proposal_store.py:85: code `*` (load) resolves to 110 files
- tests/test_proposal_store.py:238: code `*.md` (load) resolves to 1 file
- tests/test_prototype_road.py:8: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_prototype_server.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_rebuilt_tab_repair.py:22: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_remove_cli.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_remove_cli.py:21: code `*` (load) resolves to 110 files
- tests/test_remove_cli.py:72: directory `tests/fixtures/store-v2/` (mention) resolves to 11 files
- tests/test_remove_idea.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_remove_idea.py:334: code `*` (load) resolves to 110 files
- tests/test_remove_idea_in_use.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_remove_idea_in_use.py:28: code `*` (load) resolves to 110 files
- tests/test_restore_parks_orphaned_session.py:151: code `.parking_*.tmp` (load) resolves to 0 files
- tests/test_resume_closes_old_tab.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_runtime.py:17: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_runtime.py:385: code `.runtime_*.tmp` (load) resolves to 0 files
- tests/test_runtime.py:524: code `.runtime_*.tmp` (load) resolves to 0 files
- tests/test_runtime.py:570: code `.runtime_*.tmp` (load) resolves to 0 files
- tests/test_runtime.py:574: code `.runtime_*.tmp` (load) resolves to 0 files
- tests/test_runtime_identity.py:10: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_runtime_root_fallback.py:10: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_service.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_session_security.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_session_slots.py:17: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_session_slots.py:131: code `binding_*.json` (load) resolves to 0 files
- tests/test_session_slots.py:169: code `*.md` (load) resolves to 1 file
- tests/test_session_verbs.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_session_verbs.py:46: code `binding_*.json` (load) resolves to 0 files
- tests/test_session_verbs.py:53: code `binding_*.json` (load) resolves to 0 files
- tests/test_shared_store_modes.py:35: code `*` (load) resolves to 110 files
- tests/test_shared_store_modes.py:61: code `*` (load) resolves to 110 files
- tests/test_ssh_mode.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_store_load_cache.py:10: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_store_load_cache.py:151: code `*.md` (load) resolves to 1 file
- tests/test_store_load_cache.py:157: code `*.json` (load) resolves to 2 files
- tests/test_store_load_cache.py:164: code `*.md` (load) resolves to 1 file
- tests/test_store_load_cache.py:169: code `*` (load) resolves to 110 files
- tests/test_store_requests.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_store_requests.py:69: code `*` (load) resolves to 110 files
- tests/test_tab_secret.py:12: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_transactions.py:16: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_transactions.py:94: code `txn_*/manifest.json` (load) resolves to 0 files
- tests/test_transactions.py:457: code `os.listdir(self.root / tx.JOURNAL)` (load) resolves to 0 files
- tests/test_transactions.py:487: code `os.listdir(self.root / tx.JOURNAL)` (load) resolves to 0 files
- tests/test_tunnel_probe.py:10: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_tunnel_probe.py:118: code `*` (load) resolves to 110 files
- tests/test_tunnel_probe.py:125: code `discovery.json` (load) resolves to 0 files
- tests/test_tunnel_probe.py:140: code `discovery.json` (load) resolves to 0 files
- tests/test_two_sessions.py:18: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_visualize_step.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_visualize_step.py:36: code `*` (load) resolves to 110 files
- tests/test_web_assets.py:77: code `*` (load) resolves to 110 files
- tests/test_web_assets.py:89: code `*` (load) resolves to 110 files
- tests/test_web_assets.py:399: code `*` (load) resolves to 110 files
- tests/test_web_assets.py:503: glob `--ink-/**/muted` (mention) resolves to 0 files
- tests/test_web_assets.py:520: glob `2/**/px` (mention) resolves to 0 files
- tests/test_workflow.py:9: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_workflow_api.py:14: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/test_workflow_schema.py:13: directory `glitch-idea/scripts/` (mention) resolves to 36 files
- tests/web/accept-reasons.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/app-render.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/assess-clarity.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/assess.test.mjs:6: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/backlog.test.mjs:6: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/binding.test.mjs:6: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/capture-attachments.test.mjs:6: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/conversation.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/cp3-review-fixes.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/discovery-proposals.test.mjs:6: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/discovery.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/exploration-proposals.test.mjs:7: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/exploration.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/folds.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/handoff-controller.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/handoff.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/locks.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/method-cards.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/method.test.mjs:6: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/pairing.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/plain-words.test.mjs:9: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/prior-art.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/proposals.test.mjs:5: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/setup.test.mjs:6: directory `glitch-idea/web/` (mention) resolves to 20 files
- tests/web/visualize.test.mjs:6: directory `glitch-idea/web/` (mention) resolves to 20 files

### On disk, left out of the manifest (a host that finds components by folder may still load them) (0)

None.

### Dangling references (660)

- README.md:83: `pyvenv.cfg` (code)
- README.md:117: `_local/` (code)
- README.md:117: `workspaces/` (code)
- README.md:120: `config.json` (code)
- README.md:126: `ideas/` (code)
- README.md:131: `config.json` (code)
- README.md:155: `config.json` (code)
- README.md:258: `plan-evidence/` (code)
- README.md:267: `config.json` (code)
- docs/browser-api.md:46: `origin>/#pair` (code)
- docs/browser-runbook.md:82: `_local/` (code)
- docs/browser-runbook.md:82: `workspaces/` (code)
- docs/browser-runbook.md:92: `config.json` (code)
- docs/browser-runbook.md:93: `config.json` (code)
- docs/browser-runbook.md:115: `origin>/#pair` (code)
- docs/browser-runbook.md:298: `plan-evidence/` (code)
- docs/browser-runbook.md:309: `state.json` (code)
- docs/browser-runbook.md:310: `migration-recovery/` (code)
- docs/browser-runbook.md:310: `state.json` (code)
- docs/browser-runbook.md:312: `plan-evidence/` (code)
- docs/browser-runbook.md:318: `state.json` (code)
- docs/cp1-validation.md:55: `plan_check.py` (code)
- docs/cp1-validation.md:56: `update.py` (code)
- docs/cp1-validation.md:71: `isolation-disk-readback.json` (code)
- docs/cp1-validation.md:72: `conflict-disk-readback.json` (code)
- docs/cp1-validation.md:72: `live-browser-conflict-recovered.json` (code)
- docs/cp1-validation.md:73: `configured-validator.log` (code)
- docs/cp3-validation.md:18: `Skip/` (prose)
- docs/cp3-validation.md:66: `effort/` (prose)
- docs/cp3-validation.md:96: `middle-b-final-readback.json` (code)
- docs/cp3-validation.md:134: `metadata/` (prose)
- docs/cp4-validation.md:53: `design-notes.md` (code)
- docs/cp4-validation.md:55: `layout.svg` (code)
- docs/cp4-validation.md:93: `product-source-boundary.json` (code)
- docs/cp4-validation.md:158: `app/` (prose)
- docs/cp4-validation.md:182: `-r5.md` (code)
- docs/design-provenance.md:32: `dc-runtime.js` (code)
- docs/design-provenance.md:32: `support.js` (code)
- docs/design-provenance.md:32: `tokens.json` (code)
- docs/design-provenance.md:42: `support.js` (code)
- docs/design-provenance.md:42: `tokens.json` (code)
- docs/history/pull-requests/PR-006.md:34: `origin>/#pair` (prose)
- docs/markdown-format.md:280: `state.json` (code)
- docs/markdown-format.md:288: `state.json` (code)
- docs/orca-contract.md:96: `origin>/#pair` (code)
- docs/orca-contract.md:163: `reply-file.json` (code)
- docs/orca-contract.md:283: `codex-idle-paused.png` (code)
- glitch-idea/SKILL.md:46: `origin>/#pair` (code)
- glitch-idea/references/commands.md:23: `origin>/#pair` (code)
- glitch-idea/references/commands.md:25: `origin>/#pair` (code)
- glitch-idea/references/commands.md:50: `origin>/#pair` (code)
- glitch-idea/references/commands.md:324: `id>.2.md` (code)
- glitch-idea/references/commands.md:324: `id>.3.md` (code)
- glitch-idea/scripts/idea.py:123: `.glitch-idea-install.json` (code)
- glitch-idea/scripts/idea.py:124: `config.json` (code)
- glitch-idea/scripts/idea.py:125: `config.json` (code)
- glitch-idea/scripts/idea_agent_memory.py:26: `A-Za-z0-9][A-Za-z0-9._:/#-` (code)
- glitch-idea/scripts/idea_bridge.py:66: `steps/` (code)
- glitch-idea/scripts/idea_chain.py:75: `history/` (code)
- glitch-idea/scripts/idea_chain.py:80: `history/` (code)
- glitch-idea/scripts/idea_chain.py:101: `history/` (code)
- glitch-idea/scripts/idea_chain.py:111: `history/` (code)
- glitch-idea/scripts/idea_handoff_evidence.py:25: `history/` (code)
- glitch-idea/scripts/idea_handoff_evidence.py:301: `history/` (code)
- glitch-idea/scripts/idea_launch.py:510: `activity.log` (code)
- glitch-idea/scripts/idea_launch.py:733: `orca-pages.json` (code)
- glitch-idea/scripts/idea_launch.py:754: `.orca-pages.lock` (code)
- glitch-idea/scripts/idea_markdown.py:63: `tag:yaml.org` (code)
- glitch-idea/scripts/idea_markdown.py:89: `tag:yaml.org` (code)
- glitch-idea/scripts/idea_markdown.py:181: `tag:yaml.org` (code)
- glitch-idea/scripts/idea_markdown.py:268: `history/` (code)
- glitch-idea/scripts/idea_markdown.py:400: `history/` (code)
- glitch-idea/scripts/idea_markdown.py:425: `history/` (code)
- glitch-idea/scripts/idea_markdown.py:623: `history/` (code)
- glitch-idea/scripts/idea_markdown.py:665: `history/` (code)
- glitch-idea/scripts/idea_markdown.py:711: `history/` (code)
- glitch-idea/scripts/idea_markdown.py:977: `plan-evidence/` (code)
- glitch-idea/scripts/idea_markdown.py:981: `history/` (code)
- glitch-idea/scripts/idea_markdown.py:1123: `plan-evidence/` (code)
- glitch-idea/scripts/idea_migration.py:45: `state.json` (code)
- glitch-idea/scripts/idea_migration.py:81: `state.json` (code)
- glitch-idea/scripts/idea_migration.py:86: `state.json` (code)
- glitch-idea/scripts/idea_migration.py:89: `plan-evidence/` (code)
- glitch-idea/scripts/idea_migration.py:94: `archive/` (code)
- glitch-idea/scripts/idea_migration.py:103: `state.json` (code)
- glitch-idea/scripts/idea_migration.py:113: `archive/` (code)
- glitch-idea/scripts/idea_proposal_evidence.py:30: `history/` (code)
- glitch-idea/scripts/idea_proposal_evidence.py:153: `history/` (code)
- glitch-idea/scripts/idea_prototype.py:149: `text/` (code)
- glitch-idea/scripts/idea_runtime.py:388: `credentials.json` (code)
- glitch-idea/scripts/idea_runtime.py:388: `discovery.json` (code)
- glitch-idea/scripts/idea_runtime.py:388: `service.lock` (code)
- glitch-idea/scripts/idea_runtime.py:392: `service.lock` (code)
- glitch-idea/scripts/idea_runtime.py:393: `credentials.json` (code)
- glitch-idea/scripts/idea_runtime.py:507: `credentials.json` (code)
- glitch-idea/scripts/idea_runtime.py:507: `discovery.json` (code)
- glitch-idea/scripts/idea_runtime.py:527: `service.lock` (code)
- glitch-idea/scripts/idea_runtime.py:531: `service.lock` (code)
- glitch-idea/scripts/idea_runtime.py:550: `credentials.json` (code)
- glitch-idea/scripts/idea_runtime.py:691: `discovery.json` (code)
- glitch-idea/scripts/idea_runtime.py:712: `discovery.json` (code)
- glitch-idea/scripts/idea_runtime.py:713: `credentials.json` (code)
- glitch-idea/scripts/idea_runtime.py:734: `service.lock` (code)
- glitch-idea/scripts/idea_service.py:217: `history/` (code)
- glitch-idea/scripts/idea_store.py:217: `session-recovery/` (code)
- glitch-idea/scripts/idea_store.py:515: `plan-evidence/` (code)
- glitch-idea/scripts/idea_store.py:542: `session-recovery/` (code)
- glitch-idea/scripts/idea_store.py:543: `session-recovery/` (code)
- glitch-idea/scripts/idea_store.py:545: `session-recovery/` (code)
- glitch-idea/scripts/idea_store.py:578: `state.json` (code)
- glitch-idea/scripts/idea_store.py:652: `assets/` (code)
- glitch-idea/scripts/idea_store.py:828: `history/` (code)
- glitch-idea/scripts/idea_store.py:845: `plan-evidence/` (code)
- glitch-idea/scripts/idea_store.py:982: `receipt.json` (code)
- glitch-idea/scripts/idea_store.py:982: `v1-state.json` (code)
- glitch-idea/scripts/idea_store.py:993: `plan-evidence/` (code)
- glitch-idea/scripts/idea_store.py:996: `state.json` (code)
- glitch-idea/scripts/idea_store.py:997: `archive/` (code)
- glitch-idea/scripts/idea_store.py:1142: `plan-evidence/` (code)
- glitch-idea/scripts/idea_store.py:1226: `history/` (code)
- glitch-idea/scripts/idea_store.py:1242: `history/` (code)
- glitch-idea/scripts/idea_store.py:1298: `history/` (code)
- glitch-idea/scripts/idea_store.py:1339: `state.json` (code)
- glitch-idea/scripts/idea_store.py:1396: `state.json` (code)
- glitch-idea/scripts/idea_store.py:1910: `history/` (code)
- glitch-idea/scripts/idea_store.py:1973: `plan-evidence/` (code)
- glitch-idea/scripts/idea_store.py:1979: `archive/` (code)
- glitch-idea/scripts/idea_store.py:1980: `archive/` (code)
- glitch-idea/scripts/idea_store.py:1981: `archive/` (code)
- glitch-idea/scripts/idea_store.py:2500: `history/` (code)
- glitch-idea/scripts/idea_transactions.py:39: `archive/` (code)
- glitch-idea/scripts/idea_transactions.py:39: `history/` (code)
- glitch-idea/scripts/idea_transactions.py:39: `removed/` (code)
- glitch-idea/scripts/idea_transactions.py:85: `history/` (code)
- glitch-idea/scripts/idea_transactions.py:104: `session-recovery/` (code)
- glitch-idea/scripts/idea_transactions.py:108: `session-recovery/` (code)
- glitch-idea/scripts/idea_transactions.py:128: `state.json` (code)
- glitch-idea/scripts/idea_transactions.py:191: `state.json` (code)
- glitch-idea/scripts/idea_transactions.py:225: `state.json` (code)
- glitch-idea/scripts/idea_transactions.py:226: `state.json` (code)
- glitch-idea/scripts/idea_transactions.py:250: `manifest.json` (code)
- glitch-idea/scripts/idea_transactions.py:276: `manifest.json` (code)
- glitch-idea/scripts/idea_transactions.py:287: `cleaned:manifest.json` (code)
- glitch-idea/scripts/idea_transactions.py:471: `state.json` (code)
- glitch-idea/scripts/idea_transactions.py:473: `state.json` (code)
- glitch-idea/scripts/idea_transactions.py:474: `state.json` (code)
- glitch-idea/tern-plugin/window.luau:15: `zero>/` (prose)
- glitch-idea/web/api.js:154: `history/` (code)
- glitch-idea/web/api.js:636: `requests/` (code)
- glitch-idea/web/assets/NOTICE.md:13: `web/` (code)
- install.py:18: `.glitch-idea-install.json` (code)
- install.py:24: `operations-reference.md` (code)
- install.py:24: `update.py` (code)
- install.py:176: `config.json` (code)
- install.py:177: `config.json` (code)
- install.py:183: `config.json` (code)
- install.py:298: `pyvenv.cfg` (code)
- install.py:318: `config.json` (code)
- tests/browser_flow_smoke.mjs:30: `config.json` (code)
- tests/browser_flow_smoke.mjs:650: `saved-plan.md` (code)
- tests/browser_flow_smoke.mjs:1199: `proto-bundle.zip` (code)
- tests/browser_flow_smoke.mjs:1199: `proto-shot-two.png` (code)
- tests/browser_flow_smoke.mjs:1199: `proto-shot.png` (code)
- tests/browser_flow_smoke.mjs:1214: `proto-bundle.zip` (code)
- tests/browser_flow_smoke.mjs:1214: `proto-shot.png` (code)
- tests/browser_flow_smoke.mjs:1488: `moved-idea.txt` (code)
- tests/browser_flow_smoke.mjs:1489: `moved-exploration.json` (code)
- tests/browser_flow_smoke.mjs:1493: `moved-assess.json` (code)
- tests/browser_flow_smoke.mjs:1495: `moved-plan.md` (code)
- tests/browser_flow_smoke.mjs:1548: `config.json` (code)
- tests/browser_flow_smoke.mjs:1687: `summary.json` (code)
- tests/browser_flow_smoke.mjs:1704: `summary.json` (code)
- tests/fixtures/make_store_v2.py:25: `v02.tar` (code)
- tests/fixtures/scrub_store.py:36: `tests/private-terms.txt` (code)
- tests/fixtures/scrub_store.py:100: `.transactions/` (code)
- tests/fixtures/scrub_store.py:100: `session-recovery/` (code)
- tests/fixtures/scrub_store.py:137: `history/` (code)
- tests/hermetic_cli.py:25: `config.json` (code)
- tests/native_probe.py:108: `fixture.json` (code)
- tests/native_probe.py:129: `agent.json` (code)
- tests/native_probe.py:441: `discovery.json` (code)
- tests/native_probe.py:445: `agent.json` (code)
- tests/native_probe.py:471: `discovery.json` (code)
- tests/test_activity_log.py:1: `activity.log` (code)
- tests/test_activity_log.py:25: `activity.log` (code)
- tests/test_activity_log.py:26: `activity.log` (code)
- tests/test_activity_log.py:44: `activity.log` (code)
- tests/test_activity_log.py:46: `activity.log` (code)
- tests/test_activity_log.py:60: `elsewhere.txt` (code)
- tests/test_activity_log.py:61: `activity.log` (code)
- tests/test_activity_log.py:63: `activity.log` (code)
- tests/test_agent_cli.py:36: `response.json` (code)
- tests/test_agent_cli.py:98: `.glitch-idea-install.json` (code)
- tests/test_agent_cli.py:101: `config.json` (code)
- tests/test_agent_cli.py:106: `config.json` (code)
- tests/test_agent_client.py:166: `credentials.json` (code)
- tests/test_agent_client.py:168: `credentials.json` (code)
- tests/test_agent_client.py:204: `one.png` (code)
- tests/test_agent_client.py:223: `p.zip` (code)
- tests/test_agent_client.py:252: `page.html` (code)
- tests/test_agent_client.py:255: `shot.png` (code)
- tests/test_agent_launch.py:362: `discovery.json` (code)
- tests/test_agent_memory.py:61: `../Memory.md` (code)
- tests/test_agent_memory.py:61: `Memory/../USER.md` (code)
- tests/test_agent_resume.py:56: `history/` (code)
- tests/test_agent_resume.py:239: `../IDEAS.md` (code)
- tests/test_agent_resume.py:242: `history/../proposal.md` (code)
- tests/test_assessment_source.py:146: `history/` (code)
- tests/test_asset_agent_door.py:54: `Proto.png` (code)
- tests/test_asset_agent_door.py:84: `a.png` (code)
- tests/test_asset_agent_door.py:84: `b.zip` (code)
- tests/test_asset_agent_door.py:123: `extra.png` (code)
- tests/test_asset_agent_door.py:131: `proto.zip` (code)
- tests/test_asset_agent_door.py:132: `proto.png` (code)
- tests/test_asset_evidence.py:30: `💡.png` (code)
- tests/test_asset_evidence.py:33: `💡.png` (code)
- tests/test_asset_evidence.py:81: `Changed.png` (code)
- tests/test_asset_evidence.py:107: `-->.png` (code)
- tests/test_asset_evidence.py:131: `heading.png` (code)
- tests/test_asset_evidence.py:167: `photo.jpg` (code)
- tests/test_asset_evidence.py:275: `../outside.md` (code)
- tests/test_asset_links.py:29: `Fixture.png` (code)
- tests/test_asset_links.py:32: `💡.png` (code)
- tests/test_asset_links.py:113: `../outside.md` (code)
- tests/test_asset_links.py:230: `history/` (code)
- tests/test_asset_projection.py:35: `Actual.png` (code)
- tests/test_asset_projection.py:101: `Actual.png` (code)
- tests/test_asset_projection.py:111: `archive-plan.md` (code)
- tests/test_asset_store.py:35: `💡.png` (code)
- tests/test_asset_store.py:81: `published:session-recovery/` (code)
- tests/test_asset_store.py:124: `session-recovery/` (code)
- tests/test_asset_store.py:190: `Other.png` (code)
- tests/test_asset_store.py:224: `Changed.png` (code)
- tests/test_asset_store.py:329: `assets/` (code)
- tests/test_asset_store.py:450: `published:session-recovery/` (code)
- tests/test_assets.py:71: `Café.png` (code)
- tests/test_assets.py:140: `💡.png` (code)
- tests/test_assets.py:151: `bad.jpg` (code)
- tests/test_assets.py:157: `a.png` (code)
- tests/test_assets.py:158: `a.html` (code)
- tests/test_assets.py:158: `a.txt` (code)
- tests/test_assets.py:159: `a.svg` (code)
- tests/test_assets.py:218: `published:session-recovery/` (code)
- tests/test_assets.py:267: `working-plan.md` (code)
- tests/test_assets.py:412: `assets/` (code)
- tests/test_assets.py:681: `archive/` (code)
- tests/test_assets.py:681: `assets/` (code)
- tests/test_assets.py:681: `plan-evidence/` (code)
- tests/test_assets.py:707: `archive/` (code)
- tests/test_assets.py:707: `assets/` (code)
- tests/test_assets.py:707: `plan-evidence/` (code)
- tests/test_assets.py:742: `published:session-recovery/` (code)
- tests/test_assets.py:770: `Owner.png` (code)
- tests/test_brand_static.py:1: `assets/` (code)
- tests/test_bridge.py:324: `state.json` (code)
- tests/test_bridge.py:634: `requests/` (code)
- tests/test_bridge.py:639: `requests/` (code)
- tests/test_bridge.py:729: `requests/` (code)
- tests/test_bridge.py:764: `requests/` (code)
- tests/test_bridge.py:809: `assets/` (code)
- tests/test_bridge.py:809: `history/` (code)
- tests/test_chain.py:38: `history/` (code)
- tests/test_chain.py:96: `history/` (code)
- tests/test_chain.py:146: `history/` (code)
- tests/test_chain.py:147: `history/` (code)
- tests/test_chain.py:177: `history/` (code)
- tests/test_chain.py:180: `history/` (code)
- tests/test_chain.py:181: `history/` (code)
- tests/test_chain.py:182: `history/` (code)
- tests/test_chain.py:183: `history/` (code)
- tests/test_chain.py:184: `history/` (code)
- tests/test_chain.py:187: `history/` (code)
- tests/test_chain_fixtures.py:19: `private-terms.txt` (code)
- tests/test_chain_fixtures.py:64: `tests/private-terms.txt` (code)
- tests/test_chain_store.py:64: `history/` (code)
- tests/test_chain_store.py:68: `history/` (code)
- tests/test_chain_store_held_edit.py:45: `history/` (code)
- tests/test_chain_v2.py:28: `history/` (code)
- tests/test_chain_v2.py:156: `history/` (code)
- tests/test_chain_v2.py:182: `history/` (code)
- tests/test_chain_v2.py:203: `history/` (code)
- tests/test_chain_v2.py:208: `history/` (code)
- tests/test_chain_v2.py:241: `history/` (code)
- tests/test_cli_service.py:185: `.glitch-idea-install.json` (code)
- tests/test_cli_service.py:186: `config.json` (code)
- tests/test_cli_service.py:198: `config.json` (code)
- tests/test_cli_service.py:203: `.glitch-idea-install.json` (code)
- tests/test_cli_service.py:204: `config.json` (code)
- tests/test_handoff.py:182: `state.json` (code)
- tests/test_handoff.py:200: `state.json` (code)
- tests/test_handoff.py:277: `working-plan.md` (code)
- tests/test_handoff_evidence.py:33: `design.png` (code)
- tests/test_handoff_evidence.py:78: `history/` (code)
- tests/test_handoff_evidence.py:133: `../foreign.md` (code)
- tests/test_handoff_evidence.py:155: `../outside.md` (code)
- tests/test_handoff_evidence.py:173: `relative.md` (code)
- tests/test_handoff_links.py:80: `history/` (code)
- tests/test_handoff_links.py:119: `../outside.md` (code)
- tests/test_handoff_links.py:123: `history/` (code)
- tests/test_handoff_links.py:161: `history/` (code)
- tests/test_handoff_links.py:209: `../foreign.md` (code)
- tests/test_handoff_service.py:80: `café.md` (code)
- tests/test_handoff_service.py:189: `plan.md` (code)
- tests/test_handoff_service.py:204: `café.txt` (code)
- tests/test_handoff_service.py:242: `assets/` (code)
- tests/test_handoff_service.py:242: `history/` (code)
- tests/test_handoff_store.py:42: `history/` (code)
- tests/test_handoff_store.py:136: `session-recovery/` (code)
- tests/test_handoff_store.py:159: `working-plan.md` (code)
- tests/test_handoff_store.py:263: `state.json` (code)
- tests/test_handoff_store.py:308: `published:history/` (code)
- tests/test_handoff_store.py:310: `published:session-recovery/` (code)
- tests/test_handoff_store.py:348: `session-recovery/` (code)
- tests/test_handoff_store.py:351: `history/` (code)
- tests/test_handoff_store.py:384: `session-recovery/` (code)
- tests/test_handoff_store.py:452: `session-recovery/` (code)
- tests/test_handoff_store.py:474: `café.txt` (code)
- tests/test_handoff_store.py:550: `assets/` (code)
- tests/test_handoff_store.py:550: `history/` (code)
- tests/test_hermetic_config.py:1: `config.json` (code)
- tests/test_hermetic_config.py:12: `config.json` (code)
- tests/test_hermetic_config.py:13: `config.json` (code)
- tests/test_hermetic_config.py:21: `config.json` (code)
- tests/test_hermetic_config.py:22: `config.json` (code)
- tests/test_hermetic_config.py:23: `.glitch-idea-install.json` (code)
- tests/test_hermetic_config.py:36: `config.json` (code)
- tests/test_hermetic_config.py:66: `config.json` (code)
- tests/test_hermetic_config.py:72: `config.json` (code)
- tests/test_idea.py:24: `config.json` (code)
- tests/test_idea.py:128: `config.json` (code)
- tests/test_idea.py:199: `state.json` (code)
- tests/test_idea.py:209: `r4.json` (code)
- tests/test_idea.py:245: `archived-plan.md` (code)
- tests/test_idea.py:266: `config.json` (code)
- tests/test_idea.py:296: `r4.json` (code)
- tests/test_idea.py:321: `config.json` (code)
- tests/test_idea.py:331: `.glitch-idea-install.json` (code)
- tests/test_idea.py:332: `config.json` (code)
- tests/test_idea.py:336: `config.json` (code)
- tests/test_import_cli.py:94: `text.txt` (code)
- tests/test_import_idea.py:78: `💡.png` (code)
- tests/test_import_idea.py:121: `history/` (code)
- tests/test_import_idea.py:124: `history/` (code)
- tests/test_import_idea.py:130: `history/` (code)
- tests/test_import_idea.py:189: `session-recovery/` (code)
- tests/test_import_idea.py:190: `session-recovery/` (code)
- tests/test_import_idea.py:191: `session-recovery/` (code)
- tests/test_import_idea.py:192: `session-recovery/` (code)
- tests/test_import_idea.py:252: `history/` (code)
- tests/test_import_idea.py:297: `session-recovery/` (code)
- tests/test_import_idea.py:324: `history/` (code)
- tests/test_import_idea.py:328: `history/` (code)
- tests/test_import_idea.py:486: `history/` (code)
- tests/test_install.py:27: `state.json` (code)
- tests/test_install.py:29: `config.json` (code)
- tests/test_install.py:63: `config.json` (code)
- tests/test_install.py:94: `.glitch-idea-install.json` (code)
- tests/test_install.py:100: `personal-note.txt` (code)
- tests/test_install.py:103: `config.json` (code)
- tests/test_install.py:105: `personal-note.txt` (code)
- tests/test_install.py:115: `config.json` (code)
- tests/test_install.py:126: `config.json` (code)
- tests/test_install.py:137: `elsewhere.py` (code)
- tests/test_install.py:140: `elsewhere.py` (code)
- tests/test_install.py:159: `config.json` (code)
- tests/test_install.py:165: `config.json` (code)
- tests/test_install.py:166: `glitch-idea/config.json` (code)
- tests/test_install.py:178: `config.json` (code)
- tests/test_install.py:180: `capture.txt` (code)
- tests/test_install.py:190: `state.json` (code)
- tests/test_install.py:198: `config.json` (code)
- tests/test_install.py:207: `config.json` (code)
- tests/test_install.py:209: `config.json` (code)
- tests/test_install.py:214: `config.json` (code)
- tests/test_install.py:222: `config.json` (code)
- tests/test_install.py:232: `config.json` (code)
- tests/test_install.py:237: `config.json` (code)
- tests/test_install.py:243: `config.json` (code)
- tests/test_install.py:267: `pyvenv.cfg` (code)
- tests/test_install.py:279: `config.json` (code)
- tests/test_install.py:291: `notes.txt` (code)
- tests/test_install.py:302: `notes.txt` (code)
- tests/test_install.py:307: `update.py` (code)
- tests/test_install.py:308: `operations-reference.md` (code)
- tests/test_install.py:321: `update.py` (code)
- tests/test_install.py:322: `operations-reference.md` (code)
- tests/test_install.py:331: `config.json` (code)
- tests/test_install.py:337: `config.json` (code)
- tests/test_install.py:399: `elsewhere.py` (code)
- tests/test_install.py:419: `config.json` (code)
- tests/test_install.py:423: `config.json` (code)
- tests/test_launcher_cli.py:41: `config.json` (code)
- tests/test_launcher_cli.py:54: `raw.txt` (code)
- tests/test_launcher_cli.py:55: `raw.txt` (code)
- tests/test_launcher_cli.py:76: `config.json` (code)
- tests/test_launcher_cli.py:86: `config.json` (code)
- tests/test_launcher_cli.py:107: `.glitch-idea-install.json` (code)
- tests/test_launcher_cli.py:125: `config.json` (code)
- tests/test_launcher_cli.py:219: `discovery.json` (code)
- tests/test_launcher_cli.py:220: `discovery.json` (code)
- tests/test_launcher_cli.py:259: `discovery.json` (code)
- tests/test_launcher_cli.py:267: `credentials.json` (code)
- tests/test_launcher_cli.py:271: `.glitch-idea-install.json` (code)
- tests/test_launcher_cli.py:273: `config.json` (code)
- tests/test_launcher_cli.py:277: `config.json` (code)
- tests/test_launcher_cli.py:279: `config.json` (code)
- tests/test_link_mode.py:183: `activity.log` (code)
- tests/test_link_mode.py:189: `canary.txt` (code)
- tests/test_link_mode.py:190: `canary.txt` (code)
- tests/test_link_mode_cli.py:49: `config.json` (code)
- tests/test_link_mode_cli.py:124: `config.json` (code)
- tests/test_link_mode_cli.py:132: `discovery.json` (code)
- tests/test_markdown.py:163: `history/` (code)
- tests/test_markdown.py:199: `plan-evidence/` (code)
- tests/test_markdown.py:283: `history/` (code)
- tests/test_markdown.py:344: `history/` (code)
- tests/test_markdown.py:374: `words.txt` (code)
- tests/test_markdown.py:378: `shape.json` (code)
- tests/test_markdown.py:385: `assessment.json` (code)
- tests/test_markdown.py:390: `working.md` (code)
- tests/test_markdown.py:393: `receipt.json` (code)
- tests/test_markdown.py:404: `plan-evidence/` (code)
- tests/test_markdown_store.py:60: `words.txt` (code)
- tests/test_markdown_store.py:65: `state.json` (code)
- tests/test_markdown_store.py:206: `assessment.json` (code)
- tests/test_markdown_store.py:252: `state.json` (code)
- tests/test_markdown_store.py:256: `state.json` (code)
- tests/test_markdown_store.py:273: `shape.json` (code)
- tests/test_markdown_store.py:278: `assessment.json` (code)
- tests/test_markdown_store.py:285: `plan.md` (code)
- tests/test_markdown_store.py:291: `r4.json` (code)
- tests/test_middle_flow.py:378: `legacy-input.txt` (code)
- tests/test_middle_flow.py:398: `legacy-edited-input.txt` (code)
- tests/test_middle_flow.py:491: `J10.png` (code)
- tests/test_middle_flow.py:564: `requests/` (code)
- tests/test_middle_flow.py:717: `plan.md` (code)
- tests/test_middle_flow.py:730: `archive/` (code)
- tests/test_migration.py:51: `state.json` (code)
- tests/test_migration.py:53: `plan-evidence/` (code)
- tests/test_migration.py:54: `archive/` (code)
- tests/test_migration.py:105: `state.json` (code)
- tests/test_migration.py:118: `state.json` (code)
- tests/test_migration.py:120: `state.json` (code)
- tests/test_migration.py:144: `state.json` (code)
- tests/test_migration.py:181: `state.json` (code)
- tests/test_migration.py:202: `state.json` (code)
- tests/test_migration.py:208: `state.json` (code)
- tests/test_migration.py:212: `state.json` (code)
- tests/test_migration.py:226: `state.json` (code)
- tests/test_migration.py:229: `state.json` (code)
- tests/test_migration.py:236: `state.json` (code)
- tests/test_migration.py:238: `state.json` (code)
- tests/test_migration.py:240: `state.json` (code)
- tests/test_migration.py:258: `outside.json` (code)
- tests/test_migration.py:258: `state.json` (code)
- tests/test_migration.py:270: `published:history/` (code)
- tests/test_migration.py:271: `cleaned:manifest.json` (code)
- tests/test_migration.py:271: `published:IDEAS.md` (code)
- tests/test_migration.py:271: `published:state.json` (code)
- tests/test_migration.py:288: `state.json` (code)
- tests/test_migration.py:291: `state.json` (code)
- tests/test_migration.py:292: `state.json` (code)
- tests/test_migration.py:293: `state.json` (code)
- tests/test_move_cli.py:43: `config.json` (code)
- tests/test_move_cli.py:138: `moved.md` (code)
- tests/test_move_cli.py:310: `delivered.md` (code)
- tests/test_move_cli.py:422: `file.txt` (code)
- tests/test_move_cli.py:423: `file.txt` (code)
- tests/test_move_store.py:27: `history/` (code)
- tests/test_move_store.py:110: `history/` (code)
- tests/test_move_store.py:110: `plan-evidence/` (code)
- tests/test_move_store.py:112: `history/` (code)
- tests/test_move_store.py:246: `history/` (code)
- tests/test_move_store.py:262: `history/` (code)
- tests/test_move_store.py:349: `history/` (code)
- tests/test_move_store.py:367: `plan-evidence/` (code)
- tests/test_move_store.py:376: `../outside.md` (code)
- tests/test_move_store.py:376: `history/` (code)
- tests/test_move_store.py:376: `plan-evidence/` (code)
- tests/test_move_store.py:376: `state.json` (code)
- tests/test_native_probe.py:241: `agent.json` (code)
- tests/test_native_probe.py:241: `fixture.json` (code)
- tests/test_orca_pages_prune.py:46: `orca-pages.json` (code)
- tests/test_orca_pages_prune.py:54: `orca-pages.json` (code)
- tests/test_orca_pages_prune.py:63: `orca-pages.json` (code)
- tests/test_orca_pages_prune.py:66: `orca-pages.json` (code)
- tests/test_orca_pages_prune.py:70: `orca-pages.json` (code)
- tests/test_orca_pages_prune.py:73: `orca-pages.json` (code)
- tests/test_orca_pages_prune.py:105: `orca-pages.json` (code)
- tests/test_orca_pages_prune.py:106: `.orca-pages.lock` (code)
- tests/test_platform.py:26: `idea.md` (code)
- tests/test_platform.py:40: `idea.md` (code)
- tests/test_platform.py:47: `idea.md` (code)
- tests/test_port_config_contract.py:35: `config.json` (code)
- tests/test_proposal_evidence.py:56: `history/` (code)
- tests/test_proposal_evidence.py:165: `../outside.md` (code)
- tests/test_proposal_evidence.py:166: `00.md` (code)
- tests/test_proposal_links.py:93: `../outside.md` (code)
- tests/test_proposal_store.py:62: `published:history/` (code)
- tests/test_proposal_store.py:64: `published:session-recovery/` (code)
- tests/test_proposal_store.py:109: `session-recovery/` (code)
- tests/test_proposal_store.py:212: `published:session-recovery/` (code)
- tests/test_proposal_store.py:320: `state.json` (code)
- tests/test_proposal_store.py:321: `state.json` (code)
- tests/test_proposal_store.py:326: `state.json` (code)
- tests/test_prototype_road.py:106: `r.png` (code)
- tests/test_prototype_road.py:107: `r.png` (code)
- tests/test_prototype_road.py:111: `r2.png` (code)
- tests/test_prototype_road.py:119: `x.png` (code)
- tests/test_prototype_road.py:125: `late.png` (code)
- tests/test_prototype_server.py:38: `secret.txt` (code)
- tests/test_prototype_server.py:88: `secret.txt` (code)
- tests/test_prototype_server.py:94: `secret.txt` (code)
- tests/test_rebuilt_tab_repair.py:180: `orca-pages.json` (code)
- tests/test_rebuilt_tab_repair.py:196: `orca-pages.json` (code)
- tests/test_remove_idea.py:156: `history/` (code)
- tests/test_remove_idea.py:498: `plan-evidence/` (code)
- tests/test_remove_idea.py:514: `r1.json` (code)
- tests/test_remove_idea.py:517: `archive/` (code)
- tests/test_remove_idea.py:521: `archive/` (code)
- tests/test_remove_idea.py:575: `💡.png` (code)
- tests/test_restore_parks_orphaned_session.py:80: `activity.log` (code)
- tests/test_resume_closes_old_tab.py:80: `orca-pages.json` (code)
- tests/test_resume_closes_old_tab.py:95: `orca-pages.json` (code)
- tests/test_runtime.py:124: `credentials.json` (code)
- tests/test_runtime.py:124: `discovery.json` (code)
- tests/test_runtime.py:124: `service.lock` (code)
- tests/test_runtime.py:143: `credentials.json` (code)
- tests/test_runtime.py:144: `service.lock` (code)
- tests/test_runtime.py:149: `credentials.json` (code)
- tests/test_runtime.py:152: `service.lock` (code)
- tests/test_runtime.py:238: `credentials.json` (code)
- tests/test_runtime.py:262: `service.lock` (code)
- tests/test_runtime.py:271: `service.lock` (code)
- tests/test_runtime.py:286: `discovery.json` (code)
- tests/test_runtime.py:287: `discovery.json` (code)
- tests/test_runtime.py:361: `discovery.json` (code)
- tests/test_runtime_identity.py:65: `credentials.json` (code)
- tests/test_runtime_root_fallback.py:23: `config.json` (code)
- tests/test_runtime_root_fallback.py:67: `config.json` (code)
- tests/test_service.py:259: `published:session-recovery/` (code)
- tests/test_store_requests.py:122: `session-recovery/` (code)
- tests/test_store_requests.py:279: `published:IDEAS.md` (code)
- tests/test_store_requests.py:279: `published:session-recovery/` (code)
- tests/test_store_requests.py:304: `published:session-recovery/` (code)
- tests/test_store_requests.py:338: `state.json` (code)
- tests/test_store_requests.py:341: `state.json` (code)
- tests/test_transactions.py:106: `published:IDEAS.md` (code)
- tests/test_transactions.py:115: `published:IDEAS.md` (code)
- tests/test_transactions.py:116: `cleaned:manifest.json` (code)
- tests/test_transactions.py:186: `glitch-idea/config.json` (code)
- tests/test_transactions.py:186: `state.json` (code)
- tests/test_transactions.py:187: `idea_bad.md` (code)
- tests/test_transactions.py:214: `config.json` (code)
- tests/test_transactions.py:231: `someone-else.txt` (code)
- tests/test_transactions.py:309: `state.json` (code)
- tests/test_transactions.py:315: `published:state.json` (code)
- tests/test_transactions.py:319: `state.json` (code)
- tests/test_transactions.py:321: `published:IDEAS.md` (code)
- tests/test_transactions.py:321: `published:state.json` (code)
- tests/test_transactions.py:323: `state.json` (code)
- tests/test_transactions.py:328: `published:IDEAS.md` (code)
- tests/test_transactions.py:329: `cleaned:manifest.json` (code)
- tests/test_transactions.py:329: `published:state.json` (code)
- tests/test_transactions.py:334: `state.json` (code)
- tests/test_transactions.py:345: `state.json` (code)
- tests/test_transactions.py:350: `state.json` (code)
- tests/test_transactions.py:385: `manifest.json` (code)
- tests/test_transactions.py:404: `state.json` (code)
- tests/test_transactions.py:408: `state.json` (code)
- tests/test_transactions.py:453: `published:IDEAS.md` (code)
- tests/test_transactions.py:496: `idea_bad.md` (code)
- tests/test_transactions.py:507: `state.json` (code)
- tests/test_tunnel_probe.py:121: `discovery.json` (code)
- tests/test_tunnel_probe.py:125: `discovery.json` (code)
- tests/test_tunnel_probe.py:126: `discovery.json` (code)
- tests/test_tunnel_probe.py:140: `discovery.json` (code)
- tests/test_visualize_step.py:59: `assets/` (code)
- tests/test_visualize_step.py:100: `bundle.zip` (code)
- tests/test_visualize_step.py:129: `Other.png` (code)
- tests/test_visualize_step.py:135: `Other.png` (code)
- tests/test_visualize_step.py:217: `Other.png` (code)
- tests/test_web_assets.py:60: `private-terms.txt` (code)
- tests/test_web_assets.py:402: `STATE.md` (code)
- tests/test_web_assets.py:402: `private-terms.txt` (code)
- tests/test_web_assets.py:567: `tokens.json` (code)
- tests/test_web_assets.py:568: `tokens.json` (code)
- tests/test_web_assets.py:586: `../up.png` (code)
- tests/test_web_assets.py:595: `x.png` (code)
- tests/test_workflow_schema.py:290: `words.txt` (code)
- tests/test_workflow_schema.py:303: `assessment.json` (code)
- tests/web/assess-clarity.test.mjs:9: `../folds.js` (code)
- tests/web/assess.test.mjs:10: `../folds.js` (code)
- tests/web/assess.test.mjs:84: `history/` (code)
- tests/web/assessment-controller.test.mjs:73: `history/` (code)
- tests/web/capture-attachments.test.mjs:11: `../folds.js` (code)
- tests/web/capture-attachments.test.mjs:18: `original.md` (code)
- tests/web/capture-attachments.test.mjs:51: `blob:fixture/` (code)
- tests/web/capture-attachments.test.mjs:62: `original.md` (code)
- tests/web/capture-attachments.test.mjs:154: `./outside.js` (code)
- tests/web/conversation.test.mjs:9: `../folds.js` (code)
- tests/web/conversation.test.mjs:9: `steps/` (code)
- tests/web/cp3-review-fixes.test.mjs:10: `steps/` (code)
- tests/web/cp3-review-fixes.test.mjs:11: `../folds.js` (code)
- tests/web/cp3-review-fixes.test.mjs:178: `history/` (code)
- tests/web/discovery-proposals.test.mjs:10: `../folds.js` (code)
- tests/web/discovery-proposals.test.mjs:90: `history/` (code)
- tests/web/discovery.test.mjs:9: `../folds.js` (code)
- tests/web/exploration-proposals.test.mjs:11: `../folds.js` (code)
- tests/web/exploration-proposals.test.mjs:94: `history/` (code)
- tests/web/exploration.test.mjs:9: `../folds.js` (code)
- tests/web/folds.test.mjs:300: `requests/` (code)
- tests/web/folds.test.mjs:385: `./other.css` (code)
- tests/web/handoff-api.test.mjs:18: `history/` (code)
- tests/web/handoff-api.test.mjs:103: `../../literal💡.md` (code)
- tests/web/handoff-api.test.mjs:108: `wrong.png` (code)
- tests/web/handoff-api.test.mjs:172: `relative/` (code)
- tests/web/handoff-controller.test.mjs:35: `history/` (code)
- tests/web/handoff.test.mjs:9: `../folds.js` (code)
- tests/web/handoff.test.mjs:69: `history/` (code)
- tests/web/method-cards.test.mjs:9: `../folds.js` (code)
- tests/web/method.test.mjs:10: `../folds.js` (code)
- tests/web/method.test.mjs:82: `history/` (code)
- tests/web/prior-art.test.mjs:10: `../folds.js` (code)
- tests/web/prior-art.test.mjs:10: `steps/` (code)
- tests/web/proposals.test.mjs:46: `history/` (code)
- tests/web/proposals.test.mjs:536: `../private.md` (code)
- tests/web/proposals.test.mjs:539: `../private.md` (code)
- tests/web/review-summary.test.mjs:8: `../folds.js` (code)
- tests/web/upload-api.test.mjs:10: `design.md` (code)
- tests/web/visualize.test.mjs:12: `../folds.js` (code)
- tests/web/visualize.test.mjs:22: `draft.md` (code)
- tests/web/visualize.test.mjs:47: `saved.md` (code)
- tests/web/visualize.test.mjs:127: `blob:fixture/` (code)
- tests/web/visualize.test.mjs:155: `second.txt` (code)
- tests/web/visualize.test.mjs:160: `empty.md` (code)
- tests/web/visualize.test.mjs:160: `wrong.txt` (code)
- tests/web/visualize.test.mjs:170: `draft.md` (code)
- tests/web/visualize.test.mjs:171: `draft.md` (code)
- tests/web/visualize.test.mjs:213: `chosen.md` (code)
- tests/web/visualize.test.mjs:213: `not-chosen.md` (code)
- tests/web/visualize.test.mjs:219: `incomplete.md` (code)
- tests/web/visualize.test.mjs:223: `draft.md` (code)
- tests/web/visualize.test.mjs:377: `next.md` (code)
- tests/web/visualize.test.mjs:378: `next.md` (code)
- tests/web/visualize.test.mjs:381: `bundle.zip` (code)
- tests/web/visualize.test.mjs:381: `notes.md` (code)
- tests/web/visualize.test.mjs:384: `bundle.zip` (code)
- tests/web/visualize.test.mjs:384: `notes.md` (code)
- tests/web/visualize.test.mjs:395: `draft.md` (code)
- tests/web/visualize.test.mjs:414: `next.md` (code)
- tests/web/visualize.test.mjs:416: `next.md` (code)
- tests/web/visualize.test.mjs:460: `history/` (code)
- tests/web/visualize.test.mjs:461: `prototype.png` (code)
- tests/web/visualize.test.mjs:461: `prototype.zip` (code)
- tests/web/visualize.test.mjs:475: `design.md` (code)
- tests/web/visualize.test.mjs:532: `design.md` (code)
- tests/web/visualize.test.mjs:560: `sketch.png` (code)
- tests/web/visualize.test.mjs:565: `draft.md` (code)
- tests/web/visualize.test.mjs:566: `half.md` (code)

### Dangling references into a folder the repository does not have (often one the workflow creates when it runs) (110)

- README.md:80: `venv>\Scripts\python.exe` (code)
- README.md:257: `ideas/IDEAS.md` (code)
- docs/acceptance-browser-flow.md:97: `skill>/scripts/idea.py` (code)
- docs/cp1-validation.md:70: `evidence/cp1/` (code)
- docs/cp2-validation.md:121: `evidence/cp2/full-python.log` (prose)
- docs/cp2-validation.md:122: `evidence/cp2/product-evidence-manifest.json` (prose)
- docs/cp4-validation.md:86: `evidence/cp4/` (code)
- docs/design-provenance.md:44: `assets/fonts/` (code)
- docs/history/pull-requests/PR-005.md:42: `review-briefs/kimi-SKILLS96-c170dee-verdict.md` (prose)
- docs/history/pull-requests/PR-006.md:34: `paired/replaced/` (prose)
- docs/markdown-format.md:39: `history/backlog/rN.md` (code)
- docs/markdown-format.md:280: `migration-recovery/v1-state.json` (code)
- docs/orca-contract.md:108: `references/browser.md` (code)
- docs/orca-contract.md:275: `evidence/cp2/codex-idle-observed.json` (code)
- docs/orca-contract.md:283: `evidence/cp2/codex-idle-repeat-proof.json` (code)
- docs/orca-contract.md:297: `evidence/cp2/codex-interrupt-correlated.json` (prose)
- docs/orca-contract.md:311: `evidence/cp2/codex-compact-correlated.json` (code)
- docs/orca-contract.md:336: `evidence/cp2/claude-roundtrip-idle-verified.json` (code)
- docs/orca-contract.md:350: `evidence/cp2/claude-lifecycle-root-verified.json` (code)
- docs/orca-contract.md:376: `evidence/cp2/claude-compact-root-verified.json` (code)
- glitch-idea/SKILL.md:80: `venv>\Scripts\python.exe` (code)
- glitch-idea/references/commands.md:10: `repository-root>/config.json` (code)
- glitch-idea/references/commands.md:10: `skill-dir>/config.json` (code)
- glitch-idea/references/commands.md:141: `runtime-root>/activity.log` (code)
- glitch-idea/references/commands.md:269: `ideas/plan-evidence/PLAN_ID.md` (code)
- glitch-idea/references/commands.md:271: `ideas/archive/ID/rN.json` (code)
- glitch-idea/scripts/idea_asset_evidence.py:115: `assets/blobs/` (code)
- glitch-idea/scripts/idea_asset_evidence.py:176: `assets/evidence/` (code)
- glitch-idea/scripts/idea_assets.py:142: `assets/staging/` (code)
- glitch-idea/scripts/idea_launch.py:537: `runtime_root>/activity.log` (code)
- glitch-idea/scripts/idea_ssh.py:405: `Programs\Tern\tern.com` (code)
- glitch-idea/scripts/idea_store.py:395: `history/removed/` (code)
- glitch-idea/scripts/idea_store.py:424: `history/removed/` (code)
- glitch-idea/scripts/idea_store.py:1592: `assets/evidence/` (code)
- glitch-idea/scripts/idea_store.py:2108: `assets/blobs/` (code)
- glitch-idea/scripts/idea_store.py:2111: `assets/staging/` (code)
- glitch-idea/scripts/idea_store.py:2126: `assets/blobs/` (code)
- glitch-idea/scripts/idea_store.py:2488: `assets/blobs/` (code)
- glitch-idea/scripts/idea_transactions.py:32: `migration-recovery/v1-state.json` (code)
- glitch-idea/scripts/idea_transactions.py:33: `migration-recovery/receipt.json` (code)
- glitch-idea/scripts/idea_transactions.py:37: `history/removed/` (code)
- glitch-idea/scripts/idea_transactions.py:108: `assets/evidence/` (code)
- glitch-idea/web/steps/visualize.js:65: `assets/blobs/` (code)
- install.py:128: `Scripts/python.exe` (code)
- tests/browser_flow_smoke.mjs:996: `is/.test` (code)
- tests/browser_flow_smoke.mjs:1016: `is/.test` (code)
- tests/browser_flow_smoke.mjs:1112: `is/.test` (code)
- tests/browser_flow_smoke.mjs:1141: `is/.test` (code)
- tests/browser_flow_smoke.mjs:1253: `version/.test` (code)
- tests/browser_flow_smoke.mjs:1274: `is/.test` (code)
- tests/browser_flow_smoke.mjs:1451: `Resume/.test` (code)
- tests/browser_flow_smoke.mjs:1461: `yet/.test` (code)
- tests/browser_flow_smoke.mjs:1532: `key/.test` (code)
- tests/test_agent_memory.py:19: `Memory/USER.md#planning` (code)
- tests/test_agent_memory.py:63: `Memory/private\\notes.md` (code)
- tests/test_asset_evidence.py:74: `assets/evidence/` (code)
- tests/test_asset_evidence.py:99: `assets/blobs/` (code)
- tests/test_asset_evidence.py:118: `assets/evidence/` (code)
- tests/test_asset_evidence.py:139: `assets/evidence/` (code)
- tests/test_asset_evidence.py:195: `assets/blobs/` (code)
- tests/test_asset_evidence.py:196: `assets/blobs/` (code)
- tests/test_asset_evidence.py:196: `assets\\blobs\\file.bin` (code)
- tests/test_asset_evidence.py:275: `assets/evidence/` (code)
- tests/test_asset_links.py:90: `assets/evidence/` (code)
- tests/test_asset_links.py:120: `assets/evidence/` (code)
- tests/test_asset_links.py:224: `assets/evidence/name.md` (code)
- tests/test_asset_links.py:236: `assets/staging/upload_own.nonce.part` (code)
- tests/test_asset_links.py:244: `assets/staging/bad.part` (code)
- tests/test_asset_store.py:79: `published:assets/evidence/` (code)
- tests/test_encode_state_unchanged.py:92: `handoffs/extra.json` (code)
- tests/test_import_idea.py:122: `assets/evidence/` (code)
- tests/test_import_idea.py:148: `history/backlog/` (code)
- tests/test_install.py:247: `Scripts/python.exe` (code)
- tests/test_install.py:274: `Scripts/python.exe` (code)
- tests/test_install.py:406: `Scripts/python.exe` (code)
- tests/test_markdown.py:366: `helper/config.json` (code)
- tests/test_markdown.py:367: `helper/scripts/idea.py` (code)
- tests/test_move_store.py:331: `relative/ideas/` (code)
- tests/test_remove_idea.py:87: `history/removed/` (code)
- tests/test_remove_idea.py:157: `assets/evidence/` (code)
- tests/test_remove_idea.py:191: `history/removed/` (code)
- tests/test_remove_idea.py:407: `assets/staging/` (code)
- tests/test_remove_idea.py:450: `assets/staging/` (code)
- tests/test_skill_text.py:318: `history/removed/` (code)
- tests/test_ssh_mode.py:449: `Programs\\Tern\\tern.com` (code)
- tests/test_transactions.py:49: `migration-recovery/receipt.json` (code)
- tests/test_transactions.py:49: `migration-recovery/v1-state.json` (code)
- tests/test_transactions.py:50: `migration-recovery/receipt.json` (code)
- tests/test_transactions.py:50: `migration-recovery/v1-state.json` (code)
- tests/test_transactions.py:187: `blob/file.bin` (code)
- tests/test_transactions.py:187: `migration-recovery/v1-state.json` (code)
- tests/test_transactions.py:264: `history/backlog/metadata/` (code)
- tests/test_transactions.py:264: `history/idea_bad/metadata/` (code)
- tests/test_web_assets.py:186: `assets/fonts/` (code)
- tests/test_web_assets.py:543: `scripts/stray.ttf` (code)
- tests/test_web_assets.py:543: `web/assets/extra.png` (code)
- tests/test_web_assets.py:543: `web/assets/fonts/BlastworksSans-Bold.woff2` (code)
- tests/test_web_assets.py:543: `web/assets/fonts/other.woff2` (code)
- tests/test_web_assets.py:585: `./assets/other.png` (code)
- tests/test_web_assets.py:586: `assets/fonts/evil.woff2` (code)
- tests/web/capture-attachments.test.mjs:59: `assets/evidence/` (code)
- tests/web/capture-attachments.test.mjs:63: `assets/blobs/` (code)
- tests/web/capture-attachments.test.mjs:86: `assets/blobs/` (code)
- tests/web/upload-api.test.mjs:48: `bad\ud800.md` (code)
- tests/web/upload-api.test.mjs:63: `../../private/design.md` (code)
- tests/web/visualize.test.mjs:43: `assets/evidence/` (code)
- tests/web/visualize.test.mjs:49: `assets/blobs/` (code)
- tests/web/visualize.test.mjs:92: `assets/blobs/` (code)
- tests/web/visualize.test.mjs:161: `bad\ud800.md` (code)
- tests/web/visualize.test.mjs:298: `assets/staging/private.part` (code)

### Not scanned for references (0)

None.

### Reference depth, directly reached files (90)

- LICENSE: depth 1, from README.md
- README.md: depth 0
- config.example.json: depth 1, from README.md
- docs/browser-runbook.md: depth 1, from README.md
- docs/cp4-validation.md: depth 2, from docs/handoff-format.md
- docs/handoff-format.md: depth 1, from README.md
- docs/history/pull-requests/PR-001.md: depth 1, from docs/history/pull-requests/README.md
- docs/history/pull-requests/PR-002.md: depth 1, from docs/history/pull-requests/README.md
- docs/history/pull-requests/PR-003.md: depth 1, from docs/history/pull-requests/README.md
- docs/history/pull-requests/PR-004.md: depth 1, from docs/history/pull-requests/README.md
- docs/history/pull-requests/PR-005.md: depth 1, from docs/history/pull-requests/README.md
- docs/history/pull-requests/PR-006.md: depth 1, from docs/history/pull-requests/README.md
- docs/history/pull-requests/PR-007.md: depth 1, from docs/history/pull-requests/README.md
- docs/history/pull-requests/PR-008.md: depth 1, from docs/history/pull-requests/README.md
- docs/history/pull-requests/README.md: depth 0
- docs/markdown-format.md: depth 1, from README.md
- docs/screenshots/01-capture.png: depth 1, from README.md
- docs/screenshots/02-priorities.png: depth 1, from README.md
- docs/screenshots/03-methods.png: depth 1, from README.md
- docs/screenshots/04-discovery.png: depth 1, from README.md
- docs/screenshots/05-exploration.png: depth 1, from README.md
- docs/screenshots/06-visualize.png: depth 1, from README.md
- docs/screenshots/07-assess.png: depth 1, from README.md
- docs/screenshots/08-review.png: depth 1, from README.md
- docs/screenshots/09-review-planning-prompt.png: depth 1, from README.md
- docs/workflow-api.md: depth 2, from docs/browser-runbook.md
- glitch-idea/PyYAML-MIT-NOTICE.txt: depth 2, from docs/markdown-format.md
- glitch-idea/SKILL.md: depth 0
- glitch-idea/references/commands.md: depth 1, from README.md
- glitch-idea/references/methods.md: depth 1, from README.md
- glitch-idea/requirements.txt: depth 1, from README.md
- glitch-idea/scripts/idea.py: depth 1, from README.md
- glitch-idea/scripts/idea_chain.py: depth 1, from README.md
- glitch-idea/scripts/idea_handoff_evidence.py: depth 2, from docs/handoff-format.md
- glitch-idea/scripts/idea_sessions.py: depth 2, from docs/browser-runbook.md
- glitch-idea/scripts/idea_workflow.py: depth 2, from docs/history/pull-requests/PR-002.md
- glitch-idea/tern-plugin/README.md: depth 0
- glitch-idea/web/api.js: depth 3, from tests/web/app-render.test.mjs
- glitch-idea/web/app.js: depth 3, from tests/test_rebuilt_tab_repair.py
- glitch-idea/web/assets/bwpm/bundle.css: depth 4, from glitch-idea/web/index.html
- glitch-idea/web/assets/fonts/BlastworksSans-ExtraBold.woff2: depth 4, from glitch-idea/web/styles.css
- glitch-idea/web/assets/fonts/BlastworksSans-Regular.woff2: depth 4, from glitch-idea/web/styles.css
- glitch-idea/web/assets/fonts/BlastworksSans-SemiBold.woff2: depth 4, from glitch-idea/web/styles.css
- glitch-idea/web/assets/logo.svg: depth 4, from glitch-idea/web/index.html
- glitch-idea/web/folds.js: depth 2, from docs/history/pull-requests/PR-002.md
- glitch-idea/web/ideas.js: depth 4, from glitch-idea/web/app.js
- glitch-idea/web/index.html: depth 3, from tests/web/app-render.test.mjs
- glitch-idea/web/setup.js: depth 4, from glitch-idea/web/app.js
- glitch-idea/web/steps/assess.js: depth 4, from glitch-idea/web/app.js
- glitch-idea/web/steps/discovery.js: depth 4, from glitch-idea/web/app.js
- glitch-idea/web/steps/exploration.js: depth 4, from glitch-idea/web/app.js
- glitch-idea/web/steps/method.js: depth 4, from glitch-idea/web/app.js
- glitch-idea/web/steps/review.js: depth 3, from tests/web/plain-words.test.mjs
- glitch-idea/web/steps/visualize.js: depth 3, from tests/web/plain-words.test.mjs
- glitch-idea/web/styles.css: depth 3, from tests/web/app-render.test.mjs
- install.py: depth 1, from README.md
- tests/fake_workflow_api.py: depth 3, from docs/workflow-api.md
- tests/fixtures/handoff_plan_validator.py: depth 3, from docs/cp4-validation.md
- tests/fixtures/markdown/IDEAS.md: depth 1, from glitch-idea/SKILL.md
- tests/fixtures/markdown/history/idea_00000000000000000000000000000001/r1.md: depth 3, from tests/fixtures/markdown/idea_00000000000000000000000000000001.md
- tests/fixtures/markdown/idea_00000000000000000000000000000001.md: depth 2, from tests/fixtures/markdown/IDEAS.md
- tests/fixtures/store-v03-preprior/IDEAS.md: depth 1, from glitch-idea/SKILL.md
- tests/fixtures/store-v03-preprior/history/backlog/r1.md: depth 2, from tests/fixtures/store-v03-preprior/IDEAS.md
- tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/metadata/c8ec69b5c99a05c1685a2fe143ffbb9372a3f113316434bb590e26d49d37112e.md: depth 3, from tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md
- tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r1.md: depth 3, from tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md
- tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r2.md: depth 3, from tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md
- tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r3.md: depth 3, from tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md
- tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r4.md: depth 3, from tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md
- tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r5.md: depth 3, from tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md
- tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r6.md: depth 3, from tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md
- tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r7.md: depth 3, from tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md
- tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md: depth 2, from tests/fixtures/store-v03-preprior/IDEAS.md
- tests/fixtures/store-v2/IDEAS.md: depth 1, from glitch-idea/SKILL.md
- tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r1.md: depth 3, from tests/fixtures/store-v2/idea_11111111111111111111111111111111.md
- tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r2.md: depth 3, from tests/fixtures/store-v2/idea_11111111111111111111111111111111.md
- tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r3.md: depth 3, from tests/fixtures/store-v2/idea_11111111111111111111111111111111.md
- tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r4.md: depth 3, from tests/fixtures/store-v2/idea_11111111111111111111111111111111.md
- tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r5.md: depth 3, from tests/fixtures/store-v2/idea_11111111111111111111111111111111.md
- tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r6.md: depth 3, from tests/fixtures/store-v2/idea_11111111111111111111111111111111.md
- tests/fixtures/store-v2/history/idea_22222222222222222222222222222222/r1.md: depth 3, from tests/fixtures/store-v2/idea_22222222222222222222222222222222.md
- tests/fixtures/store-v2/history/idea_22222222222222222222222222222222/r2.md: depth 3, from tests/fixtures/store-v2/idea_22222222222222222222222222222222.md
- tests/fixtures/store-v2/idea_11111111111111111111111111111111.md: depth 2, from tests/fixtures/store-v2/IDEAS.md
- tests/fixtures/store-v2/idea_22222222222222222222222222222222.md: depth 2, from tests/fixtures/store-v2/IDEAS.md
- tests/test_handoff.py: depth 3, from docs/cp4-validation.md
- tests/test_legacy_prior_art.py: depth 2, from docs/history/pull-requests/PR-003.md
- tests/test_rebuilt_tab_repair.py: depth 2, from docs/history/pull-requests/PR-006.md
- tests/test_remove_idea_in_use.py: depth 2, from docs/history/pull-requests/PR-008.md
- tests/test_restore_parks_orphaned_session.py: depth 2, from docs/history/pull-requests/PR-008.md
- tests/web/app-render.test.mjs: depth 2, from docs/history/pull-requests/PR-003.md
- tests/web/plain-words.test.mjs: depth 2, from docs/history/pull-requests/PR-005.md

## 4 What the text asks for

4a 519 · 4b 68 · 4c 461 · 4d 0 hits on 1046 lines (33 read by a model, 92 in scripts, 60 human-facing, 861 test data); benign share not measured (stage 6 labels did not run). Hosts: 40, 30 not named in the docs. Confirm-first or prohibited actions in instruction text: 6, 1 with no confirmation step, 0 stated as prohibitions. Conditionals: 18 absence, 11 error, 3 clock, 2 version. Definitions: 12, 1 conflict, 0 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 5, 1 flagged. Lines that look like committed secrets: 0 (plus 5 in test data), by gitleaks.

Validation: PASS (gate 153/153, negative 121/121, recall 43/43; measured 2026-11-02, same code and fixtures)

Every hit is a locator. Benign share not measured here; stage 6 labels, when run, read the lines a model sees (section 6). Audience is who the file addresses, by path.

### 4a Reaching out

#### phrase.K.exfil (464 lines)

Patterns: K.assembly-code 438, K.data-flow 6, K.http-verb 19, K.md-carrier 1

- docs/acceptance-browser-flow.md:158 [K.data-flow] (human): `Evidence to record: the Orca version, local operating system, the remote host's operating system, the commit, the tunnel command (without credentials), a screenshot per numbered step, the upload file names and sizes, and each error code observed.`
- docs/browser-api.md:49 [K.data-flow] (human): `` from the address bar with `history.replaceState` before anything else, and\nredeems the code through `POST /pair` itself; the operator types nothing. ``
- docs/browser-api.md:69 [K.data-flow] (human) (stated as a prohibition (never)): `` persistent storage, never logged or put in a URL) and sends it as the\n`X-Idea-Tab` header on every `/api/v1/*` call, including `GET /session`. Cookies\nare not port-scoped, so another listener on the same loopback address could ``
- docs/browser-runbook.md:167 [K.http-verb] (human): `` | `ssh_client_no_curl` | `curl` is missing on your computer. | Install `curl` there. | ``
- docs/cp4-validation.md:97 [K.data-flow] (human): `native picker nor remote-client upload. Headless clipboard API success/denial and`
- glitch-idea/references/commands.md:77 [K.data-flow] (model): `` Missing or malformed Orca selectors fail with `origin_missing` (and selectors in system mode with `usage`) before any session exists; fix the arguments and rerun without `--resume`. Later Orca failures happen after the session exists, so the error carries `binding_id`, `session_id` and `resume_required: true`, but not the origin: run `session-open --resume binding_ID` to get the origin and a fresh pairing code. The typed codes are `origin_missing`, `identity_mismatch`, `runtime_unavailable`, `route_unavailable`, `orca_error`, `cli_missing`, `cli_unavailable`, `cli_timeout`, `cli_failed`, `unsupported_payload` and `unsafe_url`. For a post-session failure, recovery is to fix the Orca connection or selector and rerun `browser-open` with `--resume binding_ID` from that error, or to run `session-open --resume binding_ID` and open the origin it prints in a system browser (through the standing tunnel when remote). The helper never falls back silently. Other launcher codes include `system_browser_unavailable`, `service_readiness_timeout` (the service is still loading a large store; rerun the same `browser-open` once, and never rerun after `owner_unavailable`), `service_spawn_failed`, `session_capacity_exhausted`, `binding_capacity` (a ninth session while all eight are unfinished or still open; the error carries `sessions`, rows of `binding_id`, `selected_idea_id`, `title`, `finished` and `in_use`, and never a credential or pairing code; resume one with `--resume`, or discard one with `session-discard`) and `binding_not_found`. ``
- glitch-idea/references/commands.md:283 [K.data-flow] (model): `` `deliver idea_ID --ref TEXT --actor A` needs a moved idea (otherwise `not_moved`). The reference is one line, no control characters, 1 to 500 characters. It writes the immutable `history/<id>/delivered.md` and a `glitch_idea_delivered` index link. The same reference again is `repeated:true`; a different one is `delivery_conflict`. There is no un-deliver. ``
- glitch-idea/scripts/idea_agent_client.py:192 [K.assembly-code] (tool): `request = (method + ' ' + path + ' HTTP/1.0\r\n' + ''.join(`
- glitch-idea/scripts/idea_assets.py:59 [K.assembly-code] (tool): `upload_id='upload_'+'0'*32,asset_id='asset_'+'0'*32,session_id=app.context.session_id,`
- glitch-idea/scripts/idea_domain.py:66 [K.assembly-code] (tool): `require(isinstance(value,dict) and set(value)==keys,name+' must have exactly these keys: '+', '.join(sorted(keys)))`
- glitch-idea/scripts/idea_handoff_evidence.py:360 [K.assembly-code] (tool): `'\n\n## Planning source\n'+''.join('    '+line+'\n' for line in _literal(planning, 2).split('\n')))`
- glitch-idea/scripts/idea_markdown.py:828 [K.assembly-code] (tool): `lines.append('| ' + ' | '.join((str(n), markdown_link(key, key + '.md'), idea['status'],`
- glitch-idea/scripts/idea_ssh.py:127 [K.assembly-code] (tool): `raw = b''.join(bytes.fromhex(hexed[i:i + 8])[::-1] for i in range(0, len(hexed), 8))`
- glitch-idea/scripts/idea_ssh.py:376 [K.http-verb] (tool): `done = _ssh(runner, alias, f'curl -s -m 5 "http://127.0.0.1:{int(port)}/api/v1/tunnel-probe?nonce={nonce}"', timeout=20)`
- glitch-idea/scripts/idea_store.py:203 [K.assembly-code] (tool): `validate_record(_agent_record(evidence,actor,'proposal_'+'0'*32,'validation-only'))`
- glitch-idea/scripts/idea_workflow.py:97 [K.assembly-code] (tool): `require(set(value) == set(keys), name+' must contain exactly: '+', '.join(sorted(keys)))`
- glitch-idea/scripts/idea_workflow.py:461 [K.assembly-code] (tool): `require(not missing, 'Acceptance requires: '+', '.join(missing), 'not_ready')`
- glitch-idea/scripts/idea_workflow.py:507 [K.assembly-code] (tool): `require(required <= set(value), 'workflow must contain exactly: '+', '.join(sorted(required))+' (and optional hand)')`
- glitch-idea/scripts/idea_workflow_v2.py:40 [K.assembly-code] (tool): `require(set(value) == set(keys), name+' must contain exactly: '+', '.join(sorted(keys)))`
- glitch-idea/scripts/idea_workflow_v2.py:305 [K.assembly-code] (tool): `require(not missing, 'Acceptance requires: '+', '.join(missing), 'not_ready')`
- glitch-idea/web/index.html:29 [K.md-carrier] (model): `<section id="connection" class="connection" aria-label="Connect this browser" hidden></section>`
- glitch-idea/web/setup.js:83 [K.assembly-code] (tool): `urlInput = element('input', '', 'g-input'); urlInput.id = 'setup-url'; urlInput.type = 'text'; urlInput.placeholder = 'https:' + '//…'; urlInput.value = ui.url; // placeholder built in two parts: shipped files carry no literal URL`
- glitch-idea/web/steps/assess.js:59 [K.assembly-code] (tool): `const shown = assessment.method === 'wsjf' ? '(' + i.value + ' + ' + i.time_criticality + ' + ' + i.enablement + ') / ' + i.effort :`
- tests/browser_flow_smoke.mjs:106 [K.http-verb] (test-data): `const getJson = async (url, init = {}) => (await fetch(url, {...init, signal: AbortSignal.timeout(10000)})).json();`
- tests/browser_flow_smoke.mjs:335 [K.assembly-code] (test-data): `'LONGTOKEN' + 'x'.repeat(600) + ' end.';`
- tests/browser_flow_smoke.mjs:769 [K.http-verb] (test-data): `const ping = await fetch(resumed.json.origin, {signal: AbortSignal.timeout(8000)}).then(r => 'origin answers ' + r.status, e => 'origin error ' + e.name).catch(() => '?');`
- tests/browser_flow_smoke.mjs:1575 [K.http-verb] (test-data): `` try { await fetch(`http://127.0.0.1:${port}/json/close/${tab.id}`, {signal: AbortSignal.timeout(10000)}); } catch {} ``
- tests/browser_flow_smoke.mjs:1629 [K.http-verb] (test-data): `const ping = await fetch(resumed.origin, {signal: AbortSignal.timeout(10000)});`
- tests/fixtures/make_store_v2.py:40 [K.assembly-code] (test-data): `key = 'idea_' + '2' * 32`
- tests/fixtures/scrub_store.py:169 [K.assembly-code] (test-data): `assert not leaks, 'host paths remain in: ' + ', '.join(leaks)`
- tests/native_probe.py:308 [K.http-verb] (test-data): `const r = await fetch("/api/v1/" + route, options), result = await r.json();`
- tests/test_agent_bridge.py:15 [K.assembly-code] (test-data): `BIND = 'binding_'+'1'*32`
- tests/test_agent_bridge.py:16 [K.assembly-code] (test-data): `SID = 'session_'+'2'*32`
- tests/test_agent_bridge.py:17 [K.assembly-code] (test-data): `IDEA = 'idea_'+'3'*32`
- tests/test_agent_bridge.py:82 [K.assembly-code] (test-data): `for key,value in [('session_id','session_'+'4'*32),('idea_id','idea_'+'4'*32),`
- tests/test_agent_bridge.py:175 [K.assembly-code] (test-data): `self.assertFalse(self.broker.touch('binding_' + 'f' * 32, 'gen1'))`
- tests/test_agent_bridge.py:346 [K.assembly-code] (test-data): `assets = ['asset_'+'a'*32, 'asset_'+'b'*32]`
- tests/test_agent_bridge.py:350 [K.assembly-code] (test-data): `for bad in ({'disposition': 'accepted_set'}, {'disposition': 'skipped'}, {'design_set_id': 'set_'+'c'*32},`
- tests/test_agent_bridge.py:468 [K.assembly-code] (test-data): `other_idea='idea_'+'4'*32`
- tests/test_agent_bridge.py:595 [K.assembly-code] (test-data): `self.code('binding_capacity',lambda:self.broker.open('binding_'+'f'*32,'gen1',SID))`
- tests/test_agent_bridge.py:614 [K.assembly-code] (test-data): `self.generation = 'agent_'+'4'*32`
- tests/test_agent_bridge.py:741 [K.assembly-code] (test-data): `self.broker.open(BIND, 'agent_'+'5'*32, SID)`
- tests/test_agent_cli.py:87 [K.assembly-code] (test-data): `self.sid='session_'+'f'*32`
- tests/test_agent_cli.py:91 [K.assembly-code] (test-data): `self.assertEqual(self.cli('events','--timeout',0,'--generation','agent_'+'f'*32,`
- tests/test_agent_client.py:42 [K.assembly-code] (test-data): `'store': ('store_sha256','f'*64), 'sid': ('session_id','session_'+'f'*32),`
- tests/test_agent_client.py:43 [K.assembly-code] (test-data): `'binding': ('binding_id','binding_'+'f'*32), 'generation': ('generation','bad'),`
- tests/test_agent_client.py:58 [K.assembly-code] (test-data): `if f.mode == 'wrong_event_sid': result['events'][0]['session_id'] = 'session_'+'f'*32`
- tests/test_agent_client.py:79 [K.assembly-code] (test-data): `result = dict(ok=True,code='ok',idea_id=self.headers['X-Idea-Id'],asset_id='asset_'+'6'*32,`
- tests/test_agent_client.py:80 [K.assembly-code] (test-data): `asset_ids=['asset_'+'6'*32],upload_id='upload_'+'7'*32,size=len(payload),`
- tests/test_agent_client.py:114 [K.assembly-code] (test-data): `self.sid = 'session_'+'1'*32; self.bid = 'binding_'+'2'*32`
- tests/test_agent_client.py:115 [K.assembly-code] (test-data): `self.generation = 'agent_'+'3'*32; self.token = secrets.token_hex(32)`
- tests/test_agent_client.py:119 [K.assembly-code] (test-data): `self.correlation = dict(request_id='request-1',session_id=self.sid,idea_id='idea_'+'4'*32,`
- tests/test_agent_client.py:152 [K.assembly-code] (test-data): `self.assert_error(RuntimeError,lambda:AgentClient(self.runtime,'session_'+'f'*32),'binding_not_found')`
- tests/test_agent_client.py:153 [K.assembly-code] (test-data): `self.owner.persist_binding(dict(self.record,binding_id='binding_'+'5'*32))`
- tests/test_agent_client.py:163 [K.assembly-code] (test-data): `self.assert_error(RuntimeError,lambda:self.client(expected_generation='agent_'+'f'*32),'owner_identity_mismatch')`
- tests/test_agent_client.py:175 [K.assembly-code] (test-data): `for payload in ({},dict(self.reply(),token='secret'),dict(self.reply(),session_id='session_'+'f'*32)):`
- tests/test_agent_client.py:246 [K.assembly-code] (test-data): `args = idea.parser().parse_args(['asset','--session','session_'+'1'*32,'--idea','idea_'+'4'*32,`
- tests/test_agent_idle_fill.py:33 [K.assembly-code] (test-data): `self.idea='idea_'+'1'*32`
- tests/test_agent_launch.py:241 [K.assembly-code] (test-data): `self.assertEqual(self.raw_get('/api/v1/ideas/idea_'+'f'*32+'/markdown',auth)[0],404)`
- tests/test_agent_lease_after_supersede.py:33 [K.assembly-code] (test-data): `self.idea='idea_'+'1'*32`
- tests/test_agent_lease_while_composing.py:20 [K.assembly-code] (test-data): `self.bid='binding_'+'1'*32;self.gen='generation_'+'1'*32;self.sid='session_'+'1'*32`
- tests/test_agent_lease_while_composing.py:21 [K.assembly-code] (test-data): `self.idea='idea_'+'1'*32`
- tests/test_agent_memory.py:25 [K.assembly-code] (test-data): `LIVE=dict(binding_id='binding_'+'2'*32,generation='agent_'+'3'*32,`
- tests/test_agent_memory.py:26 [K.assembly-code] (test-data): `session_id='session_'+'4'*32,agent_status='connected')`
- tests/test_agent_memory.py:69 [K.assembly-code] (test-data): `with self.assertRaises(IdeaError):memory.validate_result(dict(FOUND,sources=['memory:'+'x'*257]))`
- tests/test_agent_memory.py:150 [K.assembly-code] (test-data): `for live in (dict(self.live,generation='agent_'+'9'*32),dict(self.live,binding_id='binding_'+'9'*32)):`
- tests/test_agent_memory.py:152 [K.assembly-code] (test-data): `self.assert_code('wrong_session',lambda:self.validate(state,live=dict(self.live,session_id='session_'+'9'*32)))`
- tests/test_agent_policy.py:103 [K.assembly-code] (test-data): `'Bearer '+self.credentials['generation'],'Bearer '+'f'*64):`
- tests/test_agent_policy.py:193 [K.assembly-code] (test-data): `dict(baseline,session_id='session_'+'f'*32),dict(baseline,reason='private'),`
- tests/test_agent_resume.py:15 [K.assembly-code] (test-data): `PID = 'proposal_'+'a'*32`
- tests/test_agent_resume.py:25 [K.assembly-code] (test-data): `self.case = case; self.live = dict(binding_id='binding_'+'b'*32,`
- tests/test_agent_resume.py:26 [K.assembly-code] (test-data): `generation='agent_'+'c'*32, session_id=case.sid, agent_status='connected')`
- tests/test_agent_resume.py:56 [K.assembly-code] (test-data): `evidence=dict(path='history/'+idea['idea_id']+'/metadata/'+'b'*64+'.md',sha256='a'*64),content_omitted=False,`
- tests/test_agent_resume.py:185 [K.assembly-code] (test-data): `self.capture(); self.provider.live = dict(binding_id='binding_'+'b'*32, generation='agent_'+'c'*32,`
- tests/test_agent_resume.py:244 [K.assembly-code] (test-data): `lambda o:o['proposals'][0]['evidence'].update(path='history/idea_'+'f'*32+'/metadata/'+'b'*64+'.md'),`
- tests/test_agent_resume.py:263 [K.assembly-code] (test-data): `self.provider.live['generation'] = 'agent_'+'d'*32`
- tests/test_agent_resume.py:270 [K.assembly-code] (test-data): `self.provider.overlay_change = lambda overlay: overlay.update(agent_generation='agent_'+'e'*32)`
- tests/test_agent_resume.py:275 [K.assembly-code] (test-data): `self.provider.overlay_change = lambda overlay: overlay.update(agent_generation='agent_'+'e'*32)`
- tests/test_agent_resume.py:290 [K.assembly-code] (test-data): `self.provider.live.pop('token'); self.provider.live['session_id'] = 'session_'+'f'*32`
- tests/test_agent_source.py:22 [K.assembly-code] (test-data): `LIVE = dict(binding_id='binding_'+'2'*32, generation='agent_'+'3'*32,`
- tests/test_agent_source.py:23 [K.assembly-code] (test-data): `session_id='session_'+'4'*32, agent_status='connected')`
- tests/test_agent_source.py:124 [K.assembly-code] (test-data): `self.assert_code('not_found',lambda:source.project_sources(domain(),'idea_'+'f'*32))`
- tests/test_agent_source.py:277 [K.assembly-code] (test-data): `for live,code in ((dict(self.live,generation='agent_'+'5'*32),'wrong_generation'),`
- tests/test_agent_source.py:278 [K.assembly-code] (test-data): `(dict(self.live,binding_id='binding_'+'6'*32),'wrong_generation'),`
- tests/test_agent_source.py:279 [K.assembly-code] (test-data): `(dict(self.live,session_id='session_'+'7'*32),'wrong_session'),`
- tests/test_agent_source.py:286 [K.assembly-code] (test-data): `unknown=dict(payload,proposal_id='proposal_'+'f'*32)`
- tests/test_agent_transport.py:136 [K.assembly-code] (test-data): `self.assertEqual(self.http(path, headers=dict(self.agent_headers(), Authorization='Bearer '+'f'*64))[0], 401)`
- tests/test_agent_transport.py:176 [K.assembly-code] (test-data): `for key, value in [('idea_id', 'idea_'+'f'*32), ('operation', 'method'),`
- tests/test_agent_v3_protocol.py:19 [K.assembly-code] (test-data): `return dict(schema_version=1, kind='agent-proposal', proposal_id='proposal_'+'1'*32,`
- tests/test_agent_v3_protocol.py:20 [K.assembly-code] (test-data): `binding_id='binding_'+'2'*32, generation='agent_'+'3'*32, actor='Operator',`
- tests/test_agent_v3_protocol.py:21 [K.assembly-code] (test-data): `timestamp='2026-10-01T00:00:00Z', request_id='proposal-request-1', session_id='session_'+'4'*32,`
- tests/test_agent_v3_protocol.py:22 [K.assembly-code] (test-data): `idea_id='idea_'+'5'*32, accepted_revision=2, draft_version=3, operation=operation,`
- tests/test_assessment.py:23 [K.assembly-code] (test-data): `KEY = 'idea_'+'1'*32`
- tests/test_assessment.py:24 [K.assembly-code] (test-data): `OTHER = 'idea_'+'2'*32`
- tests/test_assessment.py:25 [K.assembly-code] (test-data): `THIRD = 'idea_'+'3'*32`
- tests/test_assessment.py:166 [K.assembly-code] (test-data): `self.assert_code('not_found', lambda: assessment_helpers.validate_assessment_source(source, idea_id='idea_'+'f'*32))`
- tests/test_assessment.py:311 [K.assembly-code] (test-data): `self.live = dict(binding_id='binding_'+'6'*32, generation='agent_'+'7'*32,`
- tests/test_assessment_source.py:21 [K.assembly-code] (test-data): `LIVE = dict(binding_id='binding_'+'4'*32, generation='agent_'+'5'*32,`
- tests/test_assessment_source.py:22 [K.assembly-code] (test-data): `session_id='session_'+'6'*32, agent_status='connected')`
- tests/test_assessment_source.py:42 [K.assembly-code] (test-data): `return dict(schema_version=1, kind='agent-proposal', proposal_id='proposal_'+'7'*32,`
- tests/test_assessment_source.py:124 [K.assembly-code] (test-data): `proposal_id='proposal_'+'1'*32, binding_id='binding_'+'2'*32,`
- tests/test_assessment_source.py:125 [K.assembly-code] (test-data): `generation='agent_'+'3'*32, actor='Operator', timestamp='fixture-time',`
- tests/test_assessment_source.py:126 [K.assembly-code] (test-data): `request_id='fixture-request', session_id='session_'+'4'*32,`
- tests/test_assessment_source.py:127 [K.assembly-code] (test-data): `idea_id='idea_'+'5'*32, accepted_revision=2, draft_version=3,`
- tests/test_assessment_source.py:130 [K.assembly-code] (test-data): `canonical = ('{"accepted_revision":2,"actor":"Operator","binding_id":"binding_'+ '2'*32+'",'`
- tests/test_assessment_source.py:131 [K.assembly-code] (test-data): `'"data":{"capture":{"raw_text":"Fixture"}},"draft_version":3,"generation":"agent_'+'3'*32+'",'`
- tests/test_assessment_source.py:132 [K.assembly-code] (test-data): `'"idea_id":"idea_'+'5'*32+'","kind":"agent-proposal","operation":"'+operation+'",'`
- tests/test_assessment_source.py:133 [K.assembly-code] (test-data): `'"proposal":'+fixture['json']+',"proposal_id":"proposal_'+'1'*32+'",'`
- tests/test_assessment_source.py:134 [K.assembly-code] (test-data): `'"request_id":"fixture-request","schema_version":1,"session_id":"session_'+'4'*32+'",'`
- tests/test_assessment_source.py:136 [K.assembly-code] (test-data): `raw = ('---\naccepted_revision: 2\nactor: Operator\nbinding_id: binding_'+'2'*32+'\n'`
- tests/test_assessment_source.py:137 [K.assembly-code] (test-data): `'data:\n  capture:\n    raw_text: Fixture\ndraft_version: 3\ngeneration: agent_'+'3'*32+'\n'`
- tests/test_assessment_source.py:138 [K.assembly-code] (test-data): `'idea_id: idea_'+'5'*32+'\nkind: agent-proposal\noperation: '+operation+'\nproposal:\n'+fixture['yaml']+`
- tests/test_assessment_source.py:139 [K.assembly-code] (test-data): `'proposal_id: proposal_'+'1'*32+'\nrequest_id: fixture-request\nschema_version: 1\nsession_id: session_'+'4'*32+'\n'`
- tests/test_assessment_source.py:155 [K.assembly-code] (test-data): `record = dict(schema_version=1, kind='agent-proposal', proposal_id='proposal_'+'1'*32,`
- tests/test_assessment_source.py:156 [K.assembly-code] (test-data): `binding_id='binding_'+'2'*32, generation='agent_'+'3'*32, actor='Operator', timestamp='fixture-time',`
- tests/test_assessment_source.py:157 [K.assembly-code] (test-data): `request_id='fixture-request', session_id='session_'+'4'*32, idea_id='idea_'+'5'*32,`
- tests/test_assessment_source.py:165 [K.assembly-code] (test-data): `raw = ('---\naccepted_revision: 2\nactor: Operator\nbinding_id: binding_'+'2'*32+'\n'`
- tests/test_assessment_source.py:166 [K.assembly-code] (test-data): `'data:\n  capture:\n    raw_text: Fixture\ndraft_version: 3\ngeneration: agent_'+'3'*32+'\n'`
- tests/test_assessment_source.py:167 [K.assembly-code] (test-data): `'idea_id: idea_'+'5'*32+'\nkind: agent-proposal\noperation: shape\nproposal:\n'`
- tests/test_assessment_source.py:170 [K.assembly-code] (test-data): `'proposal_id: proposal_'+'1'*32+'\nrequest_id: fixture-request\nschema_version: 1\nsession_id: session_'+'4'*32+'\n'`
- tests/test_assessment_source.py:333 [K.assembly-code] (test-data): `for live, code in ((dict(self.live, generation='agent_'+'8'*32), 'wrong_generation'),`
- tests/test_assessment_source.py:335 [K.assembly-code] (test-data): `(dict(self.live, session_id='session_'+'9'*32), 'wrong_session')):`
- tests/test_assessment_source.py:337 [K.assembly-code] (test-data): `unknown = dict(payload, proposal_id='proposal_'+'a'*32)`
- tests/test_asset_agent_door.py:26 [K.assembly-code] (test-data): `TOKEN = 'Bearer ' + 'a' * 64`
- tests/test_asset_agent_door.py:105 [K.assembly-code] (test-data): `status,error = self.call(PNG,session='session_'+'9'*32)`
- tests/test_asset_evidence.py:127 [K.assembly-code] (test-data): `scalars = ''.join(chr(point) for point in range(0x7f,0xa0) if point != 0x85)+'\ufffe\uffff'`
- tests/test_asset_evidence.py:275 [K.assembly-code] (test-data): `('path', 'assets/evidence/'+'b'*64+'.md'), ('path', '../outside.md')):`
- tests/test_asset_links.py:27 [K.assembly-code] (test-data): `return dict(value, set_id='set_'+format(number, '032x'), session_id='session_'+'2'*32, source=source,`
- tests/test_asset_links.py:32 [K.assembly-code] (test-data): `session_id='session_'+'2'*32, name='Fixture café 💡.png', declared_type='image/png', size=8)`
- tests/test_asset_links.py:90 [K.assembly-code] (test-data): `for field, value in (('record_id', 'upload_'+'f'*32), ('path', 'assets/evidence/'+'b'*64+'.md')):`
- tests/test_asset_links.py:96 [K.assembly-code] (test-data): `value = record(idea_id='idea_'+'f'*32); raw = evidence.encode_record(value); link = evidence.record_link(value, raw)`
- tests/test_asset_links.py:223 [K.assembly-code] (test-data): `for bad in ('assets/blobs/asset_'+'1'*32+'.bin', 'assets/staging/upload_'+'2'*32+'.nonce.part',`
- tests/test_asset_links.py:230 [K.assembly-code] (test-data): `self.assertTrue(tx._allowed('history/'+KEY+'/metadata/'+'a'*64+'.md'))`
- tests/test_asset_links.py:244 [K.assembly-code] (test-data): `for bad in ('assets/staging/bad.part', 'assets/blobs/asset_'+'2'*32+'.bin'):`
- tests/test_asset_store.py:300 [K.assembly-code] (test-data): `stage = self.root/'assets/staging'/('upload_'+'a'*32+'.'+'b'*32+'.part')`
- tests/test_asset_store.py:332 [K.assembly-code] (test-data): `for folder,name in (('blobs',identifier('asset',1)+'.bin'),('staging','upload_'+'a'*32+'.'+'b'*32+'.part')):`
- tests/test_asset_store.py:362 [K.assembly-code] (test-data): `stage = self.root/'assets/staging'/('upload_'+'1'.zfill(32)+'.'+'a'*32+'.part')`
- tests/test_asset_store.py:411 [K.assembly-code] (test-data): `stage = self.root/'assets/staging'/(intent(self.sid)['upload_id']+'.'+'a'*32+'.part')`
- tests/test_asset_store.py:425 [K.assembly-code] (test-data): `failed = stage.with_name(intent(self.sid)['upload_id']+'.'+'b'*32+'.part')`
- tests/test_asset_store.py:427 [K.assembly-code] (test-data): `unmatched = stage.with_name(identifier('upload',2)+'.'+'c'*32+'.part')`
- tests/test_asset_store.py:436 [K.assembly-code] (test-data): `stage = self.root/'assets/staging'/(intent(self.sid)['upload_id']+'.'+'a'*32+'.part')`
- tests/test_assets.py:230 [K.assembly-code] (test-data): `self.assertEqual(self.request('/api/v1/attachments/asset_'+'f'*32)[0],404)`
- tests/test_assets.py:260 [K.assembly-code] (test-data): `(folder/('upload_'+'e'*32+'.'+format(number,'032x')+'.part')).write_bytes(b'Interrupted orphan')`
- tests/test_assets.py:265 [K.assembly-code] (test-data): `idea = state['ideas'][KEY]; pid = 'plan_'+'a'*32; content = '# Accepted archive fixture\n'`
- tests/test_assets.py:446 [K.assembly-code] (test-data): `examples.append(self.set_payload(['asset_'+'f'*32]))`
- tests/test_assets.py:449 [K.assembly-code] (test-data): `mismatch = self.set_payload([upload['asset_id']]); mismatch['fields']['design_set_id'] = 'set_'+'f'*32; examples.append(mismatch)`
- tests/test_assets.py:450 [K.assembly-code] (test-data): `examples.append(self.set_payload([upload['asset_id']],set_id='set_'+'f'*32))`
- tests/test_assets.py:474 [K.assembly-code] (test-data): `other = 'idea_'+'2'*32`
- tests/test_assets.py:486 [K.assembly-code] (test-data): `other = 'idea_'+'2'*32`
- tests/test_assets.py:586 [K.assembly-code] (test-data): `other = 'idea_'+'2'*32`
- tests/test_assets.py:788 [K.assembly-code] (test-data): `generic['fields'] = dict(generic['fields'],design_set_id='set_'+'f'*32)`
- tests/test_bridge.py:238 [K.assembly-code] (test-data): `if payload['idea_id'] != 'idea_' + '1' * 32: raise bridge.BridgeError('not_found', 404)`
- tests/test_bridge.py:257 [K.assembly-code] (test-data): `self.assertEqual(post('/api/v1/selection', dict(idea_id='idea_' + '1' * 32)), 200)`
- tests/test_bridge.py:259 [K.assembly-code] (test-data): `self.assertEqual(post('/api/v1/selection', dict(idea_id='idea_' + 'f' * 32)), 404)`
- tests/test_bridge.py:366 [K.assembly-code] (test-data): `selector='binding_'+'1'*32`
- tests/test_bridge.py:367 [K.assembly-code] (test-data): `idea='idea_'+'2'*32`
- tests/test_bridge.py:433 [K.assembly-code] (test-data): `self.assertEqual(self.raw(('GET / HTTP/1.1\r\nHost: ' + self.server.host + '\r\nX-Test: ' + 'x' * 8200 + '\r\n\r\n').encode())[0], 413)`
- tests/test_bridge.py:434 [K.assembly-code] (test-data): `self.assertEqual(self.raw(('GET /' + 'x' * 4096 + ' HTTP/1.1\r\n\r\n').encode())[0], 413)`
- tests/test_bridge.py:435 [K.assembly-code] (test-data): `self.assertEqual(self.raw(('GET / HTTP/1.1\r\nHost: ' + self.server.host + '\r\n' + 'X: y\r\n' * 65 + '\r\n').encode())[0], 413)`
- tests/test_bridge.py:717 [K.assembly-code] (test-data): `status,error,_ = self.wire('/api/v1/selection',{'idea_id':'idea_'+'f'*32},browser=self.first)`
- tests/test_bridge.py:818 [K.assembly-code] (test-data): `plan = dict(plan_id='plan_'+'3'*32,idea_id=self.key,idea_revision=revision,`
- tests/test_bridge.py:819 [K.assembly-code] (test-data): `path=str(self.root/'plan-evidence'/('plan_'+'3'*32+'.md')),source_path='/work/plan.md',`
- tests/test_bridge.py:961 [K.assembly-code] (test-data): `const id = 'idea_' + 'a'.repeat(32);`
- tests/test_bridge_control.py:88 [K.assembly-code] (test-data): `for name,value in [('Origin',self.server.origin),('Cookie','browser=x'),('X-CSRF-Token','x'),('X-Idea-Binding','binding_'+'f'*32)]:`
- tests/test_chain.py:177 [K.assembly-code] (test-data): `good = 'history/'+A+'/migrations/w2-'+'a'*64+'.md'`
- tests/test_chain.py:180 [K.assembly-code] (test-data): `for bad in ('history/'+A+'/migrations/w0-'+'a'*64+'.md',`
- tests/test_chain.py:181 [K.assembly-code] (test-data): `'history/'+A+'/migrations/w2-'+'a'*63+'.md',`
- tests/test_chain.py:182 [K.assembly-code] (test-data): `'history/'+A+'/migrations/w2-'+'A'*64+'.md',`
- tests/test_chain.py:184 [K.assembly-code] (test-data): `'history/'+A+'/migrations/x/w2-'+'a'*64+'.md',`
- tests/test_chain.py:185 [K.assembly-code] (test-data): `'history/backlog/migrations/w2-'+'a'*64+'.md',`
- tests/test_chain.py:186 [K.assembly-code] (test-data): `'migrations/w2-'+'a'*64+'.md',`
- tests/test_chain.py:187 [K.assembly-code] (test-data): `'history/'+A+'/migrations/w2-'+'a'*64+'.json'):`
- tests/test_chain_cli.py:20 [K.assembly-code] (test-data): `FULL = 'idea_'+'1'*32`
- tests/test_chain_cli.py:21 [K.assembly-code] (test-data): `SHAPE_ONLY = 'idea_'+'2'*32`
- tests/test_chain_cli.py:90 [K.assembly-code] (test-data): `sid = 'session_'+'a'*32`
- tests/test_chain_store.py:19 [K.assembly-code] (test-data): `FULL = 'idea_'+'1'*32`
- tests/test_chain_store.py:20 [K.assembly-code] (test-data): `SHAPE_ONLY = 'idea_'+'2'*32`
- tests/test_chain_v2.py:21 [K.assembly-code] (test-data): `FULL = 'idea_'+'1'*32`
- tests/test_chain_v2.py:22 [K.assembly-code] (test-data): `SHAPE_ONLY = 'idea_'+'2'*32`
- tests/test_chain_v2.py:255 [K.assembly-code] (test-data): `self.assertIn('"' + 'x' * 60 + '…"', long)`
- tests/test_cli_service.py:142 [K.assembly-code] (test-data): `managed['workflow']['steps']['assess']['fields']['position']['neighbors']['after']='idea_'+'2'*32`
- tests/test_cli_service.py:144 [K.assembly-code] (test-data): `other=complete();other['idea_id']='idea_'+'2'*32`
- tests/test_cli_service.py:145 [K.assembly-code] (test-data): `unaffected=complete();unaffected['idea_id']='idea_'+'3'*32`
- tests/test_cli_service.py:146 [K.assembly-code] (test-data): `tail=complete();tail['idea_id']='idea_'+'4'*32`
- tests/test_encode_state_unchanged.py:27 [K.assembly-code] (test-data): `text = text.replace(KEY, key).replace('plan_' + '1' * 32, 'plan_' + format(n + 100, '032x'))`
- tests/test_exploration_method.py:42 [K.assembly-code] (test-data): `self.context=TrustedContext('Operator','session_'+'1'*32)`
- tests/test_exploration_method.py:214 [K.assembly-code] (test-data): `self.context=TrustedContext('Operator','session_'+'1'*32)`
- tests/test_external_edits.py:29 [K.assembly-code] (test-data): `other = copy.deepcopy(values[0]); other['idea_id'] = 'idea_'+'2'*32`
- tests/test_fixed_prototype_port.py:21 [K.assembly-code] (test-data): `SESSION = 'session_' + '0' * 32`
- tests/test_fragment_pairing.py:54 [K.assembly-code] (test-data): `URL + "#pair=" + CODE.upper(), URL + "#pair=" + "g" * 32,`
- tests/test_handoff.py:165 [K.assembly-code] (test-data): `const api=new IdeaApi(async()=>({ok:true,status:200,json:async()=>structuredClone(input.reply)}),1000,'binding_'+'a'.repeat(32));`
- tests/test_handoff.py:275 [K.assembly-code] (test-data): `idea = state['ideas'][self.key]; plan_id = 'plan_'+'8'*32; content = '# Frozen plan fixture\n'`
- tests/test_handoff.py:357 [K.assembly-code] (test-data): `self.refused('not_found',lambda:handoffs.selection(self.binding,None,{'idea_id':'idea_'+'f'*32}))`
- tests/test_handoff_evidence.py:31 [K.assembly-code] (test-data): `values['visualize'].update(disposition='accepted_set', source='claude_design', reason=None, design_set_id='set_'+'a'*32)`
- tests/test_handoff_evidence.py:32 [K.assembly-code] (test-data): `design = dict(set_id='set_'+'a'*32, members=[dict(asset_id='asset_'+'b'*32,`
- tests/test_handoff_evidence.py:34 [K.assembly-code] (test-data): `path=root+('/assets/blobs/' if not windows else '\\assets\\blobs\\')+'asset_'+'b'*32+'.bin')])`
- tests/test_handoff_evidence.py:57 [K.assembly-code] (test-data): `handoff_id='handoff_'+'4'*32, session_id='session_'+'5'*32,`
- tests/test_handoff_evidence.py:138 [K.assembly-code] (test-data): `'C1'+''.join(chr(n) for n in range(0x7f, 0xa0))+'\ufffe\uffff💡'):`
- tests/test_handoff_evidence.py:154 [K.assembly-code] (test-data): `for bad in (dict(link, sha256='0'*64), dict(link, handoff_id='handoff_'+'6'*32),`
- tests/test_handoff_evidence.py:157 [K.assembly-code] (test-data): `self.refused(lambda:codec.decode_record(raw, expected_idea_id='idea_'+'9'*32), 'corrupt_store')`
- tests/test_handoff_evidence.py:168 [K.assembly-code] (test-data): `('request_id', '../outside'), ('handoff_id', 'idea_'+'1'*32),`
- tests/test_handoff_evidence.py:218 [K.assembly-code] (test-data): `elif mode == 'placement': state['placements'][0]['neighbors']['after'] = 'idea_'+'8'*32`
- tests/test_handoff_evidence.py:223 [K.assembly-code] (test-data): `neighbor = 'idea_'+'8'*32; state['order'].append(neighbor)`
- tests/test_handoff_evidence.py:244 [K.assembly-code] (test-data): `if mode == 'wrong_set': changed['set_id'] = 'set_'+'d'*32`
- tests/test_handoff_evidence.py:263 [K.assembly-code] (test-data): `design_set=design,handoff_id='handoff_'+'4'*32,session_id='session_'+'5'*32,`
- tests/test_handoff_links.py:84 [K.assembly-code] (test-data): `other['handoff_id'] = 'handoff_'+'f'*32`
- tests/test_handoff_links.py:90 [K.assembly-code] (test-data): `foreign_key = 'idea_'+'f'*32`
- tests/test_handoff_links.py:134 [K.assembly-code] (test-data): `record.update(handoff_id='handoff_'+'e'*32,request_id='append')`
- tests/test_handoff_links.py:153 [K.assembly-code] (test-data): `for refs in (links[:1],list(reversed(links)),[],[dict(links[0],handoff_id='handoff_'+'e'*32),links[1]]):`
- tests/test_handoff_links.py:161 [K.assembly-code] (test-data): `dict(raw_map,**{'history/'+key+'/metadata/'+'e'*64+'.md':b'orphan'})):`
- tests/test_handoff_store.py:156 [K.assembly-code] (test-data): `idea = state['ideas'][self.key]; plan_id = 'plan_'+'7'*32`
- tests/test_handoff_store.py:176 [K.assembly-code] (test-data): `lambda r:r['receipts'][request]['result'].update(handoff_id='handoff_'+'f'*32),`
- tests/test_handoff_store.py:179 [K.assembly-code] (test-data): `lambda r:r['receipts'][request]['result'].update(idea_id='idea_'+'e'*32),`
- tests/test_handoff_store.py:240 [K.assembly-code] (test-data): `for altered in (links[:1],list(reversed(links)),[],[dict(links[0],handoff_id='handoff_'+'e'*32),links[1]]):`
- tests/test_idea.py:284 [K.assembly-code] (test-data): `wrong = self.plan_file(dict(idea,idea_id='idea_'+'a'*32))`
- tests/test_import_cli.py:101 [K.assembly-code] (test-data): `KEPT = 'idea_'+'2'*32`
- tests/test_import_cli.py:106 [K.assembly-code] (test-data): `gone = 'idea_'+'1'*32`
- tests/test_import_idea.py:36 [K.assembly-code] (test-data): `OTHER = 'idea_'+'2'*32`
- tests/test_import_idea.py:141 [K.assembly-code] (test-data): `stage = self.source/'assets/staging'/('upload_'+'1'*32+'.'+'2'*32+'.part')`
- tests/test_import_idea.py:357 [K.assembly-code] (test-data): `moved = 'idea_'+'4'*32`
- tests/test_import_idea.py:364 [K.assembly-code] (test-data): `plan = dict(plan_id='plan_'+'3'*32, idea_id=moved, idea_revision=1, path=str(root/'plan-evidence'/('plan_'+'3'*32+'.md')),`
- tests/test_install.py:369 [K.assembly-code] (test-data): `env = dict(os.environ, HOME="/" + "h" * 4100)`
- tests/test_launch.py:118 [K.assembly-code] (test-data): `with self.assertRaises(OwnerError):self.opened(selected_idea_id='idea_'+'f'*32)`
- tests/test_launcher_cli.py:61 [K.assembly-code] (test-data): `result=dict(identity={},origin='http://127.0.0.1:1234/',binding_id='binding_'+'a'*32,`
- tests/test_launcher_cli.py:62 [K.assembly-code] (test-data): `session_id='session_'+'b'*32,selected_idea_id=None,pairing_code='ONE-TIME-FIXTURE')`
- tests/test_launcher_cli.py:70 [K.assembly-code] (test-data): `binding='binding_'+'c'*32;selected='idea_'+'d'*32`
- tests/test_launcher_cli.py:169 [K.assembly-code] (test-data): `for extra in (['--orca-terminal','t'],['--reconnect','binding_'+'a'*32]):`
- tests/test_launcher_cli.py:186 [K.assembly-code] (test-data): `binding='binding_'+'a'*32;sid='session_'+'b'*32`
- tests/test_legacy_prior_art.py:21 [K.assembly-code] (test-data): `KEY = 'idea_' + '1' * 32`
- tests/test_legacy_prior_art.py:97 [K.assembly-code] (test-data): `other = 'idea_' + '2' * 32`
- tests/test_link_mode_cli.py:21 [K.assembly-code] (test-data): `BINDING='binding_'+'a'*32`
- tests/test_link_mode_cli.py:213 [K.assembly-code] (test-data): `body=self.link('--resume','binding_'+'0'*32,ok=False)`
- tests/test_markdown.py:17 [K.assembly-code] (test-data): `KEY = 'idea_' + '0' * 31 + '1'`
- tests/test_markdown.py:34 [K.assembly-code] (test-data): `proposal_id='proposal_'+'2'*32)`
- tests/test_markdown.py:35 [K.assembly-code] (test-data): `idea['proposals'] = [proposal, dict(proposal, proposal_id='proposal_'+'3'*32, reason='Second recommendation')]`
- tests/test_markdown.py:36 [K.assembly-code] (test-data): `pid = 'plan_'+'1'*32`
- tests/test_markdown.py:67 [K.assembly-code] (test-data): `self.rejected('a: ' + '[' * 35 + '0' + ']' * 35, 'too_large')`
- tests/test_markdown.py:193 [K.assembly-code] (test-data): `pid = 'plan_' + '1' * 32`
- tests/test_markdown.py:238 [K.assembly-code] (test-data): `proposal=dict(placement,proposal_id='proposal_'+'2'*32)`
- tests/test_markdown.py:339 [K.assembly-code] (test-data): `for updates in ({'kind': 'history'}, {'record_type': 'plan'}, {'idea_id': 'idea_'+'4'*32}, {'schema_version': True}):`
- tests/test_markdown.py:344 [K.assembly-code] (test-data): `wrong_path = 'history/'+KEY+'/metadata/'+'0'*64+'.md'`
- tests/test_markdown_store.py:23 [K.assembly-code] (test-data): `KEY = 'idea_'+'1'*32`
- tests/test_markdown_store.py:224 [K.assembly-code] (test-data): `extra = self.root/('idea_'+'2'*32+'.md')`
- tests/test_middle_flow.py:405 [K.assembly-code] (test-data): `other = original_idea(); other['idea_id'] = 'idea_'+'2'*32`
- tests/test_middle_flow.py:415 [K.assembly-code] (test-data): `other = copy.deepcopy(original); other['idea_id'] = 'idea_'+'2'*32`
- tests/test_middle_flow.py:416 [K.assembly-code] (test-data): `archived = copy.deepcopy(original); archived['idea_id'] = 'idea_'+'3'*32; archived['status'] = 'archived'`
- tests/test_middle_flow.py:417 [K.assembly-code] (test-data): `new = copy.deepcopy(original); new['idea_id'] = 'idea_'+'4'*32`
- tests/test_middle_flow.py:715 [K.assembly-code] (test-data): `idea = state['ideas'][first]; pid = 'plan_'+'a'*32; content = '# J10 archive fixture\n'`
- tests/test_migration.py:22 [K.assembly-code] (test-data): `SECOND = 'idea_'+'7'*32`
- tests/test_migration.py:159 [K.assembly-code] (test-data): `proposal.update(proposal_id='proposal_'+'8'*32,idea_revision=current['revision'],`
- tests/test_migration.py:162 [K.assembly-code] (test-data): `plan=copy.deepcopy(current['plans'][0]); pid='plan_'+'9'*32`
- tests/test_move_cli.py:344 [K.assembly-code] (test-data): `self.refused('not_found', 'deliver', 'idea_'+'f'*32, '--ref', 'x', '--actor', 'operator')`
- tests/test_move_store.py:22 [K.assembly-code] (test-data): `KEY = 'idea_'+'1'*32`
- tests/test_move_store.py:23 [K.assembly-code] (test-data): `OTHER = 'idea_'+'2'*32`
- tests/test_move_store.py:24 [K.assembly-code] (test-data): `PLAN = 'plan_'+'3'*32`
- tests/test_move_store.py:188 [K.assembly-code] (test-data): `self.refusal('not_found', lambda: self.store.move_out(state, 'idea_'+'9'*32, expected_revision=1, plan=self.plan(),`
- tests/test_move_store.py:193 [K.assembly-code] (test-data): `prior = 'plan_'+'5'*32`
- tests/test_move_store.py:200 [K.assembly-code] (test-data): `result = self.move(plan=self.plan('plan_'+'6'*32))`
- tests/test_move_store.py:203 [K.assembly-code] (test-data): `self.assertEqual([p['plan_id'] for p in state['ideas'][KEY]['plans']], [prior, 'plan_'+'6'*32])`
- tests/test_move_store.py:207 [K.assembly-code] (test-data): `error = self.refusal('idea_moved', lambda: self.move(plan=self.plan('plan_'+'4'*32)))`
- tests/test_move_store.py:294 [K.assembly-code] (test-data): `self.store._prepare_commit(state, self.store._contexts.active, handoff_append=(KEY, dict(handoff_id='handoff_'+'5'*32)))`
- tests/test_move_store.py:332 [K.assembly-code] (test-data): `dict(plan_id='plan_'+'9'*32)):`
- tests/test_navigation.py:82 [K.assembly-code] (test-data): `payload=dict(request_id='navigate',idea_id='idea_'+'1'*32,expected_revision=1,expected_draft_version=0,step='capture')`
- tests/test_navigation.py:129 [K.assembly-code] (test-data): `(dict(reason='   '),'invalid_input'),(dict(idea_id='idea_'+'f'*32),'not_found')):`
- tests/test_proposal_evidence.py:33 [K.assembly-code] (test-data): `return dict(schema_version=1, kind='agent-proposal', proposal_id='proposal_'+'1'*32,`
- tests/test_proposal_evidence.py:34 [K.assembly-code] (test-data): `binding_id='binding_'+'2'*32, generation='agent_'+'3'*32, actor='Operator',`
- tests/test_proposal_evidence.py:35 [K.assembly-code] (test-data): `timestamp='2026-10-01T00:00:00Z', request_id='proposal-request-1', session_id='session_'+'4'*32,`
- tests/test_proposal_evidence.py:36 [K.assembly-code] (test-data): `idea_id='idea_'+'5'*32, accepted_revision=2, draft_version=3, operation=operation,`
- tests/test_proposal_evidence.py:165 [K.assembly-code] (test-data): `for path in ('../outside.md', '/absolute.md', link['path'].replace(record['idea_id'], 'idea_'+'6'*32),`
- tests/test_proposal_evidence.py:168 [K.assembly-code] (test-data): `with self.assertRaises(IdeaError): codec.decode_proposal(raw, expected_idea_id='idea_'+'6'*32)`
- tests/test_proposal_evidence.py:171 [K.assembly-code] (test-data): `bad = dict(link, proposal_id='proposal_'+'7'*32)`
- tests/test_proposal_links.py:21 [K.assembly-code] (test-data): `binding_id='binding_'+'2'*32, generation='agent_'+'3'*32, actor='Operator',`
- tests/test_proposal_links.py:22 [K.assembly-code] (test-data): `timestamp='2026-10-02T00:00:00Z', request_id='request-'+str(number), session_id='session_'+'4'*32,`
- tests/test_proposal_links.py:81 [K.assembly-code] (test-data): `state = fixture(); other = proposal(1, 'idea_'+'f'*32)`
- tests/test_proposal_store.py:26 [K.assembly-code] (test-data): `def build_evidence(state, sid, request_id='suggestion-1', generation='agent_'+'3'*32):`
- tests/test_proposal_store.py:32 [K.assembly-code] (test-data): `return dict(binding_id='binding_'+'2'*32,generation=generation,correlation=correlation,source=source,`
- tests/test_proposal_store.py:131 [K.assembly-code] (test-data): `changed = copy.deepcopy(self.evidence); changed['generation'] = 'agent_'+'4'*32`
- tests/test_prototype_server.py:18 [K.assembly-code] (test-data): `SESSION = 'session_' + '0' * 32`
- tests/test_rebuilt_tab_repair.py:104 [K.assembly-code] (test-data): `with self.assertRaises(BridgeError) as caught: self.policy.repair_browser('binding_' + '0' * 32)`
- tests/test_rebuilt_tab_repair.py:210 [K.assembly-code] (test-data): `binding = 'binding_' + '1' * 32`
- tests/test_rebuilt_tab_repair.py:232 [K.assembly-code] (test-data): `line = self.notice('?binding=binding_' + 'a' * 32, 'browser_unauthorized')`
- tests/test_rebuilt_tab_repair.py:238 [K.assembly-code] (test-data): `self.assertIsNone(self.notice('?binding=binding_' + 'a' * 32, 'wrong_pairing_code'))`
- tests/test_rebuilt_tab_repair.py:239 [K.assembly-code] (test-data): `self.assertIsNone(self.notice('?binding=binding_' + 'a' * 32, 'browser_unauthorized', True))`
- tests/test_remove_cli.py:57 [K.assembly-code] (test-data): `data = self.cli('remove-idea', '--idea', 'idea_'+'9'*32, '--actor', 'operator', '--confirm', ok=False)`
- tests/test_remove_cli.py:78 [K.assembly-code] (test-data): `run = self.run_cli('remove-idea', '--idea', 'idea_'+'2'*32, '--actor', 'operator')`
- tests/test_remove_cli.py:83 [K.assembly-code] (test-data): `again = self.run_cli('remove-idea', '--idea', 'idea_'+'2'*32, '--actor', 'operator')`
- tests/test_remove_cli.py:88 [K.assembly-code] (test-data): `run = self.run_cli('remove-idea', '--idea', 'idea_'+'9'*32, '--actor', 'operator', '--confirm')`
- tests/test_remove_idea.py:36 [K.assembly-code] (test-data): `self.stage = self.source/'assets/staging'/('upload_'+format(1, '032x')+'.'+'2'*32+'.part')`
- tests/test_remove_idea.py:211 [K.assembly-code] (test-data): `self.refused('not_found', 'idea_'+'9'*32)`
- tests/test_remove_idea.py:216 [K.assembly-code] (test-data): `keep = self.stage.with_name('upload_'+format(77, '032x')+'.'+'3'*32+'.part')`
- tests/test_remove_idea.py:364 [K.assembly-code] (test-data): `x, y = 'idea_'+'4'*32, 'idea_'+'5'*32`
- tests/test_remove_idea.py:460 [K.assembly-code] (test-data): `context['asset_entries'][OTHER] = [dict(record=dict(kind='asset', blob_path=self.blob_path, upload_id='upload_'+'0'*32), blob=None)]`
- tests/test_remove_idea.py:489 [K.assembly-code] (test-data): `prior = 'plan_'+'5'*32`
- tests/test_remove_idea.py:506 [K.assembly-code] (test-data): `prior = 'plan_'+'5'*32`
- tests/test_remove_idea.py:573 [K.assembly-code] (test-data): `timestamp='2026-10-02T00:00:00Z', set_id='set_'+'3'*32, session_id=self.sid, source=source,`
- tests/test_remove_idea_in_use.py:24 [K.assembly-code] (test-data): `OTHER = 'idea_'+'b'*32`
- tests/test_restore_parks_orphaned_session.py:22 [K.assembly-code] (test-data): `GONE = 'idea_' + '3' * 32`
- tests/test_restore_parks_orphaned_session.py:23 [K.assembly-code] (test-data): `LIVE = 'idea_' + '4' * 32`
- tests/test_runtime.py:55 [K.assembly-code] (test-data): `if fixture.mode == 'wrong_sid' and 'session_id' in result: result['session_id'] = 'session_' + 'f' * 32`
- tests/test_runtime.py:158 [K.assembly-code] (test-data): `self.owner.persist_binding(dict(self.record(), selected_idea_id='idea_' + 'a' * 32))`
- tests/test_runtime.py:159 [K.assembly-code] (test-data): `for key, value in (('actor', 'forged'), ('receipt_session_id', 'session_' + 'b' * 32)):`
- tests/test_runtime.py:336 [K.assembly-code] (test-data): `selected = 'idea_' + 'b' * 32`
- tests/test_runtime.py:348 [K.assembly-code] (test-data): `for args in (('shell',), ('resume',), ('new', 'binding_' + 'c' * 32), ('resume', '../private')):`
- tests/test_runtime.py:416 [K.assembly-code] (test-data): `stage = self.owner.path / 'bindings' / ('.runtime_binding_' + '0' * 32 + '_' + '1' * 64 + '_' + '2' * 32 + '.tmp')`
- tests/test_runtime.py:433 [K.assembly-code] (test-data): `stage = self.owner.path / 'bindings' / ('.runtime_' + self.record()['binding_id'] + '_' + '1' * 64 + '_' + '2' * 32 + '.tmp')`
- tests/test_runtime.py:494 [K.assembly-code] (test-data): `ghost = '.runtime_' + self.record()['binding_id'] + '_' + '1' * 64 + '_' + '2' * 32 + '.tmp'`
- tests/test_service.py:242 [K.assembly-code] (test-data): `self.assert_code('not_found',lambda:self.service.state('idea_'+'f'*32))`
- tests/test_session_security.py:176 [K.assembly-code] (test-data): `missing='session_'+'f'*32`
- tests/test_session_slots.py:257 [K.assembly-code] (test-data): `for operation,payload in (('events',None),('fill',dict(idea_id='idea_'+'a'*32,accepted_revision=1)),('session-close',{})):`
- tests/test_session_slots.py:267 [K.assembly-code] (test-data): `self.refused('binding_not_found',lambda:self.client.discard_binding('binding_'+'0'*32))`
- tests/test_session_slots.py:268 [K.assembly-code] (test-data): `self.refused('binding_not_found',lambda:self.client.discard_binding('binding_'+'0'*32,True))`
- tests/test_session_superseded.py:33 [K.assembly-code] (test-data): `junk=self.request({'X-Idea-Binding':self.bid,'Cookie':self.cookie.split('=')[0]+'='+'0'*64,'X-CSRF-Token':self.csrf,'X-Idea-Tab':'f'*64})`
- tests/test_session_verbs.py:80 [K.assembly-code] (test-data): `body=self.cli('session-discard','--binding','binding_'+'0'*32,expect=False)`
- tests/test_ssh_mode.py:30 [K.http-verb] (test-data): `open_ok=True, curl=True, machine_id=None, printed=None):`
- tests/test_ssh_mode.py:32 [K.http-verb] (test-data): `self.open_ok, self.curl, self.machine_id, self.printed = open_ok, curl, machine_id, printed`
- tests/test_ssh_mode.py:80 [K.http-verb] (test-data): `if remote.startswith('curl'):`
- tests/test_ssh_mode.py:81 [K.http-verb] (test-data): `if not client.curl:`
- tests/test_ssh_mode.py:82 [K.http-verb] (test-data): `return Result(1, '', "'curl' is not recognized as an internal or external command")`
- tests/test_ssh_mode.py:246 [K.http-verb] (test-data): `probed = [c[0][-2] for c in fake.calls if c[0][-1].startswith('curl')]`
- tests/test_ssh_mode.py:285 [K.assembly-code] (test-data): `reg = lambda *guids: '\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n' + ''.join(`
- tests/test_ssh_mode.py:416 [K.http-verb] (test-data): `self.assertEqual(code(self.check, tunnel='down', curl=False)[0], 'ssh_client_no_curl')`
- tests/test_ssh_mode.py:627 [K.assembly-code] (test-data): `'http://127.0.0.1:1/?binding=binding_' + 'a1' * 16 + '#pair=' + URL_CODE):`
- tests/test_ssh_mode.py:696 [K.assembly-code] (test-data): `return dict(binding_id='binding_' + '1' * 32, session_id='session_' + '2' * 32, selected_idea_id=None,`
- tests/test_ssh_mode.py:724 [K.assembly-code] (test-data): `self.assertEqual(result['binding_id'], 'binding_' + '1' * 32)`
- tests/test_ssh_mode.py:761 [K.http-verb] (test-data): `wrapped = lambda argv, **k: (events.append('curl' if argv[-1].startswith('curl') else 'open' if argv[-1].startswith('powershell') else 'x'), fake(argv, **k))[1]`
- tests/test_ssh_mode.py:765 [K.http-verb] (test-data): `self.assertEqual(order, ['ensure', 'curl', 'session', 'open'])`
- tests/test_store_load_cache.py:145 [K.assembly-code] (test-data): `self.forced(self.store,lambda: (self.root/('idea_'+'f'*32+'.md')).write_bytes(b'x'))`
- tests/test_store_requests.py:156 [K.assembly-code] (test-data): `for sid,rid in [('session_bad','request'),('../session','request'),('session_'+'A'*32,'request'),(self.sid,'a'*129),(self.sid,'bad/path'),(self.sid,True),(self.sid,None)]:`
- tests/test_store_requests.py:209 [K.assembly-code] (test-data): `encoded({'schema_version':1,'session_id':'session_'+'0'*32,'receipts':{}}),`
- tests/test_transactions.py:22 [K.assembly-code] (test-data): `IDEA = 'idea_' + '1' * 32 + '.md'`
- tests/test_transactions.py:23 [K.assembly-code] (test-data): `HISTORY = 'history/idea_' + '1' * 32 + '/r1.md'`
- tests/test_transactions.py:24 [K.assembly-code] (test-data): `SESSION = 'session-recovery/session_' + '2' * 32 + '.json'`
- tests/test_transactions.py:246 [K.assembly-code] (test-data): `path='history/idea_'+'3'*32+'/metadata/'+'a'*64+'.md'`
- tests/test_transactions.py:260 [K.assembly-code] (test-data): `prefix='history/idea_'+'3'*32+'/metadata/'`
- tests/test_transactions.py:261 [K.assembly-code] (test-data): `for suffix in ('a'*63+'.md','A'*64+'.md','g'*64+'.md','a'*64+'.json','../'+'a'*64+'.md','a'*64+'.md/extra'):`
- tests/test_transactions.py:264 [K.assembly-code] (test-data): `for path in ('history/idea_bad/metadata/'+'a'*64+'.md', 'history/backlog/metadata/'+'a'*64+'.md'):`
- tests/test_transactions.py:412 [K.assembly-code] (test-data): `MOVED = 'history/idea_' + '1' * 32 + '/moved.md'`
- tests/test_transactions.py:423 [K.assembly-code] (test-data): `plans=[dict(plan_id='plan_' + '3' * 32, idea_id=key, idea_revision=1, path='/s/p.md', source_path='/w/p.md',`
- tests/test_transactions.py:425 [K.assembly-code] (test-data): `return md.encode_moved(key, idea_revision=1, plan_id='plan_' + '3' * 32, workspace=dict(name='W', path='/w'),`
- tests/test_transactions.py:495 [K.assembly-code] (test-data): `(self.move_changes(), self.move_expected(), 'history/idea_' + '1' * 32 + '/r1.md'),`
- tests/test_transactions.py:524 [K.assembly-code] (test-data): `extra['path'] = 'idea_' + '2' * 32 + '.md'`
- tests/test_tunnel_probe.py:62 [K.assembly-code] (test-data): `self.assertNotEqual(self.get('?nonce=' + 'cd' * 16)[1]['proof'], body['proof'])`
- tests/test_tunnel_probe.py:65 [K.assembly-code] (test-data): `for query in ('', '?nonce=', '?nonce=' + 'AB' * 16, '?nonce=' + 'ab' * 15, '?nonce=' + 'ab' * 17,`
- tests/test_tunnel_probe.py:66 [K.assembly-code] (test-data): `'?nonce=zz' + 'ab' * 15, '?nonce=' + NONCE + '&nonce=' + NONCE, '?nonce=' + NONCE + '&x=1',`
- tests/test_two_sessions.py:319 [K.assembly-code] (test-data): `self.enqueue(self.b,'req_two',idea='idea_'+'9'*32)`
- tests/test_visualize_step.py:102 [K.assembly-code] (test-data): `fields = dict(disposition='accepted_set',reason=None,design_set_id='set_'+'1'*32,brief_evidence_id=None,`
- tests/test_visualize_step.py:114 [K.assembly-code] (test-data): `payload = self.set_payload(); payload['proposal_id'] = 'proposal_'+'a'*32`
- tests/test_web_assets.py:634 [K.http-verb] (test-data): `for line in ('fetch("//cdn.example/a.js");', "new Worker('//cdn.example/w.js');",`
- tests/test_web_assets.py:636 [K.http-verb] (test-data): `'<img src="//img.example/a.png">', 'fetch("//localhost/a.js");', 'fetch("//cdn/a.js");',`
- tests/test_web_assets.py:638 [K.http-verb] (test-data): `'fetch( "//cdn.example/a.js");'):`
- tests/test_workflow.py:52 [K.assembly-code] (test-data): `return {'idea_id': 'idea_'+'1'*32, 'revision': 1, 'status': 'active',`
- tests/test_workflow.py:442 [K.assembly-code] (test-data): `assets=['asset_'+'a'*32, 'asset_'+'b'*32])`
- tests/test_workflow_api.py:87 [K.assembly-code] (test-data): `record = dict(idea_id='idea_' + '1' * 32, title='Lunch box lid', status='in-progress')`
- tests/test_workflow_api.py:108 [K.assembly-code] (test-data): `with self.assertRaises(WorkflowError) as caught: WorkflowClient(fake.url, KEY).get_idea('idea_' + 'f' * 32)`
- tests/test_workflow_schema.py:226 [K.assembly-code] (test-data): `value['position']['neighbors']['before'] = 'idea_'+'1'*32`
- tests/web/accept-reasons.test.mjs:8 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), SID = 'session_' + '2'.repeat(32), BINDING = 'binding_' + '6'.repeat(32), GEN = 'agent_' + '3'.repeat(32);`
- tests/web/app-render.test.mjs:12 [K.assembly-code] (test-data): `const idea='idea_'+'1'.repeat(32);`
- tests/web/app-render.test.mjs:485 [K.assembly-code] (test-data): `const sid='session_'+'4'.repeat(32),gen='agent_'+'5'.repeat(32);`
- tests/web/assess-clarity.test.mjs:10 [K.assembly-code] (test-data): `const IDEA='idea_'+'1'.repeat(32),OTHER='idea_'+'2'.repeat(32),SID='session_'+'4'.repeat(32),BINDING='binding_'+'7'.repeat(32);`
- tests/web/assess-clarity.test.mjs:25 [K.assembly-code] (test-data): `agent_status:'connected',agent_generation:'agent_'+'5'.repeat(32),proposal_sources:{assessment:{available:false,code:'agent_unavailable',source:null}},proposals:[],proposal_inventory:{total:0,projected:0,omitted:0,content_omitted:0,index_path:IDEA+'.md'},human_ratings:{urgency:6,importance:7,actor:'x',timestamp:'t'},`
- tests/web/assess.test.mjs:12 [K.assembly-code] (test-data): `const IDEA='idea_'+'1'.repeat(32),OTHER='idea_'+'2'.repeat(32),THIRD='idea_'+'3'.repeat(32);`
- tests/web/assess.test.mjs:13 [K.assembly-code] (test-data): `const SID='session_'+'4'.repeat(32),GEN='agent_'+'5'.repeat(32),PID='proposal_'+'6'.repeat(32),BINDING='binding_'+'7'.repeat(32);`
- tests/web/assess.test.mjs:84 [K.assembly-code] (test-data): `acceptance_eligible:true,acceptance_reason:null,content_omitted:false,evidence:{path:'history/'+IDEA+'/metadata/'+'b'.repeat(64)+'.md',sha256:'c'.repeat(64)},...overrides}];sources();`
- tests/web/assessment-controller.test.mjs:9 [K.assembly-code] (test-data): `const IDEA='idea_'+'1'.repeat(32),OTHER='idea_'+'2'.repeat(32),THIRD='idea_'+'3'.repeat(32);`
- tests/web/assessment-controller.test.mjs:10 [K.assembly-code] (test-data): `const SID='session_'+'4'.repeat(32),GEN='agent_'+'5'.repeat(32),PID='proposal_'+'6'.repeat(32),BINDING='binding_'+'7'.repeat(32);`
- tests/web/assessment-controller.test.mjs:73 [K.assembly-code] (test-data): `acceptance_eligible:true,acceptance_reason:null,content_omitted:false,evidence:{path:'history/'+IDEA+'/metadata/'+'b'.repeat(64)+'.md',sha256:'c'.repeat(64)},...overrides}];update(state);`
- tests/web/attachment-api.test.mjs:7 [K.assembly-code] (test-data): `const binding = 'binding_' + 'a'.repeat(32), asset = 'asset_' + 'b'.repeat(32);`
- tests/web/backlog.test.mjs:15 [K.assembly-code] (test-data): `const A = 'binding_' + 'a'.repeat(32), SA = 'session_' + 'a'.repeat(32);`
- tests/web/binding.test.mjs:15 [K.assembly-code] (test-data): `const A = 'binding_' + 'a'.repeat(32), B = 'binding_' + 'b'.repeat(32);`
- tests/web/binding.test.mjs:16 [K.assembly-code] (test-data): `const SA = 'session_' + 'a'.repeat(32), SB = 'session_' + 'b'.repeat(32);`
- tests/web/binding.test.mjs:17 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32);`
- tests/web/binding.test.mjs:214 [K.assembly-code] (test-data): `const SET='set_'+'3'.repeat(32),OTHER_SET='set_'+'4'.repeat(32),ASSET='asset_'+'5'.repeat(32);`
- tests/web/capture-attachments.test.mjs:15 [K.assembly-code] (test-data): `const IDEA='idea_'+'1'.repeat(32),SESSION='session_'+'2'.repeat(32),BINDING='binding_'+'3'.repeat(32),ASSET='asset_'+'4'.repeat(32),UPLOAD='upload_'+'5'.repeat(32),HASH='a'.repeat(64);`
- tests/web/conversation.test.mjs:12 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), OTHER = 'idea_' + '2'.repeat(32), THIRD = 'idea_' + '3'.repeat(32);`
- tests/web/conversation.test.mjs:13 [K.assembly-code] (test-data): `const SID = 'session_' + '4'.repeat(32), GEN = 'agent_' + '5'.repeat(32);`
- tests/web/cp3-review-fixes.test.mjs:13 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), SID = 'session_' + '2'.repeat(32), GEN = 'agent_' + '3'.repeat(32);`
- tests/web/cp3-review-fixes.test.mjs:158 [K.assembly-code] (test-data): `const flow = flowFor(opts, buffers); flow.selectedProposals[key] = 'proposal_' + '9'.repeat(32);`
- tests/web/cp3-review-fixes.test.mjs:176 [K.assembly-code] (test-data): `value.proposals = [{proposal_id: 'proposal_' + '4'.repeat(32), request_id: 'request-1', operation: key, accepted_revision: 3, draft_version: 0, source_digest: 'a'.repeat(64),`
- tests/web/cp3-review-fixes.test.mjs:178 [K.assembly-code] (test-data): `evidence: {path: 'history/' + IDEA + '/metadata/' + 'b'.repeat(64) + '.md', sha256: 'c'.repeat(64)}}];`
- tests/web/cp3-review-fixes.test.mjs:187 [K.assembly-code] (test-data): `assert.equal(flow.useProposal(key, 'proposal_' + '4'.repeat(32)), true);`
- tests/web/discovery-proposals.test.mjs:15 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), SID = 'session_' + '2'.repeat(32), GEN = 'agent_' + '3'.repeat(32), PID = 'proposal_' + '4'.repeat(32);`
- tests/web/discovery-proposals.test.mjs:90 [K.assembly-code] (test-data): `evidence: {path: 'history/' + IDEA + '/metadata/' + 'b'.repeat(64) + '.md', sha256: 'c'.repeat(64)}, ...changes}];`
- tests/web/discovery-proposals.test.mjs:233 [K.assembly-code] (test-data): `await h.get('discovery-use-proposal-' + PID).click(); h.state.agent_generation = 'agent_' + '5'.repeat(32);`
- tests/web/discovery.test.mjs:10 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32);`
- tests/web/discovery.test.mjs:27 [K.assembly-code] (test-data): `const state = {ok: true, code: 'ok', session_id: 'session_' + '2'.repeat(32), idea_id: IDEA, idea_status: 'active', revision: 2, draft_version: 0, backlog_revision: 1,`
- tests/web/discovery.test.mjs:31 [K.assembly-code] (test-data): `drafts: draft ? {discovery: draft} : {}, draft: null, agent_status: agent, agent_generation: agent === 'connected' ? 'agent_' + '3'.repeat(32) : null,`
- tests/web/exploration-proposals.test.mjs:16 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), SID = 'session_' + '2'.repeat(32), GEN = 'agent_' + '3'.repeat(32), PID = 'proposal_' + '4'.repeat(32);`
- tests/web/exploration-proposals.test.mjs:94 [K.assembly-code] (test-data): `evidence: {path: 'history/' + IDEA + '/metadata/' + 'b'.repeat(64) + '.md', sha256: 'c'.repeat(64)}, ...changes}];`
- tests/web/exploration-proposals.test.mjs:233 [K.assembly-code] (test-data): `await h.get('exploration-use-proposal-' + PID).click(); h.state.agent_generation = 'agent_' + '5'.repeat(32);`
- tests/web/exploration-proposals.test.mjs:353 [K.assembly-code] (test-data): `const other = copy(h.state); other.idea_id = 'idea_' + '6'.repeat(32); other.proposal_inventory.index_path = other.idea_id + '.md'; other.drafts.exploration.investment.cap = null;`
- tests/web/exploration.test.mjs:11 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), GEN = 'agent_' + '3'.repeat(32);`
- tests/web/exploration.test.mjs:26 [K.assembly-code] (test-data): `const state = {ok: true, code: 'ok', session_id: 'session_' + '2'.repeat(32), idea_id: IDEA, idea_status: 'active', revision: 3, draft_version: 0, backlog_revision: 0,`
- tests/web/folds.test.mjs:11 [K.assembly-code] (test-data): `const BINDING = 'binding_' + '1'.repeat(32);`
- tests/web/folds.test.mjs:12 [K.assembly-code] (test-data): `const SESSION = 'session_' + '2'.repeat(32);`
- tests/web/handoff-api.test.mjs:7 [K.assembly-code] (test-data): `const binding = 'binding_' + 'a'.repeat(32), session = 'session_' + 'b'.repeat(32);`
- tests/web/handoff-api.test.mjs:8 [K.assembly-code] (test-data): `const idea = 'idea_' + 'c'.repeat(32), otherIdea = 'idea_' + 'd'.repeat(32);`
- tests/web/handoff-api.test.mjs:9 [K.assembly-code] (test-data): `const handoff = 'handoff_' + 'e'.repeat(32), hash = 'f'.repeat(64), digest = '1'.repeat(64);`
- tests/web/handoff-api.test.mjs:74 [K.assembly-code] (test-data): `{handoff_id:'handoff_'+'2'.repeat(32)},{sha256:digest},{path:packet().path},{handoff_index:0},`
- tests/web/handoff-api.test.mjs:103 [K.assembly-code] (test-data): `const asset='asset_'+'3'.repeat(32),member={asset_id:asset,name:'../../literal💡.md',type:'text/markdown',`
- tests/web/handoff-api.test.mjs:105 [K.assembly-code] (test-data): `const p=packet();p.design_set={set_id:'set_'+'4'.repeat(32),members:[member]};`
- tests/web/handoff-api.test.mjs:141 [K.assembly-code] (test-data): `newer.handoff_id='handoff_'+'5'.repeat(32);`
- tests/web/handoff-api.test.mjs:156 [K.assembly-code] (test-data): `for(const delta of [{session_id:'session_'+'6'.repeat(32)},{idea_id:otherIdea}]) {`
- tests/web/handoff-api.test.mjs:189 [K.assembly-code] (test-data): `for(const delta of [{session_id:'session_'+'7'.repeat(32)},{idea_id:otherIdea},{revision:0},`
- tests/web/handoff-api.test.mjs:249 [K.assembly-code] (test-data): `const asset='asset_'+'8'.repeat(32),upload='upload_'+'9'.repeat(32);`
- tests/web/handoff-controller.test.mjs:10 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), OTHER = 'idea_' + '2'.repeat(32);`
- tests/web/handoff-controller.test.mjs:11 [K.assembly-code] (test-data): `const SESSION = 'session_' + '3'.repeat(32), BINDING = 'binding_' + '4'.repeat(32);`
- tests/web/handoff-controller.test.mjs:12 [K.assembly-code] (test-data): `const PACKET = 'handoff_' + '5'.repeat(32), HASH = 'a'.repeat(64), DIGEST = 'b'.repeat(64);`
- tests/web/handoff-controller.test.mjs:158 [K.assembly-code] (test-data): `else installPacket(value,packet(IDEA,'c'.repeat(64),'handoff_'+'6'.repeat(32),'d'.repeat(64)));`
- tests/web/handoff-controller.test.mjs:179 [K.assembly-code] (test-data): `for(const changed of [packet(IDEA,HASH,'handoff_'+'7'.repeat(32)),packet(IDEA,'c'.repeat(64)),packet(IDEA,HASH,PACKET,'d'.repeat(64))]) {`
- tests/web/handoff-controller.test.mjs:200 [K.assembly-code] (test-data): `h.flow.pending={operation:'draft',ambiguous:true};h.flow.selectedProposals.exploration='proposal_'+'8'.repeat(32);`
- tests/web/handoff-controller.test.mjs:220 [K.assembly-code] (test-data): `h.flow.selectedProposals.exploration='proposal_'+'8'.repeat(32);h.flow.proposalError={code:'old'};`
- tests/web/handoff-controller.test.mjs:252 [K.assembly-code] (test-data): `if(mode==='wrong-session')h.faults.selectionReply=r=>({...r,session_id:'session_'+'9'.repeat(32)});`
- tests/web/handoff-controller.test.mjs:324 [K.assembly-code] (test-data): `h.faults.read=()=>response(foreign==='idea'?state(OTHER):{...state(ideaId),session_id:'session_'+'9'.repeat(32)});`
- tests/web/handoff-controller.test.mjs:339 [K.assembly-code] (test-data): `h.faults.read=()=>response(foreign==='idea'?state(OTHER):{...state(null),session_id:'session_'+'9'.repeat(32)});`
- tests/web/handoff-controller.test.mjs:363 [K.assembly-code] (test-data): `h.flow.current='capture';h.flow.paused=true;h.flow.selectedProposals.exploration='proposal_'+'8'.repeat(32);`
- tests/web/handoff-controller.test.mjs:368 [K.assembly-code] (test-data): `assert.equal(h.flow.selectedProposals.exploration,'proposal_'+'8'.repeat(32));assert.ok(h.flow.error);`
- tests/web/handoff-controller.test.mjs:380 [K.assembly-code] (test-data): `if(mode==='state-session')h.faults.read=()=>response({...state(),session_id:'session_'+'9'.repeat(32)});`
- tests/web/handoff-controller.test.mjs:395 [K.assembly-code] (test-data): `h.api.sessionId='session_'+'9'.repeat(32);flight.resolve(response({...state(null),session_id:h.api.sessionId}));`
- tests/web/handoff-controller.test.mjs:403 [K.assembly-code] (test-data): `h.faults.read=value=>response({...value,session_id:'session_'+'9'.repeat(32)});`
- tests/web/handoff.test.mjs:16 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), OTHER = 'idea_' + '2'.repeat(32);`
- tests/web/handoff.test.mjs:17 [K.assembly-code] (test-data): `const SESSION = 'session_' + '3'.repeat(32), BINDING = 'binding_' + '4'.repeat(32);`
- tests/web/handoff.test.mjs:21 [K.assembly-code] (test-data): `const packet = (id = IDEA) => ({handoff_id: 'handoff_' + '5'.repeat(32), source_revision: 6, source_digest: DIGEST,`
- tests/web/handoff.test.mjs:23 [K.assembly-code] (test-data): `prompt: '/glitch-plan\nLiteral <script> and 💡 prompt\n' + 'Full prompt line\n'.repeat(300),`
- tests/web/handoff.test.mjs:294 [K.assembly-code] (test-data): `}, h => {h.faults.read = value => response(kind === 'idea' ? state(OTHER) : {...value, session_id: 'session_' + '9'.repeat(32)});});`
- tests/web/handoff.test.mjs:325 [K.assembly-code] (test-data): `faults.read = value => response(kind === 'idea' ? state(OTHER) : {...value, session_id: 'session_' + '9'.repeat(32)});`
- tests/web/idea-markdown-api.test.mjs:7 [K.assembly-code] (test-data): `const binding = 'binding_' + 'a'.repeat(32), idea = 'idea_' + 'c'.repeat(32);`
- tests/web/locks.test.mjs:9 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), SID = 'session_' + '2'.repeat(32), BINDING = 'binding_' + '6'.repeat(32), GEN = 'agent_' + '3'.repeat(32);`
- tests/web/method-cards.test.mjs:27 [K.assembly-code] (test-data): `const state = {ok: true, code: 'ok', session_id: 'session_' + '2'.repeat(32), idea_id: 'idea_' + '1'.repeat(32), idea_status: 'active', revision: 2, draft_version: 0, backlog_revision: 1,`
- tests/web/method-cards.test.mjs:32 [K.assembly-code] (test-data): `drafts: pick ? {method: {selection: pick, reason: '', memory: {status: 'unavailable', sources: [], rationale: null}}} : {}, draft: null, agent_status: 'connected', agent_generation: 'agent_' + '3'.repeat(32),`
- tests/web/method-cards.test.mjs:34 [K.assembly-code] (test-data): `proposal_sources: {method: {available: false, code: 'agent_unavailable', source: null}}, proposals: [], proposal_inventory: {total: 0, projected: 0, omitted: 0, content_omitted: 0, index_path: 'idea_' + '1'.repeat(32) + '.md'}};`
- tests/web/method.test.mjs:15 [K.assembly-code] (test-data): `const IDEA = 'idea_'+'1'.repeat(32), SID = 'session_'+'2'.repeat(32), GEN = 'agent_'+'3'.repeat(32), PID = 'proposal_'+'4'.repeat(32);`
- tests/web/method.test.mjs:82 [K.assembly-code] (test-data): `evidence:{path:'history/'+IDEA+'/metadata/'+'b'.repeat(64)+'.md',sha256:'c'.repeat(64)},...changes}];`
- tests/web/moved-ideas.test.mjs:7 [K.assembly-code] (test-data): `const binding = 'binding_' + 'a'.repeat(32), session = 'session_' + 'b'.repeat(32);`
- tests/web/moved-ideas.test.mjs:8 [K.assembly-code] (test-data): `const idea = 'idea_' + 'c'.repeat(32), other = 'idea_' + 'd'.repeat(32);`
- tests/web/prior-art.test.mjs:12 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32);`
- tests/web/prior-art.test.mjs:30 [K.assembly-code] (test-data): `const state = {ok: true, code: 'ok', session_id: 'session_' + '2'.repeat(32), idea_id: IDEA, idea_status: 'active', revision: 2, draft_version: 0, backlog_revision: 1,`
- tests/web/prior-art.test.mjs:34 [K.assembly-code] (test-data): `drafts: draft ? {discovery: draft} : {}, draft: null, agent_status: agent, agent_generation: agent === 'connected' ? 'agent_' + '3'.repeat(32) : null,`
- tests/web/proposals.test.mjs:9 [K.assembly-code] (test-data): `const IDEA = 'idea_'+'1'.repeat(32), SID = 'session_'+'2'.repeat(32), GEN = 'agent_'+'3'.repeat(32), PID = 'proposal_'+'4'.repeat(32);`
- tests/web/proposals.test.mjs:18 [K.assembly-code] (test-data): `const BINDING = 'binding_'+'6'.repeat(32);`
- tests/web/proposals.test.mjs:46 [K.assembly-code] (test-data): `evidence:{path:'history/'+IDEA+'/metadata/'+'a'.repeat(64)+'.md',sha256:'b'.repeat(64)},...overrides};`
- tests/web/proposals.test.mjs:235 [K.assembly-code] (test-data): `h.value.agent_generation='agent_'+'5'.repeat(32);await h.flow.refreshAgent();`
- tests/web/proposals.test.mjs:434 [K.assembly-code] (test-data): `const other=new Flow({...h.api,bindingId:'binding_'+'7'.repeat(32)},undefined,undefined,saved);other.load(copy(h.value));`
- tests/web/proposals.test.mjs:436 [K.assembly-code] (test-data): `const different=copy(h.value);different.idea_id='idea_'+'8'.repeat(32);different.proposals=[];updateInventory(different);`
- tests/web/proposals.test.mjs:448 [K.assembly-code] (test-data): `const next='proposal_'+'9'.repeat(32);h.value.proposals[0].proposal_id=next;await h.flow.refreshAgent();`
- tests/web/proposals.test.mjs:538 [K.assembly-code] (test-data): `v=>v.proposals[0].evidence.path='history/idea_'+'f'.repeat(32)+'/metadata/'+'a'.repeat(64)+'.md',`
- tests/web/rerank-api.test.mjs:7 [K.assembly-code] (test-data): `const binding = 'binding_' + 'a'.repeat(32), session = 'session_' + 'b'.repeat(32), idea = 'idea_' + 'c'.repeat(32);`
- tests/web/rerank-api.test.mjs:31 [K.assembly-code] (test-data): `for (const reply of [{...good, position: 2}, {...good, write_state: 'not_applied'}, {...good, idea_id: 'idea_' + 'd'.repeat(32)}, {...good, extra: 1}]) {`
- tests/web/setup.test.mjs:9 [K.assembly-code] (test-data): `const A = 'binding_' + 'a'.repeat(32), SA = 'session_' + 'a'.repeat(32);`
- tests/web/setup.test.mjs:260 [K.assembly-code] (test-data): `h.find('setup-url').type_('https:' + '//board.example'); h.find('setup-key').type_('has spaces in it');`
- tests/web/upload-api.test.mjs:7 [K.assembly-code] (test-data): `const binding = 'binding_' + 'a'.repeat(32), idea = 'idea_' + 'b'.repeat(32);`
- tests/web/upload-api.test.mjs:8 [K.assembly-code] (test-data): `const upload = 'upload_' + 'c'.repeat(32), asset = 'asset_' + 'd'.repeat(32);`
- tests/web/upload-api.test.mjs:93 [K.assembly-code] (test-data): `for(const body of [result(completion,{asset_id:null}),result('other'),result(completion,{upload_id:'upload_'+'e'.repeat(32)}),`
- tests/web/upload-api.test.mjs:129 [K.assembly-code] (test-data): `for(const receipt of [result(completion,{idea_id:'idea_'+'e'.repeat(32)}),result('other'),`
- tests/web/visualize-controller.test.mjs:8 [K.assembly-code] (test-data): `const IDEA = 'idea_' + '1'.repeat(32), OTHER = 'idea_' + '2'.repeat(32);`
- tests/web/visualize-controller.test.mjs:9 [K.assembly-code] (test-data): `const SET = 'set_' + '3'.repeat(32), NEXT_SET = 'set_' + '4'.repeat(32);`
- tests/web/visualize-controller.test.mjs:10 [K.assembly-code] (test-data): `const ASSET = 'asset_' + '5'.repeat(32), SECOND = 'asset_' + '6'.repeat(32);`
- tests/web/visualize.test.mjs:14 [K.assembly-code] (test-data): `const IDEA='idea_'+'1'.repeat(32),OTHER='idea_'+'2'.repeat(32),SESSION='session_'+'3'.repeat(32),BINDING='binding_'+'4'.repeat(32);`
- tests/web/visualize.test.mjs:15 [K.assembly-code] (test-data): `const HEX='a'.repeat(64),SET='set_'+'5'.repeat(32);`
- tests/web/visualize.test.mjs:293 [K.assembly-code] (test-data): `const h=harness();h.state.asset_inventory.orphans={count:140,ids:[id('asset',90),'stage_'+id('upload',91).slice('upload_'.length)+'_'+'9'.repeat(32)]};h.reload();`
- tests/web/visualize.test.mjs:297 [K.assembly-code] (test-data): `for(const orphan of ['stage_'+id('upload',91)+'_'+'9'.repeat(32),'stage_'+'9'.repeat(31)+'_'+'9'.repeat(32),`
- tests/web/visualize.test.mjs:298 [K.assembly-code] (test-data): `'stage_'+'9'.repeat(32)+'_'+'9'.repeat(33),'../stage_'+'9'.repeat(32)+'_'+'9'.repeat(32),'assets/staging/private.part']){`
- tests/web/visualize.test.mjs:396 [K.assembly-code] (test-data): `h.state.session_id='session_'+'9'.repeat(32);h.reload();h.choose([file()]);`
- tests/web/visualize.test.mjs:449 [K.assembly-code] (test-data): `Object.assign(h.state,{agent_status:'connected',agent_generation:'agent_'+'6'.repeat(32),proposals:[],`
- tests/web/visualize.test.mjs:458 [K.assembly-code] (test-data): `const answer=(h,skill)=>{h.state.proposals=[{proposal_id:'proposal_'+'7'.repeat(32),request_id:h.sent.at(-1).payload.request_id,operation:'visual_brief',accepted_revision:4,draft_version:0,`

#### phrase.creds (54 lines)

Patterns: creds.desktop 8, creds.enumerate 8, creds.path 15, creds.secret-name 23

- README.md:250 [creds.desktop] (human): `` When the browser's Review step is ready, **Generate planning prompt** saves an immutable planning packet, and **Copy planning prompt** puts a prompt beginning `/glitch-plan` on your clipboard. ``
- docs/acceptance-browser-flow.md:73 [creds.desktop] (human): `` 12. Complete the handoff: in Review, choose **Copy planning prompt** with the clipboard permission granted, confirm the clipboard holds exactly the generated prompt, write a minimal real plan carrying its `## Idea trace`, run `register-plan`, and confirm the idea is archived at that revision and `doctor` is healthy. ``
- docs/browser-api.md:11 [creds.desktop] (human): `` All application routes are under `/api/v1/`. Reads require a browser session ``
- docs/browser-api.md:479 [creds.secret-name] (human): `` `X-Idea-Agent-Binding`, `X-Idea-Agent-Generation` and Bearer authorization headers. ``
- docs/browser-api.md:482 [creds.secret-name] (human): `refused on every non-agent route; Bearer authorization is accepted only on the`
- docs/browser-api.md:738 [creds.desktop] (human): `app. Review/Ideas render names, paths and prompts as text. Copy checks server\nreadiness plus local dirty/pending state; successful clipboard write returns to`
- docs/browser-api.md:809 [creds.desktop] (human): `prompt as text. Copy checks currentness before clipboard write and again after`
- docs/cp4-validation.md:91 [creds.desktop] (human): `hit-test guards remained. Explicit SelectAll/Copy use real Input, without a JS\nclipboard shim or clipboard reads. All proof helper hashes and the actual source`
- docs/cp4-validation.md:164 [creds.desktop] (human): `97d7081 completed Capture through Assess, prompt generation, actual clipboard`
- glitch-idea/references/commands.md:197 [creds.enumerate] (model): `` The next-slice file given to `exploration` is validated whole by the same checks that accept the Exploration step, so every key is required and nothing may be left empty. It has exactly these keys: `outcome`, `scope` (one of the scope values in [methods.md](methods.md)), `scope_reason`, `next_slice` (non-empty text), `alternatives` (at least one `route` and `reason`), `assumptions` and `learning` (lists, which may be empty: send an empty list (`[]`), never null, and never omit them, because the page keeps an undelivered field locked), `sketch` (one to five slices, each with `title`, `why_next`, `done_when` and a `method` from [methods.md](methods.md)), and `investment` and `experiment`. In this file, and only here, leave `investment` and `experiment` as `null` unless the chosen method needs them: `investment` is `{"cap", "unit", "boundary"}` and `experiment` is `{"question", "evidence", "success_criterion", "stop_rule"}`. ``
- glitch-idea/scripts/idea_bridge.py:407 [creds.enumerate] (tool): `pass  # No stack trace may dump credentials or domain data.`
- glitch-idea/scripts/idea_runtime.py:388 [creds.path] (tool): `_check(set(names) <= {'service.lock', 'discovery.json', 'credentials.json', 'bindings'})`
- glitch-idea/scripts/idea_runtime.py:393 [creds.path] (tool): `else: _identity(_json(raw), self.store_sha256, credential=name == 'credentials.json')`
- glitch-idea/scripts/idea_runtime.py:507 [creds.path] (tool): `if name in ('credentials.json', 'discovery.json'):`
- glitch-idea/scripts/idea_runtime.py:550 [creds.path] (tool): `self._write(directory, 'credentials.json', self._credential)`
- glitch-idea/scripts/idea_runtime.py:713 [creds.path] (tool): `credential = _identity(_json(_raw(directory, 'credentials.json')), self.store_sha256, credential=True)`
- glitch-idea/scripts/idea_sessions.py:184 [creds.enumerate] (tool): `self.persist(copy.deepcopy(record))  # SID before any credential exposure.`
- glitch-idea/scripts/idea_ssh.py:173 [creds.path] (tool): `path = path or os.path.expanduser('~/.ssh/config')`
- tests/native_probe.py:165 [creds.enumerate] (test-data): `check(isinstance(value['code'], str) and value['code'].isascii() and secrets.compare_digest(value['code'], self.code),`
- tests/test_agent_client.py:166 [creds.path] (test-data): `os.chmod(self.owner.path/'credentials.json',0o644)`
- tests/test_agent_client.py:168 [creds.path] (test-data): `finally: os.chmod(self.owner.path/'credentials.json',0o600)`
- tests/test_agent_launch.py:111 [creds.enumerate] (test-data): `self.assertNotIn(credentials['token'],json.dumps(after));self.assertNotIn(credentials['token'],repr(self.agent))`
- tests/test_agent_transport.py:296 [creds.secret-name] (test-data): `if request.header('Authorization') != 'Bearer fixture-owner':`
- tests/test_agent_transport.py:306 [creds.secret-name] (test-data): `headers={'Authorization':'Bearer fixture-owner', name:value})`
- tests/test_agent_transport.py:312 [creds.secret-name] (test-data): `self.assertEqual(self.http('/control/v1/probe', {}, headers={'Authorization':'Bearer fixture-owner'})[0], 200)`
- tests/test_agent_transport.py:317 [creds.secret-name] (test-data): `headers={'Authorization':'Bearer fixture-owner', name:value})[0], 403)`
- tests/test_bridge.py:301 [creds.secret-name] (test-data): `status,error,_=self.request(path,authenticated=False,extra={'Authorization':'Bearer fixture'})`
- tests/test_bridge_control.py:48 [creds.secret-name] (test-data): `check(request.header('Authorization')=='Bearer fixture-owner','owner_unauthorized',401)`
- tests/test_bridge_control.py:55 [creds.secret-name] (test-data): `if path.split('?',1)[0] in CONTROL_PATHS: headers['Authorization']='Bearer fixture-owner'`
- tests/test_bridge_control.py:78 [creds.secret-name] (test-data): `raw=self.raw(('POST /control/v1/stop HTTP/1.0\r\nHost: '+self.server.host+'\r\nContent-Type: application/json\r\nAuthorization: Bearer fixture-owner\r\nContent-Length: 2\r\n\r\n{}').encode())`
- tests/test_bridge_control.py:91 [creds.secret-name] (test-data): `raw=self.raw(('POST /control/v1/probe HTTP/1.0\r\nHost: '+self.server.host+'\r\nContent-Type: application/json\r\nAuthorization: Bearer fixture-owner\r\nAuthorization: Bearer fixture-owner\r\nContent-Length: 2\r\n\r\n{}').encode())`
- tests/test_bridge_control.py:132 [creds.secret-name] (test-data): `sock.sendall(('POST /control/v1/probe HTTP/1.0\r\nHost: '+self.server.host+'\r\nContent-Type: application/json\r\nAuthorization: Bearer fixture-owner\r\nContent-Length: 2\r\n\r\n{').encode())`
- tests/test_fixed_ports.py:286 [creds.secret-name] (test-data): `failure = launch.LaunchError('port_mismatch', port=self.port, owner_token='SECRET')`
- tests/test_launcher_cli.py:188 [creds.secret-name] (test-data): `resume_required=True,owner_token='SECRET',diagnostic='private child output')`
- tests/test_launcher_cli.py:267 [creds.path] (test-data): `credentials=json.loads((self.client.path/'credentials.json').read_bytes())`
- tests/test_native_probe.py:95 [creds.secret-name] (test-data): `self.assertEqual(self.http('/agent/status', {}, {'Authorization': 'Bearer wrong'})[0], 401)`
- tests/test_runtime.py:124 [creds.path] (test-data): `for path in (self.owner.path / 'service.lock', self.owner.path / 'credentials.json', self.owner.path / 'discovery.json',`
- tests/test_runtime.py:143 [creds.path] (test-data): `original = json.loads((self.owner.path / 'credentials.json').read_bytes())`
- tests/test_runtime.py:149 [creds.path] (test-data): `current = json.loads((self.owner.path / 'credentials.json').read_bytes())`
- tests/test_runtime.py:238 [creds.path] (test-data): `credential = json.loads((self.owner.path / 'credentials.json').read_bytes())`
- tests/test_runtime_identity.py:65 [creds.path] (test-data): `token = json.loads((self.owner.path / 'credentials.json').read_bytes())['owner_token']`
- tests/test_ssh_mode.py:18 [creds.secret-name] (test-data): `SECRET = 'a1' * 16`
- tests/test_ssh_mode.py:41 [creds.path] (test-data): `self.hosts = hosts or {a: (a, USER, '22', ('~/.ssh/k_' + a,)) for a in clients}`
- tests/test_ssh_mode.py:90 [creds.secret-name] (test-data): `return Result(0, '{"ok":true,"proof":"%s"}' % idea_runtime.expected_tunnel_proof(SECRET, nonce))`
- tests/test_ssh_mode.py:190 [creds.secret-name] (test-data): `return lambda alias: idea_ssh.check_tunnel(fake, alias, 8840, SECRET, idea_runtime.expected_tunnel_proof)`
- tests/test_ssh_mode.py:401 [creds.secret-name] (test-data): `return idea_ssh.check_tunnel(Fake({'c': Client(**kw)}), 'c', 8840, SECRET, idea_runtime.expected_tunnel_proof)`
- tests/test_ssh_mode.py:419 [creds.secret-name] (test-data): `self.assertEqual(code(idea_ssh.check_tunnel, Fake({}), 'c', 8840, SECRET, idea_runtime.expected_tunnel_proof)[0],`
- tests/test_ssh_mode.py:425 [creds.secret-name] (test-data): `idea_ssh.check_tunnel(fake, 'c', 8840, SECRET, idea_runtime.expected_tunnel_proof)`
- tests/test_ssh_mode.py:687 [creds.secret-name] (test-data): `return SECRET`
- tests/test_web_assets.py:230 [creds.enumerate] (test-data): `` # A font token (`--font-sans: ...`) is a family list too; size/weight/style tokens are not. ``
- tests/test_web_assets.py:567 [creds.enumerate] (test-data): `(copy / "web" / "assets" / "tokens.json").write_text("{}")`
- tests/test_web_assets.py:568 [creds.enumerate] (test-data): `self.assertEqual(sorted(banned_name_violations(copy)), ["bundle.css", "tokens.json"])`
- tests/web/handoff.test.mjs:133 [creds.desktop] (test-data): `assert.match(h.get('review-copy-status').textContent, /Clipboard unavailable/); assert.ok(h.get('review-manual-copy'));`
- tests/web/setup.test.mjs:10 [creds.secret-name] (test-data): `[line not shown: it holds what looks like a secret; open the file to see it]`

#### phrase.remote-load (1 line)

Patterns: RL.branch-ref 1

- glitch-idea/references/commands.md:64 [RL.branch-ref] (model): `` A store keeps at most eight sessions (bindings). Resume an existing binding when continuing work. When a new open needs room, a session whose idea reached Review (its Review step is saved) and that has no open browser tab or terminal agent is freed automatically, the least recently used first; its ideas and receipts are untouched. A session that is unfinished or still open is never freed automatically: the open is refused with `binding_capacity` and the JSON error carries a `sessions` list. An ambiguous partial private write reports `runtime_recovery_conflict` and preserves the bytes for explicit recovery. An ambiguous partial private write reports `runtime_recovery_conflict` and preserves the bytes for explicit recovery. Domain recovery and supported Markdown edits are described in [the Markdown format](https://github.com/blastworksai/tools/tree/main/skills/glitch-idea/docs/markdown-format.md). ``

### 4b Taking the wheel

#### phrase.L.override (3 lines)

Patterns: L.override 2, L.skip-confirm 1

- docs/workflow-api.md:12 [L.override] (human): `With Option 2 the API replaces the Markdown store: the idea's record lives in your system, and its detailed Markdown files live in the idea's own workspace (the project folder chosen at Capture), not in the Glitch store.`
- glitch-idea/SKILL.md:59 [L.override] (model): `` If the link expired or the click was missed, run `browser-open --browser link --resume <binding_id>` and show the new link the same way. In link mode this replaces the "ready to type a code?" question; the typed-code path above keeps its Ready-first rule. ``
- glitch-idea/scripts/idea_store.py:1998 [L.skip-confirm] (tool): `Without confirm: a preview and nothing written. With confirm, under the`

#### phrase.A.consent (3 lines)

Patterns: A.prior-consent 3

- glitch-idea/SKILL.md:243 [A.prior-consent] (model): `Save the outcome, alternatives, scope rationale, assumptions and next useful slice through the browser flow. Fill only the fields the operator agreed; a fill never carries a null top-level field value (nested nulls only as documented in Guided conversation). The method is chosen by the operator on Methods. An epic gets an outcome/dependency map and next decision, not speculative detailed plans for all its projects. Wayfinder, rocket-fuel, grilling and other discovery skills are optional when available and useful; their absence does not block this workflow.`
- glitch-idea/references/commands.md:134 [A.prior-consent] (model): `` `fill` sends fields the operator agreed in the terminal for the page to apply to the open step. ``
- glitch-idea/scripts/idea_proposals.py:428 [A.prior-consent] (tool): `"""Record fields the human agreed in the terminal for the page to apply.`

#### phrase.B.defs (35 lines)

Patterns: B.absence 1, B.means 5, B.safety-adjective 29, B.safety-exception 2

- README.md:272 [B.safety-adjective] (human): `` When a plan is registered for a different workspace, `register-plan` takes `--workspace-name` and `--workspace-path` (both or neither) and moves the idea's living detail file to `<workspace>/ideas/<idea_id>.md`.\nHistory, metadata and frozen plan evidence stay in the store, with an immutable pointer.\nA moved idea is read-only from glitch-idea; further slices happen in the project. ``
- README.md:274 [B.safety-adjective] (human): `` A moved idea is read-only from glitch-idea; further slices happen in the project.\n`deliver idea_ID --ref TEXT` marks a moved idea delivered, once and permanently. ``
- docs/browser-api.md:419 [B.safety-adjective] (human): `` A moved or delivered idea is read-only: every browser save for it is refused `idea_moved` (409) with `details.home`. ``
- docs/browser-api.md:445 [B.safety-adjective] (human): `` The reply is `{ok, code, idea_id, step, hand, released, write_state, revision, draft_version}`, with `released` the number of requests cancelled; the call is idempotent. ``
- docs/browser-api.md:589 [B.means] (human) (stated as a prohibition (never)): `result and state reads against this identity; a missing receipt never means a\ncompleted upload. An explicit same-upload retry hashes the supplied bytes. The`
- docs/browser-api.md:732 [B.safety-adjective] (human): `` retains current answers and reports `session_persistence_failed`. Reads/Open\n  must not clear unsaved buffers or ambiguous requests implicitly. Selection\n  is idempotent and updates no accepted/draft/backlog counter. Do not add a new ``
- docs/browser-api.md:807 [B.safety-adjective] (human): `` The app loads six fixed literal modules, including `/ideas.js`; missing HTTP404\nalone means unavailable. Review shows accepted summaries and the full read-only ``
- docs/browser-runbook.md:201 [B.means] (human) (stated as a prohibition (never)): `` A page that never answers with the tunnel up usually means the seat's service idled out after 15 minutes; run `browser-open --browser link --resume binding_ID` to start it again. ``
- docs/cp4-validation.md:180 [B.safety-adjective] (human): `` linear on `f902408`; the implementer's worktree was not written. a reviewer reviewed every round\nheadless, read-only and systemd-fenced. Verdicts are saved verbatim in ``
- docs/cp4-validation.md:181 [B.safety-adjective] (human): `` headless, read-only and systemd-fenced. Verdicts are saved verbatim in\na private review report to `-r5.md`. ``
- docs/markdown-format.md:305 [B.safety-adjective] (human): `` `deliver` writes the immutable `history/<id>/delivered.md` and a `glitch_idea_delivered` index link; the reference is one line of 1 to 500 characters.\nA moved idea is read-only from glitch-idea, and no store file keeps a copy of the home file. ``
- docs/markdown-format.md:306 [B.safety-adjective] (human): `` A moved idea is read-only from glitch-idea, and no store file keeps a copy of the home file.\n`doctor` treats a missing home file or workspace folder as unhealthy and an edited home file as a notice; `repair-views` never writes outside the store. ``
- glitch-idea/SKILL.md:58 [B.safety-exception] (model): `` Never print `pairing_code` or `fallback_line` unless the operator says the click did not pair. ``
- glitch-idea/SKILL.md:160 [B.safety-adjective] (model): `` Run the bounded memory retrieval (when no other memory capability is available, a read-only `list` of this store's own ideas, with their accepted methods, is an acceptable bounded retrieval) and send a method memory fill only: `fields: {"memory": {status, sources, rationale, preferred_method}}`. `preferred_method` is one of the four method ids and is REQUIRED when `status` is `found`; otherwise it is null. Never select, fill or favour a method beyond that memory line: the operator picks one of the four equal cards and writes any reason themselves. The memory status is one of `found` (with `preferred_method`), `varied` (all four in use), `searched_no_preference`, `unavailable` or `error`. Never send `selection` or `reason`. Recommend only when the operator asks in the terminal for a method: one recommendation with its reason, in the terminal only, never in a fill. Unasked, lay out nothing beyond the memory line. ``
- glitch-idea/SKILL.md:203 [B.safety-adjective] (model): `` Read its first JSON line for `origin`, `port` and `fixed_port`.\nIt serves on its own loopback port, sandboxed by CSP, with no cookies. ``
- glitch-idea/SKILL.md:204 [B.safety-adjective] (model): `` It serves on its own loopback port, sandboxed by CSP, with no cookies.\nOpen a second tab on `origin` (Orca `tab create --url <origin>` in the same worktree, or the system browser). ``
- glitch-idea/SKILL.md:220 [B.means, B.safety-adjective] (model): `` Review sends no request: there is nothing to fill or answer. After the planning prompt the service may end; `agent_unavailable` there means the run is over, not an error. To tell that end from a failure: once Assess is accepted the next `events` may return `agent_unavailable`; do a read-only `show` of the idea. If `workflow.current_step` is `review` and `workflow.steps.assess.acceptance` is set, the run is over: say the review is ready, give no further command, and stop. Otherwise follow the stop list. ``
- glitch-idea/SKILL.md:260 [B.safety-adjective] (model): `` **Read-only after the move.** A moved or delivered idea answers `show` and `list`, but every mutation (`exploration` including a next slice, `rate`, `assess`, `propose`, `place`, `handoff`, `record-execution` and browser saves) is refused `idea_moved` with the home in its details. ``
- glitch-idea/SKILL.md:264 [B.safety-exception] (model): `` Do not call `deliver` unless the operator or the workflow that did the work says it is done. ``
- glitch-idea/references/commands.md:50 [B.safety-adjective] (model): `` `--reconnect` reads the pairing mark of the page recorded for that binding (`orca eval`, read-only). Only a page marked unpaired is touched: the service retires its browser credentials and issues a fresh one-time code for the same agent generation, and `orca goto --page` loads `<origin>/#pair=<code>` into that same page, which pairs itself. No tab is created or closed, the agent keeps its credential and lease, and the code is never printed. A paired page returns `browser.reconnected: false` with `reason: tab_still_paired`, and a page still loading returns `tab_not_unpaired`; neither changes anything. `tab_not_recorded` (no Orca page recorded for the binding) and `tab_unreadable` (Orca could not read it, for example the operator closed it) change nothing either: say so in one line and use `--resume` only on the operator's word. `--reconnect` is Orca-only and refuses `--resume`, `--idea-id` and the system browser (`usage`). ``
- glitch-idea/references/commands.md:132 [B.means, B.safety-adjective] (model): `` Review sends no request; after the planning prompt the service may end, and `agent_unavailable` there means the run is over, not an error. To tell that end from a failure: once Assess is accepted the next `events` may return `agent_unavailable`; a read-only `show` of the idea with `workflow.current_step` `review` and `workflow.steps.assess.acceptance` set means the run is over; otherwise follow the stop list in SKILL.md. ``
- glitch-idea/references/commands.md:144 [B.safety-adjective] (model): `` `sessions` is read-only and prints `{ok: true, sessions: [...]}`: one row per retained session with `binding_id`, `selected_idea_id`, `title` (the idea's text, at most 80 characters), `finished` (its Review step is saved) and `in_use` (a browser tab or terminal agent is still connected). ``
- glitch-idea/references/commands.md:162 [B.safety-adjective] (model): `` `prototype-serve` serves a built prototype folder on its own loopback port, sandboxed by CSP, with no cookies, and runs until the session ends, so start it in the background (a background job or `&`): ``
- glitch-idea/references/commands.md:259 [B.safety-adjective] (model): `` `handoff` is read-only and needs complete Exploration, human ratings and an assessment. It returns the exact trace block and current revision for the planner. Preserve its values, outside the planner's closed `## Build choices` section: ``
- glitch-idea/references/commands.md:281 [B.safety-adjective] (model): `` A moved or delivered idea is read-only from glitch-idea. `show` and `list` still work and carry `lifecycle` (`active`, `moved` or `delivered`), `home` and `delivered_ref`; `list` also has a `lifecycles` map. Every mutation (`exploration` including a next slice, `rate`, `assess`, `propose`, `place`, `handoff`, `record-execution`, browser saves) is refused `idea_moved` with `details.home`. The browser bridge answers 409 for `idea_moved`, `not_moved` and `delivery_conflict`. From the move on, next slices happen in the project. ``
- glitch-idea/references/commands.md:302 [B.safety-adjective] (model): `` Statuses are `succeeded|failed|blocked`. Evidence must be nonempty and grounded in actual actions. An attempt ID identifies one attempt: retries receive new IDs; an identical registration is idempotent and conflicting reuse is rejected. Keep execution receipt files at their durable paths. Registration validates identity and file integrity against the frozen accepted plan; it does not independently prove every factual claim in a receipt. Unregistered executor runs remain outside this trace. ``
- glitch-idea/references/commands.md:324 [B.safety-adjective] (model): `` An immutable tombstone `history/removed/<id>.md` (`<id>.2.md`, `<id>.3.md` … when the same idea was imported again and removed again) is written in the same publish, sealed read-only (0400, or 0440 in a shared store): idea id, actor, time, first words and a manifest of the removed paths with their sha256. ``
- glitch-idea/scripts/idea_native.py:212 [B.safety-adjective] (tool): `` Read-only: `orca eval` of a fixed expression, scoped to the binding's own worktree. ``
- tests/browser_flow_smoke.mjs:5 [B.safety-adjective] (test-data): `// from the DOM; page scripts are evaluated READ-ONLY. These events prove page`
- tests/browser_flow_smoke.mjs:534 [B.safety-adjective] (test-data): `` return `prompt read-only: starts with /glitch-plan, has ## Idea trace, ${promptText.length} chars; untrusted text literal in summary`; ``
- tests/browser_flow_smoke.mjs:1481 [B.safety-adjective] (test-data): `` return `${cards.length} cards (${chips}); ${resumable.length} with Step N of 8 · Resume; Markdown read-only in <pre> (contains "${word}"); moved one idea up ${mover.position}->${mover.position - 1}, CLI order and cards agree`; ``
- tests/test_idea.py:271 [B.absence] (test-data): `self.skipTest('Optional integration: plan_validator_argv is not configured')`
- tests/test_skill_text.py:226 [B.means] (test-data): `` rule = r"Review sends no request.{0,300}`agent_unavailable` .{0,40}means the run is over, not an error" ``
- tests/test_skill_text.py:245 [B.safety-adjective] (test-data): `` self.assertRegex(body, r"Review sends no request.{0,900}Assess is accepted.{0,300}read-only `show`.{0,200}current_step`.{0,60}`review`.{0,300}stop list") ``
- tests/test_skill_text.py:283 [B.safety-adjective] (test-data): `` self.assertRegex(body, r"(?i)moved or delivered idea.{0,60}(read-only|answers `show` and `list`)") ``

#### phrase.H.anti-review (22 lines)

Patterns: H.anti-inspect 2, H.evidence 2, H.sabotage 11, H.self-attest 2, H.suppress 3, H.unbounded 2

- docs/asset-format.md:40 [H.sabotage] (human): `records must name the active request session. This supersedes the unreleased`
- docs/browser-api.md:53 [H.self-attest] (human): `because the code is one-time and short-lived; domain Markdown still contains no`
- docs/browser-api.md:225 [H.anti-inspect] (human): `workspace is trusted resolution or service-host validated explicit selection;`
- docs/browser-api.md:255 [H.suppress] (human): `snapshot; it does not silently change the legacy snapshot keys.`
- docs/browser-api.md:436 [H.sabotage] (human): `usual; the operator accepts. Opening another step's conversation supersedes an`
- docs/browser-api.md:671 [H.evidence] (human): `rows; removing a local row does not delete retained Store history. Explicit`
- docs/cp2-validation.md:58 [H.suppress] (human): `it does not silently drop the link or discard the human draft.`
- docs/handoff-format.md:151 [H.suppress] (human): `this contract does not silently change the archived-idea policy:`
- docs/markdown-format.md:316 [H.sabotage] (human): `This supersedes v1 JSON's ability to regenerate frozen plans from duplicate`
- docs/orca-contract.md:30 [H.self-attest] (human): `contains no credentials, private host identifiers or personal ideas. The local`
- docs/orca-contract.md:265 [H.sabotage] (human): `This supersedes any inference that the earlier single-process five-wait test`
- docs/orca-contract.md:370 [H.sabotage] (human): `This supersedes the earlier unobserved/refused Claude compaction rows. After`
- glitch-idea/SKILL.md:202 [H.unbounded] (model): `` Then start `idea.py prototype-serve --session <session_id> --dir <that folder>`; it runs until the session ends, so start it in the background (a background job or `&`).\nRead its first JSON line for `origin`, `port` and `fixed_port`.\nIt serves on its own loopback port, sandboxed by CSP, with no cookies.\nOpen a second tab on `origin` (Orca `tab create --url <origin>` in the same worktree, or the system browser). ``
- glitch-idea/scripts/idea_proposals.py:392 [H.sabotage] (tool): `# Reaching another step, or another idea, supersedes an unanswered conversation. A reply`
- glitch-idea/scripts/idea_sessions.py:79 [H.anti-inspect] (tool): `agent_credentials is trusted-only and must never be routed to the browser.`
- glitch-idea/scripts/idea_ssh.py:534 [H.unbounded] (tool): `# The tunnel proof needs the service answering, so it starts first; nothing is allocated until the checks pass.`
- glitch-idea/web/api.js:456 [H.sabotage] (tool): `// An explicit navigation ATTEMPT supersedes older credential`
- glitch-idea/web/folds.js:1144 [H.sabotage] (tool): `// Leaving drops the local wait; the next step's request supersedes the old one on the service.`
- tests/test_agent_bridge.py:445 [H.sabotage] (test-data): `broker.enqueue(BIND,'gen1',self.other('request2'),self.source)   # supersedes request1`
- tests/test_skill_text.py:318 [H.evidence] (test-data): `for needed in ("remove-idea --idea", "--confirm", "preview", "writes nothing", "history/removed/", "tombstone",`
- tests/test_two_sessions.py:318 [H.sabotage] (test-data): `# B moves to another idea: that supersedes B's own conversation (within one binding) ...`
- tests/web/handoff-api.test.mjs:239 [H.sabotage] (test-data): `test('successful session credential installation supersedes an older pending 401',async()=>{`

#### phrase.I.conditional (5 lines)

Patterns: I.environment 2, I.failure-path 2, I.state 1

- docs/acceptance-browser-flow.md:142 [I.failure-path] (human): `` If the error is `origin_missing` or `usage`, no session exists: correct the arguments and rerun without `--resume`. ``
- docs/orca-contract.md:75 [I.state] (human): `Output contains only the non-secret loopback URL and initial session ID. The`
- glitch-idea/SKILL.md:234 [I.failure-path] (model): `` Launch with `browser-open` (or `session-open`) as described in commands.md, using the configured runtime interpreter. The service accepts only its exact `127.0.0.1:<port>` origin and needs an owner-private runtime directory (mode 0700, no symlink components). When the browser is on another computer and the seat has no fixed `browser_port`, tell the operator SSH mode needs a fixed port and a standing tunnel; never print an `ssh -L` line. If Orca launch fails with `origin_missing` or `usage`, no session exists yet: report it and have the selectors corrected, without `--resume`. If it fails later, the error carries the `binding_id` but no origin: report the code and the `binding_id`, do not silently open another browser, and let the operator choose between fixing Orca and rerunning `browser-open ... --resume binding_ID`, or running `session-open --resume binding_ID`, which prints the origin and a fresh pairing code to open themselves. ``
- glitch-idea/scripts/idea_workflow_api.py:46 [I.environment] (tool): `if host == 'localhost':`
- tests/test_ssh_mode.py:47 [I.environment] (test-data): `if host is None:`

### 4c Changing the environment

#### phrase.E.perms (185 lines)

Patterns: E.exec-primitive 166, E.install-global 2, E.outlives-session 17

- docs/cp4-validation.md:75 [E.exec-primitive] (human): `CLI registration of an exact revision6 Idea trace invoked that subprocess.`
- glitch-idea/scripts/idea_bridge.py:13 [E.outlives-session] (tool): `from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer`
- glitch-idea/scripts/idea_launch.py:20 [E.exec-primitive] (tool): `import subprocess`
- glitch-idea/scripts/idea_launch.py:563 [E.outlives-session] (tool): `probe = socket.socket(socket.AF_INET,socket.SOCK_STREAM)`
- glitch-idea/scripts/idea_launch.py:590 [E.exec-primitive] (tool): `spawn=subprocess.Popen,clock=time.monotonic,sleep=time.sleep):`
- glitch-idea/scripts/idea_launch.py:624 [E.exec-primitive] (tool): `child = spawn(argv,stdin=stream,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,`
- glitch-idea/scripts/idea_launch.py:644 [E.exec-primitive] (tool): `readiness_timeout=5,timeout=5,spawn=subprocess.Popen):`
- glitch-idea/scripts/idea_launch.py:663 [E.exec-primitive] (tool): `def open_browser_session(store_path,runtime_root,config=None,*,mode,orcabinding=None,runner=subprocess.run,**options):`
- glitch-idea/scripts/idea_launch.py:700 [E.exec-primitive] (tool): `def reconnect_browser_session(store_path,runtime_root,config=None,*,binding_id,orcabinding,runner=subprocess.run,`
- glitch-idea/scripts/idea_launch.py:701 [E.exec-primitive] (tool): `runtime_python=None,readiness_timeout=5,timeout=5,spawn=subprocess.Popen):`
- glitch-idea/scripts/idea_markdown.py:164 [E.exec-primitive] (tool): `value = yaml.load(front, Loader=BoundedLoader)`
- glitch-idea/scripts/idea_native.py:12 [E.exec-primitive] (tool): `import subprocess`
- glitch-idea/scripts/idea_native.py:35 [E.exec-primitive] (tool): `def __call__(self, argv: Sequence[str], **kwargs) -> subprocess.CompletedProcess: ...`
- glitch-idea/scripts/idea_native.py:89 [E.exec-primitive] (tool): `def _run(argv: list[str], runner: Runner, timeout: float) -> subprocess.CompletedProcess:`
- glitch-idea/scripts/idea_native.py:92 [E.exec-primitive] (tool): `shell=False, stdin=subprocess.DEVNULL)`
- glitch-idea/scripts/idea_native.py:95 [E.exec-primitive] (tool): `except subprocess.TimeoutExpired:`
- glitch-idea/scripts/idea_native.py:148 [E.exec-primitive] (tool): `runner: Runner = subprocess.run, timeout: float = 8) -> BrowserLaunch:`
- glitch-idea/scripts/idea_native.py:191 [E.exec-primitive] (tool): `runner: Runner = subprocess.run, timeout: float = 8) -> None:`
- glitch-idea/scripts/idea_native.py:209 [E.exec-primitive] (tool): `runner: Runner = subprocess.run, timeout: float = 8) -> str:`
- glitch-idea/scripts/idea_native.py:226 [E.exec-primitive] (tool): `runner: Runner = subprocess.run, timeout: float = 8) -> None:`
- glitch-idea/scripts/idea_prototype.py:18 [E.outlives-session] (tool): `from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer`
- glitch-idea/scripts/idea_service.py:15 [E.exec-primitive] (tool): `import subprocess`
- glitch-idea/scripts/idea_service.py:750 [E.exec-primitive] (tool): `result=subprocess.run(fixed,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,timeout=config['validator_timeout_seconds'],check=False)`
- glitch-idea/scripts/idea_service.py:755 [E.exec-primitive] (tool): `except subprocess.TimeoutExpired as exc:`
- glitch-idea/scripts/idea_ssh.py:9 [E.exec-primitive] (tool): `Process rules for this host: every subprocess call is an argv list with a timeout and BatchMode=yes, never a`
- glitch-idea/scripts/idea_ssh.py:22 [E.exec-primitive] (tool): `import subprocess`
- glitch-idea/scripts/idea_ssh.py:64 [E.exec-primitive] (tool): `done = subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout, shell=False,`
- glitch-idea/scripts/idea_ssh.py:65 [E.exec-primitive] (tool): `stdin=None if input is not None else subprocess.DEVNULL, errors='replace')`
- glitch-idea/scripts/idea_ssh.py:66 [E.exec-primitive] (tool): `except subprocess.TimeoutExpired:`
- glitch-idea/tern-plugin/README.md:24 [E.install-global] (human): `tern plugin install github.com/blastworksai/tools/skills/glitch-idea/glitch-idea/tern-plugin`
- install.py:11 [E.exec-primitive] (human): `import subprocess`
- install.py:157 [E.exec-primitive] (human): `probe = subprocess.run([str(python), "-E", "-B", "-c", PROBE], capture_output=True, text=True,`
- install.py:161 [E.exec-primitive] (human): `except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:`
- install.py:331 [E.exec-primitive] (human): `made = subprocess.run([sys.executable, "-m", "venv", str(venv)],`
- install.py:426 [E.exec-primitive] (human): `except (OSError, ValueError, subprocess.SubprocessError) as exc:`
- tests/browser_flow_smoke.mjs:14 [E.exec-primitive] (test-data): `import {spawn, spawnSync} from 'node:child_process';`
- tests/fake_workflow_api.py:7 [E.outlives-session] (test-data): `from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer`
- tests/fixtures/make_store_v2.py:14 [E.exec-primitive] (test-data): `import subprocess`
- tests/fixtures/make_store_v2.py:27 [E.exec-primitive] (test-data): `subprocess.run(['git', '-C', str(ROOT), 'archive', V02], stdout=handle, check=True)`
- tests/fixtures/make_store_v2.py:30 [E.exec-primitive] (test-data): `subprocess.run(['tar', '-xf', str(archive), '-C', str(source)], check=True)`
- tests/native_probe.py:7 [E.outlives-session] (test-data): `from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer`
- tests/test_agent_cli.py:1 [E.exec-primitive] (test-data): `"""real subprocess native verbs against fixed loopback owner/agent."""`
- tests/test_agent_cli.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_agent_cli.py:27 [E.exec-primitive] (test-data): `result=subprocess.run(argv,capture_output=True,timeout=8)`
- tests/test_agent_cli.py:66 [E.exec-primitive] (test-data): `result=subprocess.run([sys.executable,str(idea_script()),'respond','--session',self.sid,`
- tests/test_agent_cli.py:73 [E.exec-primitive] (test-data): `result=subprocess.run([sys.executable,str(idea_script()),'events','--session',self.sid,`
- tests/test_agent_client.py:2 [E.outlives-session] (test-data): `from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer`
- tests/test_asset_store.py:7 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_asset_store.py:462 [E.exec-primitive] (test-data): `child = subprocess.run([sys.executable,'-c',CHILD,str(SCRIPTS),str(Path(__file__).parent),`
- tests/test_bridge.py:9 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_bridge.py:969 [E.exec-primitive] (test-data): `result = subprocess.run(['node', '--input-type=module', '--eval', script, str(web)],`
- tests/test_chain_cli.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_chain_cli.py:34 [E.exec-primitive] (test-data): `done = subprocess.run([sys.executable, str(idea_script()), '--store', str(self.root), *map(str, args)],`
- tests/test_chain_fixtures.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_chain_fixtures.py:36 [E.exec-primitive] (test-data): `r = subprocess.run([sys.executable, str(idea_script()), '--store', str(self.root), *args], capture_output=True, timeout=30)`
- tests/test_cli_service.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_cli_service.py:39 [E.exec-primitive] (test-data): `result=subprocess.run([sys.executable,str(self.script),'--store',str(self.root),*map(str,args)],capture_output=True,timeout=8)`
- tests/test_cli_service.py:188 [E.exec-primitive] (test-data): `result=subprocess.run([sys.executable,str(self.script),'capture','--text-file',str(self.file('configured','.txt')),'--actor','operator'],capture_output=True,timeout=8)`
- tests/test_fixed_ports.py:7 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_fixed_ports.py:25 [E.outlives-session] (test-data): `sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)`
- tests/test_fixed_ports.py:62 [E.outlives-session] (test-data): `sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)`
- tests/test_fixed_ports.py:65 [E.outlives-session] (test-data): `sock.listen(1)`
- tests/test_fixed_ports.py:336 [E.exec-primitive] (test-data): `child = subprocess.Popen(*a, **k)`
- tests/test_fixed_prototype_port.py:25 [E.outlives-session] (test-data): `with socket.socket() as s:`
- tests/test_fixed_prototype_port.py:82 [E.outlives-session] (test-data): `held = socket.socket()`
- tests/test_fixed_prototype_port.py:85 [E.outlives-session] (test-data): `held.listen(1)`
- tests/test_fixed_prototype_port.py:91 [E.outlives-session] (test-data): `held = socket.socket()`
- tests/test_fixed_prototype_port.py:94 [E.outlives-session] (test-data): `held.listen(1)`
- tests/test_fragment_pairing.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_fragment_pairing.py:28 [E.exec-primitive] (test-data): `out = self.outputs.pop(0) if self.outputs else subprocess.CompletedProcess(argv, 0, "", "")`
- tests/test_fragment_pairing.py:29 [E.exec-primitive] (test-data): `return out if isinstance(out, subprocess.CompletedProcess) else subprocess.CompletedProcess(argv, 0, json.dumps(out), "")`
- tests/test_fragment_pairing.py:77 [E.exec-primitive] (test-data): `child = subprocess.Popen(*a, **k)`
- tests/test_handoff.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_handoff.py:171 [E.exec-primitive] (test-data): `result = subprocess.run(['node','--input-type=module','-e',script,str(api)],`
- tests/test_handoff_store.py:9 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_handoff_store.py:589 [E.exec-primitive] (test-data): `child = subprocess.run([sys.executable,'-c',HANDOFF_CHILD,scripts,tests,str(root),sid,key,phase],`
- tests/test_handoff_store.py:590 [E.exec-primitive] (test-data): `stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30,check=False)`
- tests/test_hermetic_config.py:3 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_hermetic_config.py:27 [E.exec-primitive] (test-data): `out = subprocess.run([sys.executable, str(hermetic_cli.idea_script()), '--store', str(Path(t)/'ideas'), 'list'],`
- tests/test_hermetic_config.py:55 [E.exec-primitive] (test-data): `r = subprocess.run([sys.executable, '-c', code % (bad, mine, str(script.parent),`
- tests/test_hermetic_config.py:74 [E.exec-primitive] (test-data): `out = subprocess.run([sys.executable, str(helper), '--store', str(Path(t)/'ideas'), 'list'],`
- tests/test_idea.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_idea.py:35 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(self.script), '--store', str(self.store), *map(str, args)], capture_output=True, text=True)`
- tests/test_idea.py:359 [E.exec-primitive] (test-data): `result=subprocess.run([sys.executable,str(self.script),'--store',str(self.store),'exploration',idea['idea_id'],'--file',str(path),'--expected-revision','1','--actor','assistant'],capture_output=True,text=True)`
- tests/test_import_cli.py:8 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_import_cli.py:38 [E.exec-primitive] (test-data): `return subprocess.run([sys.executable, str(SCRIPT), '--store', str(store or self.target), *map(str, args)],`
- tests/test_install.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_install.py:45 [E.exec-primitive] (test-data): `subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(path)], check=True)`
- tests/test_install.py:49 [E.exec-primitive] (test-data): `result = subprocess.run([`
- tests/test_install.py:169 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(script), *map(str, args)],`
- tests/test_install.py:361 [E.exec-primitive] (test-data): `subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(venv)], check=True)`
- tests/test_install.py:372 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(INSTALLER), "--source", str(self.source),`
- tests/test_install.py:409 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(INSTALLER), "--source", str(self.source),`
- tests/test_launch.py:9 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_launch.py:38 [E.exec-primitive] (test-data): `child=subprocess.Popen(*args,**kwargs)`
- tests/test_launch.py:136 [E.exec-primitive] (test-data): `kwargs.update(stdout=subprocess.PIPE,stderr=subprocess.PIPE)`
- tests/test_launch.py:147 [E.exec-primitive] (test-data): `result=subprocess.run([sys.executable,str(launch.CHILD),'--store',str(self.store),'--runtime-root',str(self.root),'serve'],`
- tests/test_launcher_cli.py:10 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_launcher_cli.py:223 [E.exec-primitive] (test-data): `result=subprocess.run([sys.executable,str(self.script),'--store',str(self.store),*map(str,args)],`
- tests/test_launcher_cli.py:224 [E.exec-primitive] (test-data): `stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)`
- tests/test_legacy_prior_art.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_legacy_prior_art.py:62 [E.exec-primitive] (test-data): `r = subprocess.run([sys.executable, str(idea_script()), '--store', str(root), *args], capture_output=True, timeout=20)`
- tests/test_link_mode.py:10 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_link_mode.py:32 [E.exec-primitive] (test-data): `return subprocess.CompletedProcess(argv, 0, "", "")`
- tests/test_link_mode.py:46 [E.exec-primitive] (test-data): `child = subprocess.Popen(*a, **k)`
- tests/test_link_mode_cli.py:8 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_link_mode_cli.py:112 [E.exec-primitive] (test-data): `"""Real subprocess CLI against a real owner service; open_browser_session is NOT mocked."""`
- tests/test_link_mode_cli.py:135 [E.exec-primitive] (test-data): `result=subprocess.run([sys.executable,str(self.script),'--store',str(self.store),*map(str,args)],`
- tests/test_link_mode_cli.py:136 [E.exec-primitive] (test-data): `stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)`
- tests/test_markdown.py:7 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_markdown.py:370 [E.exec-primitive] (test-data): `process = subprocess.run([sys.executable, str(script), '--store', str(store), *map(str, arguments)], capture_output=True)`
- tests/test_markdown_store.py:7 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_markdown_store.py:56 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(idea_script()), '--store', str(self.root), *map(str,arguments)], capture_output=True, timeout=8)`
- tests/test_migration.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_migration.py:276 [E.exec-primitive] (test-data): `child=subprocess.Popen([sys.executable,'-c',CHILD,str(SCRIPTS),str(root),phase,str(signal)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)`
- tests/test_move_cli.py:7 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_move_cli.py:52 [E.exec-primitive] (test-data): `return subprocess.run([sys.executable, str(self.script), '--store', str(self.store), *map(str, args)], capture_output=True, text=True)`
- tests/test_move_cli.py:442 [E.exec-primitive] (test-data): `absent = json.loads(subprocess.run([sys.executable, '-c', script], capture_output=True, text=True, check=True).stdout)`
- tests/test_move_cli.py:445 [E.exec-primitive] (test-data): `present = json.loads(subprocess.run([sys.executable, '-c', script], capture_output=True, text=True, check=True).stdout)`
- tests/test_native.py:4 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_native.py:39 [E.exec-primitive] (test-data): `if isinstance(output, subprocess.CompletedProcess):`
- tests/test_native.py:41 [E.exec-primitive] (test-data): `return subprocess.CompletedProcess(argv, 0, json.dumps(output), "PRIVATE STDERR")`
- tests/test_native.py:67 [E.exec-primitive] (test-data): `self.assertEqual(options["stdin"], subprocess.DEVNULL)`
- tests/test_native.py:71 [E.exec-primitive] (test-data): `(subprocess.TimeoutExpired("orca", 3, output="PRIVATE"), "cli_timeout"),`
- tests/test_native.py:108 [E.exec-primitive] (test-data): `self.refused("unsupported_payload", FakeRunner(subprocess.CompletedProcess([], 0, "not JSON", "PRIVATE")))`
- tests/test_native.py:111 [E.exec-primitive] (test-data): `self.refused("unsupported_payload", FakeRunner(subprocess.CompletedProcess([], 0, output, "PRIVATE")))`
- tests/test_native.py:114 [E.exec-primitive] (test-data): `runner = FakeRunner(listing(), subprocess.TimeoutExpired("orca", 3))`
- tests/test_native.py:123 [E.exec-primitive] (test-data): `self.refused("cli_failed", FakeRunner(subprocess.CompletedProcess([], 1, json.dumps(listing()), "PRIVATE")))`
- tests/test_native.py:143 [E.exec-primitive] (test-data): `runner = FakeRunner(subprocess.CompletedProcess([], 0, "", ""))`
- tests/test_native.py:148 [E.exec-primitive] (test-data): `self.refused("system_browser_unavailable", FakeRunner(subprocess.CompletedProcess([], 1, "", "PRIVATE")), mode="system")`
- tests/test_native.py:156 [E.exec-primitive] (test-data): `result = subprocess.run([argv[0], "-c", script, argv[3]], **kwargs)`
- tests/test_native.py:165 [E.exec-primitive] (test-data): `return subprocess.run([argv[0], "-c", script, argv[3]], **kwargs)`
- tests/test_orca_pages_prune.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_orca_pages_prune.py:30 [E.exec-primitive] (test-data): `child = subprocess.Popen(*a, **k)`
- tests/test_platform.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_platform.py:168 [E.exec-primitive] (test-data): `child = subprocess.Popen([sys.executable, '-c', code, str(SCRIPTS), str(lock)],`
- tests/test_platform.py:169 [E.exec-primitive] (test-data): `stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)`
- tests/test_proposal_store.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_proposal_store.py:228 [E.exec-primitive] (test-data): `completed = subprocess.run([sys.executable,'-c',CHILD,str(SCRIPTS),str(Path(__file__).parent),`
- tests/test_rebuilt_tab_repair.py:12 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_rebuilt_tab_repair.py:145 [E.exec-primitive] (test-data): `child = subprocess.Popen(*a, **k)`
- tests/test_rebuilt_tab_repair.py:205 [E.exec-primitive] (test-data): `completed = subprocess.run([sys.executable, str(idea_script()), '--store', '/nonexistent/ideas', *argv],`
- tests/test_rebuilt_tab_repair.py:226 [E.exec-primitive] (test-data): `completed = subprocess.run(['node', '--input-type=module', '-e', script, json.dumps([search, code, from_link])],`
- tests/test_remove_cli.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_remove_cli.py:32 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(SCRIPT), '--store', str(self.store), *map(str, args)], capture_output=True, text=True)`
- tests/test_remove_cli.py:61 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(SCRIPT), '--store', str(self.store), 'remove-idea', '--idea', self.key], capture_output=True, text=True)`
- tests/test_remove_cli.py:75 [E.exec-primitive] (test-data): `return subprocess.run([sys.executable, str(SCRIPT), '--store', str(self.store), *map(str, args)], capture_output=True, text=True)`
- tests/test_remove_idea.py:66 [E.exec-primitive] (test-data): `import json, subprocess`
- tests/test_remove_idea.py:67 [E.exec-primitive] (test-data): `run = subprocess.run([sys.executable, str(idea_script()), '--store', str(self.target), 'doctor'], capture_output=True, text=True)`
- tests/test_remove_idea.py:475 [E.exec-primitive] (test-data): `import json, subprocess, sys`
- tests/test_remove_idea.py:476 [E.exec-primitive] (test-data): `run = subprocess.run([sys.executable, str(idea_script()), '--store', str(self.source), 'doctor'], capture_output=True, text=True)`
- tests/test_remove_idea_in_use.py:7 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_remove_idea_in_use.py:59 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(SCRIPT), '--store', str(self.store), 'remove-idea', '--idea', self.key,`
- tests/test_remove_idea_in_use.py:128 [E.exec-primitive] (test-data): `child = subprocess.Popen(*a, **k); children.append(child); return child`
- tests/test_restore_parks_orphaned_session.py:6 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_restore_parks_orphaned_session.py:93 [E.exec-primitive] (test-data): `child = subprocess.Popen(*a, **k); children.append(child); return child`
- tests/test_resume_closes_old_tab.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_resume_closes_old_tab.py:52 [E.exec-primitive] (test-data): `child = subprocess.Popen(*a, **k)`
- tests/test_runtime.py:3 [E.outlives-session] (test-data): `from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer`
- tests/test_runtime.py:9 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_runtime.py:136 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, '-c', source, str(self.store), str(self.root)],`
- tests/test_runtime.py:560 [E.exec-primitive] (test-data): `child = subprocess.Popen([sys.executable, '-c', script, str(self.store), str(root), mode],`
- tests/test_runtime.py:562 [E.exec-primitive] (test-data): `stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)`
- tests/test_runtime_identity.py:19 [E.outlives-session] (test-data): `self.sock = socket.socket(); self.sock.bind(('127.0.0.1', 0)); self.sock.listen(4)`
- tests/test_runtime_identity.py:85 [E.outlives-session] (test-data): `from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer`
- tests/test_session_security.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_session_security.py:248 [E.exec-primitive] (test-data): `result=subprocess.run(['node','--input-type=module','-e',script,str(api)],input=json.dumps(dict(pair=pair,session=session,code=code)),text=True,capture_output=True,timeout=5)`
- tests/test_session_verbs.py:1 [E.exec-primitive] (test-data): `` """Real-subprocess `sessions` and `session-discard` verbs, and the session list on a capacity refusal.""" ``
- tests/test_session_verbs.py:5 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_session_verbs.py:36 [E.exec-primitive] (test-data): `result=subprocess.run(argv,capture_output=True,timeout=15)`
- tests/test_ssh_mode.py:647 [E.exec-primitive] (test-data): `import shutil, subprocess`
- tests/test_ssh_mode.py:656 [E.exec-primitive] (test-data): `done = subprocess.run(command, shell=True, input=url + '\n', capture_output=True, text=True, timeout=10)`
- tests/test_ssh_mode.py:661 [E.exec-primitive] (test-data): `import shutil, subprocess`
- tests/test_ssh_mode.py:668 [E.exec-primitive] (test-data): `done = subprocess.run(command, shell=True, input=payload.encode(), capture_output=True, timeout=10)`
- tests/test_store_requests.py:7 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_store_requests.py:283 [E.exec-primitive] (test-data): `child=subprocess.Popen([sys.executable,'-c',CHILD,str(SCRIPTS),str(Path(__file__).parent),str(root),sid,target],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)`
- tests/test_store_requests.py:291 [E.exec-primitive] (test-data): `restarted=subprocess.run([sys.executable,'-c',code,str(SCRIPTS),str(root),sid],capture_output=True,text=True,timeout=5)`
- tests/test_tern_plugin.py:84 [E.install-global] (test-data): `self.assertIn('tern plugin install github.com/blastworksai/tools/skills/glitch-idea/glitch-idea/tern-plugin', README)`
- tests/test_transactions.py:10 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_transactions.py:123 [E.exec-primitive] (test-data): `child=subprocess.Popen([sys.executable,'-c',CHILD,str(SCRIPTS),str(root),phase,IDEA],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)`
- tests/test_transactions.py:130 [E.exec-primitive] (test-data): `restart=subprocess.run([sys.executable,'-c',CHILD,str(SCRIPTS),str(root),'RECOVER',IDEA],capture_output=True,text=True,timeout=4)`
- tests/test_transactions.py:335 [E.exec-primitive] (test-data): `child=subprocess.Popen([sys.executable,'-c',CHILD,str(SCRIPTS),str(root),phase,IDEA,'migration'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)`
- tests/test_transactions.py:342 [E.exec-primitive] (test-data): `restart=subprocess.run([sys.executable,'-c',CHILD,str(SCRIPTS),str(root),'RECOVER',IDEA],capture_output=True,text=True,timeout=4)`
- tests/test_workflow_schema.py:9 [E.exec-primitive] (test-data): `import subprocess`
- tests/test_workflow_schema.py:294 [E.exec-primitive] (test-data): `result = subprocess.run([sys.executable, str(script), '--store', str(root/'ideas'),`

#### phrase.C.second-order (12 lines)

Patterns: C.error-instruction 12

- docs/browser-runbook.md:69 [C.error-instruction] (human): `` Expected: exit 0, `"action": "installed"`, and `runtime` with `"status": "ready"`, `python_version` and `"pyyaml": "6.0.3"`.\nA third identical run reports `"action": "unchanged"`. ``
- glitch-idea/SKILL.md:53 [C.error-instruction] (model): `` Ready first: before a typed code is ever issued (plain `session-open`, or `session-open --resume <binding_id>` after an expired or failed pairing), ask the operator ONE question, "ready to type a code?", and run the verb only on their yes, then give the origin and the fresh code in the same message that carries it. The code lasts 60 seconds: measured, 12 seconds when the operator is at the box, expired when the code travels through a prompt first. ``
- glitch-idea/SKILL.md:132 [C.error-instruction] (model): `` disconnected or authorization/generation failure; explicit skill reinvocation\nand resume rotate the generation. At most five consecutive empty waits belong\nto one idle run: after the fifth, tell the operator in one line you are pausing, then stop waiting; resume with `events` (from your last cursor) when they say so. Right after launch, start one background shell loop that runs `events` again by itself each time a wait returns (advancing the cursor) and writes each result to a file, so the lease never lapses between turns; it exits, and so wakes you, only when a request is delivered or a stop code (`agent_unavailable`, `owner_unavailable`, `unsupported_idea_version`) comes back. The lease starts at open, so start that loop within the first call after `session-open`, never minutes later: `agent_unavailable` right after `session-open` means the loop started too late. On delivery, restart the loop at once, in the same turn you start composing (in the background, as the first loop ran), so the lease never lapses while the operator moves on; the server keeps a composing agent through a supersede until its next call. A `request_cancelled` on a fill means the operator moved on: read the next request from the loop's file, never resume the session. Never re-run waits yourself turn by turn to keep the lease alive: that wakes the model every 25 seconds. Empty waits never reset the idle clock, so a forgotten session still pauses after 600 seconds. The five-wait pause applies to waits you sit in yourself. Use supported native background-command observation ``
- glitch-idea/SKILL.md:232 [C.error-instruction] (model): `` Installing is the operator's step, documented in the repository README and runbook; this skill never installs anything. If the runtime interpreter lacks PyYAML 6.0.3, the installer fails with `runtime_prerequisite` and prints the exact `"<python>" -m pip install -r "<requirements.txt>"` command for the operator to run, then they rerun the installer. If the interpreter is older than Python 3.10, the installer fails with `install_error` and no pip command: the operator needs a newer Python (a new venv from it), not a package. Never run that command, fetch a package or create a venv yourself. Direct installs go through `install.py` with `python3` on macOS and Linux and `py -3` on Windows. ``
- glitch-idea/references/commands.md:23 [C.error-instruction] (model): `` `browser-open` opens a dedicated tab at `<origin>/#pair=<code>` (the code is exactly 32 lowercase hex characters). The page reads the fragment, removes it from the address bar before anything else and redeems the code itself, so the operator types nothing. The returned `browser.url` stays the root-only origin. The result also carries `pairing_code` and `fallback_line`: "Only if the tab did not open paired: type <code> within 60 s." Show that line only when the operator reports the tab did not open paired; typing a code the tab already redeemed invalidates the session (`pairing_replay_session_invalidated`). Ready first: before a typed code is ever issued (plain `session-open`, or `session-open --resume binding_ID` after an expired or failed pairing), ask the operator ONE question, "ready to type a code?", and run the verb only on their yes, giving the origin and fresh code in the same message that carries it (60 seconds: measured 12 seconds at the box, expired when the code travels through a prompt first). The page's own sentence is: "This link's pairing code has expired. Ask your terminal for a new code (it runs session-open --resume)." Plain `session-open` launches no browser, so the operator opens the origin and types the code. Only the initiating helper prints this one-time code. Keep `binding_id` from the result or browser URL: `--resume` rotates credentials while retaining that binding's durable save receipts and selected idea. A browser-open error that includes `resume_required` also carries the binding reference; resume it explicitly instead of creating another session. A lost or uncertain NEW result is never retried automatically. With `--browser orca`, a resume creates the new tab first and then closes the page recorded for that binding (`orca tab close --page <id> --worktree id:<worktree>`); the result's `browser.previous_page_closed` says whether it did, with `previous_page_close_error` on a failure, which never fails the reconnect. System-browser mode cannot close a tab. An old tab still open elsewhere is told it was replaced by a newer one (error code `session_superseded`). ``
- glitch-idea/references/commands.md:143 [C.error-instruction] (model): `` Two verbs manage the retained sessions and need a running service; both take `--runtime-root` and `--runtime-python` like `session-open`. Without a running service they fail with `owner_unavailable`.\n`sessions` is read-only and prints `{ok: true, sessions: [...]}`: one row per retained session with `binding_id`, `selected_idea_id`, `title` (the idea's text, at most 80 characters), `finished` (its Review step is saved) and `in_use` (a browser tab or terminal agent is still connected).\n`session-discard --binding binding_ID [--confirm]` removes one session; its ideas and receipts are untouched. An idle session is discarded at once and prints `{ok: true, binding_id, was_in_use}`.\nFor a session that is still open, a run without `--confirm` changes nothing, exits nonzero with `session_in_use` and a fixed `warning` field: "This session is still open: its browser tab and terminal agent will stop working. Run again with --confirm to discard it." ``
- glitch-idea/scripts/idea_bridge.py:396 [C.error-instruction] (tool): `raise RuntimeError('Drain must run outside request handlers')`
- glitch-idea/scripts/idea_ssh.py:298 [C.error-instruction] (tool): `given, must raise SshError unless that client's tunnel proves this service: it is run on the one candidate, and`
- tests/browser_flow_smoke.mjs:32 [C.error-instruction] (test-data): `if (local?.default_workspace) { console.error('smoke refused: ' + cfg + ' sets default_workspace; run from a tree without a local config'); process.exit(2); }`
- tests/browser_flow_smoke.mjs:1215 [C.error-instruction] (test-data): `if (open.pointer) throw new Error('the install pointer is still shown beside a ready prototype');`
- tests/test_fixed_ports.py:133 [C.error-instruction] (test-data): `self.fail('spawn must not run when the port is held')`
- tests/test_fixed_ports.py:156 [C.error-instruction] (test-data): `self.fail('spawn must not run when the port is held')`

#### phrase.D.trust (0 lines)

None.

#### phrase.E.env (13 lines)

Patterns: E.install 7, E.memory 6

- README.md:73 [E.install] (human): `` If the runtime lacks PyYAML it stops with error code `runtime_prerequisite` and prints the exact `pip install` command for you to run yourself, then you rerun the installer. ``
- README.md:105 [E.install] (human): `` 4. **Run the printed command yourself**, for example `"/absolute/path/to/venv/bin/python" -m pip install -r "/absolute/path/to/glitch-idea/requirements.txt"`. ``
- docs/browser-runbook.md:61 [E.install] (human): `"/absolute/path/to/venv/bin/python" -m pip install -r "/absolute/path/to/checkout/glitch-idea/requirements.txt"`
- glitch-idea/SKILL.md:232 [E.install] (model): `` Installing is the operator's step, documented in the repository README and runbook; this skill never installs anything. If the runtime interpreter lacks PyYAML 6.0.3, the installer fails with `runtime_prerequisite` and prints the exact `"<python>" -m pip install -r "<requirements.txt>"` command for the operator to run, then they rerun the installer. If the interpreter is older than Python 3.10, the installer fails with `install_error` and no pip command: the operator needs a newer Python (a new venv from it), not a package. Never run that command, fetch a package or create a venv yourself. Direct installs go through `install.py` with `python3` on macOS and Linux and `py -3` on Windows. ``
- glitch-idea/references/commands.md:3 [E.install] (model): `` Python 3.10+ and PyYAML 6.0.3 (MIT) are required. Linux is exercised; native Windows and macOS are not yet qualified. The installer (`install.py`) can create a per-skill venv offline and checks the pinned PyYAML, but it never downloads: when the dependency is missing it fails with `runtime_prerequisite` and prints the exact `pip install` command for the operator to run. Use the helper inside the loaded skill. From this repository's root: ``
- glitch-idea/scripts/idea_proposal_evidence.py:121 [E.memory] (tool): `# Discovery/Exploration/Memory/Method. No old record is adapted or rewritten on read.`
- glitch-idea/scripts/idea_steps/method.py:4 [E.memory] (tool): `checks memory/proposal provenance before this pure handler. The human may choose`
- install.py:150 [E.install] (human): `remedy = f'"{python}" -m pip install -r "{requirements}"'`
- tests/test_agent_memory.py:19 [E.memory] (test-data): `FOUND=dict(status='found',sources=['memory:preference-42','Memory/USER.md#planning'],`
- tests/test_agent_memory.py:61 [E.memory] (test-data): `for reference in ('/home/other/memory.md','../Memory.md','Memory/../USER.md',`
- tests/test_agent_memory.py:62 [E.memory] (test-data): `'C:/Users/user/memory.md','memory:/absolute','memory://private','https://host/private',`
- tests/test_agent_memory.py:63 [E.memory] (test-data): `'memory:memory-private/preference','Memory/private\\notes.md','Authorization:Bearer-secret',`
- tests/test_install.py:251 [E.install] (test-data): `self.assertIn(f'"{python}" -m pip install -r "{self.source / "requirements.txt"}"', error["message"])`

#### phrase.J.prohibited (251 lines)

Patterns: J.confirm-first 251

- LICENSE:8 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`
- docs/asset-format.md:7 [J.confirm-first] (human): `` Streams use generated `assets/staging/<upload_id>.<nonce>.part`; complete bytes publish immutably at `assets/blobs/<asset_id>.bin`, all on the Store filesystem. Upload display names never select a path. Every path component, root and ancestor must be a real directory/regular file, never a symlink, special file or foreign-device path. The browser selects opaque IDs only. ``
- docs/asset-format.md:11 [J.confirm-first] (human): `An upload intent and its request receipt publish together. Network streaming never holds a Store lock. Flush and publish the immutable blob first; then rehash and register complete evidence/detail links and receipt atomically through Store's recoverable transaction. A crash before registration leaves an orphan, never a completed upload. Completed stages are sealed read-only and owner-only (0400, with stages created 0600 and asset directories 0700) before exclusive hardlink blob publication. A retained stage whose generated upload ID and verified read-only inode match the completed blob is a retained success, excluded from orphan diagnostics. Failed, interrupted or unmatched stages and unlinked blobs remain reported orphans; no automatic deletion. Replays return the original receipt before business/CAS checks. Same identity with different bytes refuses. Linked missing/corrupt evidence or blobs fail closed.`
- docs/markdown-format.md:78 [J.confirm-first] (human): `to publish and owns monotonic transaction advancement.`
- docs/markdown-format.md:325 [J.confirm-first] (human): `Each idea is migrated alone, in one publish.`
- docs/markdown-format.md:330 [J.confirm-first] (human): `` An idea the chain cannot update (a step refuses it, a publish conflicts, it is moved, delivered or archived) is held: its files are left exactly as they were, the rest of the store works, `show` of it refuses `unsupported_idea_version` with a plain sentence naming it by its first words, and `doctor` lists it. ``
- glitch-idea/PyYAML-MIT-NOTICE.txt:13 [J.confirm-first] (model): `use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies`
- glitch-idea/references/commands.md:324 [J.confirm-first] (model): `` An immutable tombstone `history/removed/<id>.md` (`<id>.2.md`, `<id>.3.md` … when the same idea was imported again and removed again) is written in the same publish, sealed read-only (0400, or 0440 in a shared store): idea id, actor, time, first words and a manifest of the removed paths with their sha256. ``
- glitch-idea/scripts/idea_chain.py:9 [J.confirm-first] (tool): `new history revision is published with it. A step that raises, or a publish that`
- glitch-idea/scripts/idea_chain.py:166 [J.confirm-first] (tool): `transactions.publish(root, changes, expected).raise_for_error()`
- glitch-idea/scripts/idea_handoff.py:110 [J.confirm-first] (tool): `def publish(self,context,payload):`
- glitch-idea/scripts/idea_handoff.py:183 [J.confirm-first] (tool): `result = _provider(app).publish(app.context,payload)`
- glitch-idea/scripts/idea_markdown.py:1073 [J.confirm-first] (tool) (stated as a prohibition (must not; exception: until import/invalidation succeeds)): `Callers must not publish a candidate until import/invalidation succeeds.`
- glitch-idea/scripts/idea_proposals.py:16 [J.confirm-first] (tool) (stated as a prohibition (never)): `correlation and must reconcile uncertainty, never publish a second artifact.`
- glitch-idea/scripts/idea_store.py:1519 [J.confirm-first] (tool): `# Fresh physical inventory plus new immutable evidence, before publish.`
- glitch-idea/scripts/idea_store.py:1540 [J.confirm-first] (tool): `self._load_cache = None  # any publish attempt invalidates the remembered load`
- glitch-idea/scripts/idea_store.py:1553 [J.confirm-first] (tool): `result = transactions.publish(self.path, combined, expected, freeze_legacy=True,`
- glitch-idea/scripts/idea_store.py:1562 [J.confirm-first] (tool): `result = transactions.publish(self.path, combined, expected, move_out=move_out, removals=removals)`
- glitch-idea/scripts/idea_store.py:1642 [J.confirm-first] (tool): `require(not context.get('request_running'), 'Request mutators cannot publish or perform I/O', 'invalid_transaction')`
- glitch-idea/scripts/idea_store.py:1719 [J.confirm-first] (tool): `publish: the files, the idea appended last in order, and one placement`
- glitch-idea/scripts/idea_store.py:1853 [J.confirm-first] (tool): `# Once the journaled publish may have committed, the evidence names these blobs: they stay.`
- glitch-idea/scripts/idea_store.py:1996 [J.confirm-first] (tool): `"""Remove one idea and everything it owns, for good, in one journaled publish.`
- glitch-idea/scripts/idea_store.py:2181 [J.confirm-first] (tool): `require(not context.get('request_running'), 'Request mutators cannot publish or perform I/O', 'invalid_transaction')`
- glitch-idea/scripts/idea_store.py:2217 [J.confirm-first] (tool): `require(not context.get('request_running'), 'Request mutators cannot publish or perform I/O', 'invalid_transaction')`
- glitch-idea/scripts/idea_store.py:2278 [J.confirm-first] (tool): `Neither callback may wait/read network, read files or publish. The business`
- glitch-idea/scripts/idea_store.py:2615 [J.confirm-first] (tool): `"""Publish suggestion/link/receipt under an existing binding->Store guard.`
- glitch-idea/scripts/idea_store.py:2618 [J.confirm-first] (tool): `trusted pure code, returning the exact checked source on first publish;`
- glitch-idea/scripts/idea_transactions.py:4 [J.confirm-first] (tool): `read/validate/CAS and publish. No agent waits under that lock. Product readers`
- glitch-idea/scripts/idea_transactions.py:149 [J.confirm-first] (tool): `A crash can leave a folder at a looser mode; the next publish repairs it. A folder owned by someone else, a symlink or a missing path is left alone.`
- glitch-idea/scripts/idea_transactions.py:427 [J.confirm-first] (tool): `def publish(root, changes, expected, *, freeze_legacy=False, legacy_sha256=None, move_out=None, removals=None, _checkpoint=None):`
- glitch-idea/scripts/idea_transactions.py:428 [J.confirm-first] (tool): `"""Stage and publish complete after-images under caller-held store lock.`
- glitch-idea/tern-plugin/LICENSE:8 [J.confirm-first] (human): `to use, copy, modify, merge, publish, distribute, sublicense, and/or sell`
- glitch-idea/web/app.js:816 [J.confirm-first] (tool): `const submit = element('button', 'Connect', 'primary bw-btn bw-btn--primary');`
- glitch-idea/web/app.js:817 [J.confirm-first] (tool): `submit.type = 'submit';`
- glitch-idea/web/app.js:819 [J.confirm-first] (tool): `form.append(wrap, submit);`
- glitch-idea/web/app.js:820 [J.confirm-first] (tool): `form.addEventListener('submit', async event => {`
- glitch-idea/web/app.js:822 [J.confirm-first] (tool): `submit.disabled = true;`
- glitch-idea/web/assets/fonts/BlastworksSans-UNLICENSE.txt:3 [J.confirm-first] (model): `Anyone is free to copy, modify, publish, use, compile, sell, or`
- tests/browser_flow_smoke.mjs:360 [J.confirm-first] (test-data): `if (!port) throw new Error('chrome did not publish a debugging port');`
- tests/test_agent_bridge.py:560 [J.confirm-first] (test-data) (stated as a prohibition (must not)): `self.fail('Stale unpublished response must not publish')`
- tests/test_agent_bridge.py:626 [J.confirm-first] (test-data): `# proposed neighbors against the recorded target/backlog before publish.`
- tests/test_agent_memory.py:106 [J.confirm-first] (test-data): `def publish(self,value=FOUND,operation='memory',request='memory-1'):`
- tests/test_agent_memory.py:131 [J.confirm-first] (test-data): `self.publish();self.publish(EMPTY,request='empty-search')`
- tests/test_agent_memory.py:148 [J.confirm-first] (test-data): `self.publish()`
- tests/test_agent_memory.py:158 [J.confirm-first] (test-data): `self.publish()`
- tests/test_agent_memory.py:167 [J.confirm-first] (test-data): `link=self.publish()`
- tests/test_agent_memory.py:177 [J.confirm-first] (test-data): `link=self.publish(operation='method',request='method-found')`
- tests/test_agent_memory.py:185 [J.confirm-first] (test-data): `self.publish(operation='method',request='method-found')`
- tests/test_agent_memory.py:198 [J.confirm-first] (test-data): `self.publish()`
- tests/test_agent_memory.py:204 [J.confirm-first] (test-data): `self.publish()`
- tests/test_asset_links.py:239 [J.confirm-first] (test-data): `tx.publish(root, {path: raw}, {path: None}).raise_for_error()`
- tests/test_asset_links.py:241 [J.confirm-first] (test-data): `tx.publish(root, {path: raw}, {path: digest(raw)}).raise_for_error()`
- tests/test_asset_links.py:243 [J.confirm-first] (test-data): `tx.publish(root, {path: raw+b'changed'}, {path: digest(raw)})`
- tests/test_asset_links.py:246 [J.confirm-first] (test-data): `tx.publish(root, {bad: b'bytes'}, {bad: None})`
- tests/test_asset_links.py:258 [J.confirm-first] (test-data): `tx.publish(root,{path:raw},{path:None})`
- tests/test_asset_links.py:275 [J.confirm-first] (test-data): `tx.publish(root,{path:raw},{path:None},_checkpoint=checkpoint)`
- tests/test_asset_links.py:292 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError) as caught: tx.publish(root,{path:raw},{path:None})`
- tests/test_asset_links.py:308 [J.confirm-first] (test-data): `tx.publish(root, files, {path: None for path in files}, _checkpoint=checkpoint)`
- tests/test_asset_links.py:320 [J.confirm-first] (test-data): `tx.publish(root, {path: b'x'*(md.MAX_INPUT+1)}, {path: None})`
- tests/test_asset_links.py:329 [J.confirm-first] (test-data): `tx.publish(root, {path: raw}, {path: None})`
- tests/test_asset_links.py:338 [J.confirm-first] (test-data): `tx.publish(root, {path: raw}, {path: None})`
- tests/test_asset_store.py:75 [J.confirm-first] (test-data): `original=storage.transactions.publish`
- tests/test_asset_store.py:76 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_asset_store.py:83 [J.confirm-first] (test-data): `storage.transactions.publish=publish`
- tests/test_asset_store.py:447 [J.confirm-first] (test-data): `original = tx.publish`
- tests/test_asset_store.py:448 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_asset_store.py:452 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',side_effect=publish):`
- tests/test_assets.py:215 [J.confirm-first] (test-data): `intent = self.start(); original = tx.publish`
- tests/test_assets.py:216 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_assets.py:220 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',side_effect=publish):`
- tests/test_assets.py:294 [J.confirm-first] (test-data): `publish = assets._publish_blob; admitted = []`
- tests/test_assets.py:300 [J.confirm-first] (test-data): `return publish(store,stage,record)`
- tests/test_assets.py:739 [J.confirm-first] (test-data): `upload = self.complete_upload(); payload = self.set_payload([upload['asset_id']]); original = tx.publish`
- tests/test_assets.py:740 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_assets.py:744 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',side_effect=publish):`
- tests/test_bridge.py:445 [J.confirm-first] (test-data): `future = pool.submit(self.request, '/api/v1/state')`
- tests/test_bridge.py:450 [J.confirm-first] (test-data): `future = pool.submit(self.request, '/api/v1/state')`
- tests/test_chain.py:190 [J.confirm-first] (test-data): `tx.publish(self.root, {good: b'first'}, {good: None}).raise_for_error()`
- tests/test_chain.py:192 [J.confirm-first] (test-data): `tx.publish(self.root, {good: b'second'}, {good: digest(b'first')})`
- tests/test_external_edits.py:215 [J.confirm-first] (test-data): `original=tx.publish`
- tests/test_external_edits.py:216 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_external_edits.py:220 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',publish):`
- tests/test_handoff.py:38 [J.confirm-first] (test-data): `def publish(self,request='handoff-1',payload=None):`
- tests/test_handoff.py:52 [J.confirm-first] (test-data): `result = self.publish(); compact = self.store.request_result(self.sid,'handoff-1')`
- tests/test_handoff.py:67 [J.confirm-first] (test-data): `result = self.publish(); before = self.files()`
- tests/test_handoff.py:77 [J.confirm-first] (test-data): `payload = self.payload(); original = self.publish(payload=payload)`
- tests/test_handoff.py:85 [J.confirm-first] (test-data): `replay = self.publish(payload=payload)`
- tests/test_handoff.py:89 [J.confirm-first] (test-data): `self.refused('workspace_unavailable',lambda:self.publish('fresh'))`
- tests/test_handoff.py:92 [J.confirm-first] (test-data): `payload = self.payload(); first = self.publish(payload=payload); before = self.files()`
- tests/test_handoff.py:110 [J.confirm-first] (test-data): `self.assertEqual(self.publish(payload=payload),historical)`
- tests/test_handoff.py:112 [J.confirm-first] (test-data): `fresh = self.publish('moved-new')`
- tests/test_handoff.py:126 [J.confirm-first] (test-data): `first = self.publish(); spelling = self.root.parent/'Spelling'; spelling.mkdir()`
- tests/test_handoff.py:132 [J.confirm-first] (test-data): `reused = self.publish('canonical-reuse')`
- tests/test_handoff.py:139 [J.confirm-first] (test-data): `if published: self.publish()`
- tests/test_handoff.py:209 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError) as caught: self.publish(payload=payload)`
- tests/test_handoff.py:221 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError) as caught: self.publish('refused-before-commit')`
- tests/test_handoff.py:228 [J.confirm-first] (test-data): `result = self.publish(); self.edit_exploration(); before = self.files()`
- tests/test_handoff.py:250 [J.confirm-first] (test-data): `result = self.publish(); compact = self.store.request_result(self.sid,'handoff-1')`
- tests/test_handoff.py:259 [J.confirm-first] (test-data): `self.publish()`
- tests/test_handoff.py:265 [J.confirm-first] (test-data): `first = self.publish(); second = self.publish('handoff-2')`
- tests/test_handoff.py:272 [J.confirm-first] (test-data): `original = self.publish()`
- tests/test_handoff.py:291 [J.confirm-first] (test-data): `self.refused('archived_revision',lambda:self.publish('after-archive'))`
- tests/test_handoff.py:297 [J.confirm-first] (test-data): `self.refused('invalid_input',lambda:self.publish(payload=dict(payload,**{extra:'browser-value'})))`
- tests/test_handoff.py:298 [J.confirm-first] (test-data): `self.refused('invalid_input',lambda:self.publish(payload=dict(payload,expected_revision=True)))`
- tests/test_handoff.py:312 [J.confirm-first] (test-data): `self.publish()`
- tests/test_handoff.py:318 [J.confirm-first] (test-data): `result = self.publish(); before = self.files()`
- tests/test_handoff_links.py:199 [J.confirm-first] (test-data): `tx.publish(root,{path:raw},{path:None}).raise_for_error()`
- tests/test_handoff_links.py:202 [J.confirm-first] (test-data): `tx.publish(root,{path:raw},{path:None})`
- tests/test_handoff_links.py:205 [J.confirm-first] (test-data): `tx.publish(root,{path:raw+b'foreign'},{path:digest(raw)})`
- tests/test_handoff_links.py:209 [J.confirm-first] (test-data): `tx.publish(root,{'../foreign.md':raw},{'../foreign.md':None})`
- tests/test_handoff_store.py:3 [J.confirm-first] (test-data): `Fixtures publish through the existing trusted journal writer under Store lock;`
- tests/test_handoff_store.py:65 [J.confirm-first] (test-data): `tx.publish(store.path,changes,expected).raise_for_error()`
- tests/test_handoff_store.py:291 [J.confirm-first] (test-data): `def publication_payload(store,key,request='handoff-publish-1'):`
- tests/test_handoff_store.py:305 [J.confirm-first] (test-data): `original=storage.transactions.publish`
- tests/test_handoff_store.py:306 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_handoff_store.py:312 [J.confirm-first] (test-data): `storage.transactions.publish=publish`
- tests/test_handoff_store.py:322 [J.confirm-first] (test-data): `self.root = Path(self.temp.name)/'Publish café'`
- tests/test_handoff_store.py:334 [J.confirm-first] (test-data): `def publish(self,request='handoff-publish-1',payload=None,factory=codec.build_record):`
- tests/test_handoff_store.py:343 [J.confirm-first] (test-data): `before = self.files(); original = self.show(); result = self.publish(); after = self.files()`
- tests/test_handoff_store.py:358 [J.confirm-first] (test-data): `payload = publication_payload(self.store,self.key); result = self.publish(payload=payload)`
- tests/test_handoff_store.py:368 [J.confirm-first] (test-data): `self.assertEqual(self.publish(payload=payload,factory=lambda *a,**k:self.fail('Replay factory')),result)`
- tests/test_handoff_store.py:370 [J.confirm-first] (test-data): `self.refused(lambda:self.publish(request='new-after-drift'),'not_ready')`
- tests/test_handoff_store.py:372 [J.confirm-first] (test-data): `self.refused(lambda:self.publish(payload=changed),'request_conflict')`
- tests/test_handoff_store.py:375 [J.confirm-first] (test-data): `first = self.publish(); before = self.files(); original = self.show()`
- tests/test_handoff_store.py:379 [J.confirm-first] (test-data): `second = self.publish('handoff-publish-2',factory=lambda *a,**k:self.fail('Reuse factory'))`
- tests/test_handoff_store.py:395 [J.confirm-first] (test-data): `self.refused(lambda:self.publish(payload=changed),code); self.assertEqual(self.files(),before)`
- tests/test_handoff_store.py:397 [J.confirm-first] (test-data): `self.refused(self.publish,'workspace_unavailable'); self.assertEqual(self.files(),before)`
- tests/test_handoff_store.py:403 [J.confirm-first] (test-data): `self.refused(lambda:self.publish(factory=mutate),'invalid_handler'); self.assertEqual(self.files(),before)`
- tests/test_handoff_store.py:406 [J.confirm-first] (test-data): `self.refused(lambda:self.publish(factory=wrong),'invalid_handler'); self.assertEqual(self.files(),before)`
- tests/test_handoff_store.py:409 [J.confirm-first] (test-data): `self.refused(lambda:self.publish(factory=nested),'store_busy'); self.assertEqual(self.files(),before)`
- tests/test_handoff_store.py:433 [J.confirm-first] (test-data): `self.refused(self.publish,'handoff_capacity')`
- tests/test_handoff_store.py:443 [J.confirm-first] (test-data): `self.refused(self.publish,'save_conflict')`
- tests/test_handoff_store.py:465 [J.confirm-first] (test-data): `self.refused(lambda:self.publish(payload=payload,factory=factory),code)`
- tests/test_handoff_store.py:499 [J.confirm-first] (test-data): `result = self.publish(); packet_raw = (self.root/result['path']).read_bytes(); packet = codec.decode_record(packet_raw)`
- tests/test_handoff_store.py:522 [J.confirm-first] (test-data): `original = self.show(); first = self.publish(payload=payload); before = self.files()`
- tests/test_handoff_store.py:528 [J.confirm-first] (test-data): `self.assertEqual(self.publish(payload=payload,factory=lambda *a,**k:self.fail('Historical replay built')),first)`
- tests/test_handoff_store.py:537 [J.confirm-first] (test-data): `second = self.publish('moved-new-packet')`
- tests/test_handoff_store.py:560 [J.confirm-first] (test-data): `first = self.publish(); before = self.files()`
- tests/test_handoff_store.py:570 [J.confirm-first] (test-data): `reused = self.publish('respelled-reuse')`
- tests/test_handoff_store.py:576 [J.confirm-first] (test-data): `self.publish(); before = self.files()`
- tests/test_handoff_store.py:596 [J.confirm-first] (test-data): `recovered = store.request_result(sid,'handoff-publish-1'); stable = self.files(root)`
- tests/test_handoff_store.py:598 [J.confirm-first] (test-data): `self.assertEqual(store.publish_handoff(sid,'handoff-publish-1',payload,`
- tests/test_import_idea.py:383 [J.confirm-first] (test-data): `with mock.patch.object(storage.transactions, 'publish', side_effect=IdeaError('io_error', 'boom')):`
- tests/test_import_idea.py:398 [J.confirm-first] (test-data): `real = storage.transactions.publish`
- tests/test_import_idea.py:402 [J.confirm-first] (test-data): `with mock.patch.object(storage.transactions, 'publish', side_effect=interrupted):`
- tests/test_import_idea.py:409 [J.confirm-first] (test-data): `with mock.patch.object(storage.transactions, 'publish', side_effect=IdeaError('save_conflict', 'moved on')):`
- tests/test_markdown_store.py:138 [J.confirm-first] (test-data): `with self.assertRaises(Stop): tx.publish(self.root,{KEY+'.md':after},{KEY+'.md':digest(old)},_checkpoint=stop)`
- tests/test_markdown_store.py:303 [J.confirm-first] (test-data): `original = tx.publish`
- tests/test_markdown_store.py:304 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_markdown_store.py:308 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',side_effect=publish):`
- tests/test_migration.py:71 [J.confirm-first] (test-data): `original=storage.transactions.publish`
- tests/test_migration.py:73 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_migration.py:78 [J.confirm-first] (test-data): `storage.transactions.publish=publish`
- tests/test_migration.py:188 [J.confirm-first] (test-data): `original=tx.publish`
- tests/test_migration.py:189 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_migration.py:193 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',side_effect=publish):`
- tests/test_move_store.py:360 [J.confirm-first] (test-data): `def publish(self, changes, expected_extra=None, **kwargs):`
- tests/test_move_store.py:364 [J.confirm-first] (test-data): `return tx.publish(self.root, changes, expected, **kwargs)`
- tests/test_move_store.py:367 [J.confirm-first] (test-data): `self.refusal('invalid_input', lambda: self.publish({'plan-evidence/'+PLAN+'.md': b'x'}, move_out=DETAIL))`
- tests/test_move_store.py:369 [J.confirm-first] (test-data): `self.refusal('invalid_input', lambda: self.publish({POINTER: wrong}, move_out=DETAIL))`
- tests/test_move_store.py:371 [J.confirm-first] (test-data): `self.refusal('invalid_input', lambda: self.publish({POINTER: other}, move_out=DETAIL))`
- tests/test_move_store.py:378 [J.confirm-first] (test-data): `self.refusal('invalid_input', lambda: self.publish({POINTER: self.pointer_for(self.original)}, move_out=path))`
- tests/test_move_store.py:382 [J.confirm-first] (test-data): `self.publish({POINTER: self.pointer_for(self.original), 'IDEAS.md': index+b'\n'}, move_out=DETAIL,`
- tests/test_move_store.py:392 [J.confirm-first] (test-data): `real = tx.publish`
- tests/test_move_store.py:395 [J.confirm-first] (test-data): `with patch.object(tx, 'publish', spy):`
- tests/test_move_store.py:407 [J.confirm-first] (test-data): `real = tx.publish`
- tests/test_move_store.py:414 [J.confirm-first] (test-data): `with patch.object(tx, 'publish', killer), self.assertRaises(Stop):`
- tests/test_proposal_store.py:58 [J.confirm-first] (test-data): `original=storage.transactions.publish`
- tests/test_proposal_store.py:59 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_proposal_store.py:67 [J.confirm-first] (test-data): `storage.transactions.publish=publish`
- tests/test_proposal_store.py:88 [J.confirm-first] (test-data): `def publish(self,evidence=None,validator=validate_current):`
- tests/test_proposal_store.py:104 [J.confirm-first] (test-data): `before = self.files(); link = self.publish(); after = self.files(); state = self.show()`
- tests/test_proposal_store.py:118 [J.confirm-first] (test-data): `link = self.publish(); before = self.files()`
- tests/test_proposal_store.py:121 [J.confirm-first] (test-data): `replay = self.publish(validator=lambda *args:self.fail('current validator called on replay'))`
- tests/test_proposal_store.py:124 [J.confirm-first] (test-data): `self.assertEqual(self.publish(),link)`
- tests/test_proposal_store.py:127 [J.confirm-first] (test-data): `link = self.publish(); before = self.files()`
- tests/test_proposal_store.py:129 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError) as caught: self.publish(changed)`
- tests/test_proposal_store.py:132 [J.confirm-first] (test-data): `second = self.publish(changed)`
- tests/test_proposal_store.py:162 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError) as caught: self.publish(validator=nested)`
- tests/test_proposal_store.py:166 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError): self.store.mutate(self.sid,'attempt-publish',{},mutator)`
- tests/test_proposal_store.py:176 [J.confirm-first] (test-data): `self.publish(stale,validator=lambda *args:self.fail('validator called before Store CAS'))`
- tests/test_proposal_store.py:192 [J.confirm-first] (test-data): `with self.subTest(validator=validator.__name__), self.assertRaises(IdeaError): self.publish(validator=validator)`
- tests/test_proposal_store.py:202 [J.confirm-first] (test-data): `with self.subTest(kind=kind), self.assertRaises(IdeaError): self.publish(changed)`
- tests/test_proposal_store.py:205 [J.confirm-first] (test-data): `with self.subTest(name=name), patch.object(module,name,value), self.assertRaises(IdeaError): self.publish()`
- tests/test_proposal_store.py:209 [J.confirm-first] (test-data): `original = tx.publish`
- tests/test_proposal_store.py:214 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',side_effect=uncertain), self.assertRaises(IdeaError) as caught:`
- tests/test_proposal_store.py:215 [J.confirm-first] (test-data): `self.publish()`
- tests/test_proposal_store.py:220 [J.confirm-first] (test-data): `replay = self.publish(validator=lambda *args:self.fail('replay validator'))`
- tests/test_proposal_store.py:243 [J.confirm-first] (test-data): `link = self.publish(); raw = (self.root/link['path']).read_bytes()`
- tests/test_proposal_store.py:261 [J.confirm-first] (test-data): `self.assertEqual(self.publish(validator=lambda *args:self.fail('historical retry validator')),link)`
- tests/test_proposal_store.py:264 [J.confirm-first] (test-data): `link = self.publish(); evidence_path = self.root/link['path']; original = evidence_path.read_bytes()`
- tests/test_proposal_store.py:279 [J.confirm-first] (test-data): `first = self.publish(); changed = copy.deepcopy(self.evidence); changed['correlation']['request_id']='suggestion-2'`
- tests/test_proposal_store.py:280 [J.confirm-first] (test-data): `second = self.publish(changed)`
- tests/test_proposal_store.py:297 [J.confirm-first] (test-data): `self.publish(); receipt_path=self.receipt_file(); saved=receipt_path.read_bytes()`
- tests/test_proposal_store.py:313 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError) as caught: self.publish(validator=changed_receipt)`
- tests/test_remove_idea.py:202 [J.confirm-first] (test-data): `tx.publish(self.source, {path: raw+b'x'}, {path: digest(raw)})`
- tests/test_remove_idea.py:239 [J.confirm-first] (test-data): `original = tx.publish`
- tests/test_remove_idea.py:243 [J.confirm-first] (test-data): `tx_publish, tx.publish = tx.publish, crashing`
- tests/test_remove_idea.py:248 [J.confirm-first] (test-data): `tx.publish = tx_publish`
- tests/test_service.py:256 [J.confirm-first] (test-data): `original=tx.publish`
- tests/test_service.py:257 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_service.py:261 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',publish):`
- tests/test_session_slots.py:91 [J.confirm-first] (test-data): `HandoffProvider(store).publish(TrustedContext(ACTOR,sid,self.key),publication_payload(store,self.key)['payload'])`
- tests/test_shared_store_modes.py:152 [J.confirm-first] (test-data): `def publish(self,umask=0o022,raw=b'index\n',before=None):`
- tests/test_shared_store_modes.py:157 [J.confirm-first] (test-data): `result = tx.publish(self.root,{'IDEAS.md':raw},{'IDEAS.md':before})`
- tests/test_shared_store_modes.py:170 [J.confirm-first] (test-data): `self.publish()`
- tests/test_shared_store_modes.py:181 [J.confirm-first] (test-data): `self.publish()`
- tests/test_store_requests.py:44 [J.confirm-first] (test-data): `original=storage.transactions.publish`
- tests/test_store_requests.py:45 [J.confirm-first] (test-data): `def publish(*args,**kwargs):`
- tests/test_store_requests.py:50 [J.confirm-first] (test-data): `storage.transactions.publish=publish`
- tests/test_store_requests.py:301 [J.confirm-first] (test-data): `original=tx.publish`
- tests/test_store_requests.py:306 [J.confirm-first] (test-data): `with patch.object(storage.transactions,'publish',side_effect=fail):`
- tests/test_transactions.py:31 [J.confirm-first] (test-data): `from idea_transactions import publish,recover`
- tests/test_transactions.py:51 [J.confirm-first] (test-data): `result=publish(root,changes,expected,freeze_legacy=True,legacy_sha256=digest(legacy),_checkpoint=checkpoint)`
- tests/test_transactions.py:53 [J.confirm-first] (test-data): `result=publish(root,changes,expected,_checkpoint=checkpoint)`
- tests/test_transactions.py:77 [J.confirm-first] (test-data): `def publish(self, changes=None, expected=None, **kwargs):`
- tests/test_transactions.py:79 [J.confirm-first] (test-data): `return tx.publish(self.root, self.changes() if changes is None else changes,`
- tests/test_transactions.py:91 [J.confirm-first] (test-data): `self.publish(_checkpoint=callback)`
- tests/test_transactions.py:102 [J.confirm-first] (test-data): `result=self.publish(_checkpoint=phases.append)`
- tests/test_transactions.py:189 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError): self.publish({path:b'x'},{path:None})`
- tests/test_transactions.py:195 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError): tx.publish(alias,self.changes(),self.expected())`
- tests/test_transactions.py:199 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError): self.publish()`
- tests/test_transactions.py:203 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError): self.publish({HISTORY:b'evidence'},{HISTORY:None})`
- tests/test_transactions.py:237 [J.confirm-first] (test-data): `self.publish({HISTORY:b'history',SESSION:b'first'},{HISTORY:None,SESSION:None}).raise_for_error()`
- tests/test_transactions.py:239 [J.confirm-first] (test-data): `self.publish({HISTORY:b'changed'},{HISTORY:digest(b'history')})`
- tests/test_transactions.py:241 [J.confirm-first] (test-data): `self.publish({HISTORY:b'history',SESSION:b'second'},{HISTORY:digest(b'history'),SESSION:digest(b'first')}).raise_for_error()`
- tests/test_transactions.py:250 [J.confirm-first] (test-data): `self.publish({path:b'metadata evidence'},{path:None},_checkpoint=checkpoint)`
- tests/test_transactions.py:254 [J.confirm-first] (test-data): `self.publish({path:b'changed'},{path:digest(b'metadata evidence')})`
- tests/test_transactions.py:256 [J.confirm-first] (test-data): `self.publish({path:b'metadata evidence'},{path:digest(b'metadata evidence')}).raise_for_error()`
- tests/test_transactions.py:263 [J.confirm-first] (test-data): `self.publish({prefix+suffix:b'bad'},{prefix+suffix:None})`
- tests/test_transactions.py:265 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError): self.publish({path:b'bad'},{path:None})`
- tests/test_transactions.py:270 [J.confirm-first] (test-data): `self.publish({prefix+link.name:b'bad'},{prefix+link.name:digest(b'index before')})`
- tests/test_transactions.py:276 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError) as caught: self.publish(expected=wrong)`
- tests/test_transactions.py:282 [J.confirm-first] (test-data): `result=self.publish()`
- tests/test_transactions.py:292 [J.confirm-first] (test-data): `result=self.publish()`
- tests/test_transactions.py:303 [J.confirm-first] (test-data): `result=tx.publish(self.root,self.changes(),self.expected())`
- tests/test_transactions.py:317 [J.confirm-first] (test-data): `self.publish(changes,expected,freeze_legacy=True,legacy_sha256=digest(legacy),_checkpoint=callback)`
- tests/test_transactions.py:361 [J.confirm-first] (test-data): `result=self.publish()`
- tests/test_transactions.py:397 [J.confirm-first] (test-data): `self.publish({SESSION:b'x'*(tx.MAX_INPUT+1)},{SESSION:None})`
- tests/test_transactions.py:400 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError): self.publish()`
- tests/test_transactions.py:407 [J.confirm-first] (test-data): `with self.assertRaises(IdeaError): self.publish(changes,expected,freeze_legacy=True,legacy_sha256=digest(b'actual legacy'))`
- tests/test_transactions.py:440 [J.confirm-first] (test-data): `return self.publish(self.move_changes(), self.move_expected(), move_out=IDEA, **kwargs)`
- tests/test_transactions.py:501 [J.confirm-first] (test-data): `self.publish(changes, expected, move_out=move_out)`
- tests/test_transactions.py:511 [J.confirm-first] (test-data): `self.publish(changes, expected, freeze_legacy=True, legacy_sha256=digest(legacy), move_out=IDEA)`
- tests/web/app-render.test.mjs:561 [J.confirm-first] (test-data): `await form.listeners.submit({preventDefault(){}});`
- tests/web/binding.test.mjs:394 [J.confirm-first] (test-data): `const submit=connection.all().find(node=>node.listeners?.submit);`
- tests/web/binding.test.mjs:395 [J.confirm-first] (test-data): `await submit.listeners.submit({preventDefault(){}});`
- tests/web/cp3-review-fixes.test.mjs:147 [J.confirm-first] (test-data): `test('a disabled Accept names a lost connection, an unusable suggestion, and never stays silent', () => {`
- tests/web/exploration-proposals.test.mjs:337 [J.confirm-first] (test-data): `test('invalid and partial cap text cannot flip sign, silently validate, or submit invalid numeric draft', async () => {`
- tests/web/handoff.test.mjs:267 [J.confirm-first] (test-data): `await form.listeners.submit({preventDefault() {}});`
- tests/web/handoff.test.mjs:306 [J.confirm-first] (test-data): `await form.listeners.submit({preventDefault() {}});`

### 4d Talking to the human

#### phrase.G.human (0 lines)

None.

### Tables

Hosts: 40, 30 not named in the docs. Confirm-first or prohibited actions in instruction text: 6, 1 with no confirmation step, 0 stated as prohibitions. Conditionals: 18 absence, 11 error, 3 clock, 2 version. Definitions: 12, 1 conflict, 0 safety-word definitions. Long files with flagged lines: 0, 0 with some past the reader window. Sentences repeated across files: 5, 1 flagged. Lines that look like committed secrets: 0 (plus 5 in test data), by gitleaks.

### Endpoints (hosts named anywhere; documented = named in the docs) (40)

- 0.0.0.0: not in the docs, local, local; 1 code; first at tests/test_native.py:127
- ::1: not in the docs, local, local; 1 code; first at tests/test_workflow_api.py:73
- localhost: not in the docs, local, local; 2 code; first at tests/test_agent_transport.py:135
- self.local: not in the docs, local, local; 16 code; first at tests/test_install.py:20
- 10.0.0.5: not in the docs, other; 1 code; first at tests/test_workflow_api.py:68
- 127.0.0.1.evil.example: not in the docs, other; 1 code; first at tests/test_ssh_mode.py:624
- 198.51.100.34: not in the docs, other; 1 code; first at tests/test_ssh_mode.py:360
- a.example: not in the docs, other; 1 code; first at tests/web/setup.test.mjs:62
- asq.org: not in the docs, other; 1 instructions; first at glitch-idea/references/methods.md:53
- attacker.test: not in the docs, other; 3 code; first at tests/test_native_probe.py:98
- b.example: not in the docs, other; 1 code; first at tests/test_workflow_api.py:69
- board.example: not in the docs, other; 19 code; first at tests/test_agent_launch.py:276
- c2pa.org: not in the docs, other; 1 instructions; first at glitch-idea/web/assets/logo.svg:1
- cdn.example: not in the docs, other; 1 code; first at tests/web/folds.test.mjs:372
- evil.example: not in the docs, other; 6 code; first at tests/test_prototype_server.py:108
- example.com: not in the docs, other; 1 code; first at tests/test_native.py:126
- example.invalid: not in the docs, other; 3 code; first at tests/browser_flow_smoke.mjs:433
- example.org: not in the docs, other; 2 code; first at tests/web/proposals.test.mjs:536
- example.test: not in the docs, other; 8 code; first at tests/test_agent_resume.py:243
- framework.scaledagile.com: not in the docs, other; 1 instructions; first at glitch-idea/references/methods.md:53
- intercom.com: not in the docs, other; 1 instructions; first at glitch-idea/references/methods.md:53
- logging.info: not in the docs, other; 3 code; first at glitch-idea/scripts/idea_launch.py:517
- other.example: not in the docs, other; 2 code; first at tests/web/setup.test.mjs:155
- outside.invalid: not in the docs, other; 1 code; first at tests/web/upload-api.test.mjs:52
- self.app: not in the docs, other; 6 code; first at tests/test_asset_agent_door.py:43
- ui.test: not in the docs, other; 7 code; first at glitch-idea/web/setup.js:64
- unlicense.org: not in the docs, other; 1 instructions; first at glitch-idea/web/assets/fonts/BlastworksSans-UNLICENSE.txt:24
- w.example: not in the docs, other; 11 code; first at tests/web/setup.test.mjs:141
- w3.org: not in the docs, other; 1 instructions, 5 code; first at glitch-idea/web/app.js:133
- workstation.example: not in the docs, other; 1 code; first at tests/test_ssh_mode.py:222
- workstation.example.net: not in the docs, other; 4 code; first at tests/test_ssh_mode.py:320
- workstation.tailnet.example.net: not in the docs, other; 2 code; first at tests/test_port_config_contract.py:21
- x.example: not in the docs, other; 7 code; first at tests/web/folds.test.mjs:384
- yaml.org: not in the docs, other; 3 code; first at glitch-idea/scripts/idea_markdown.py:63
- 127.0.0.1: documented, local, local; 2 instructions, 9 docs, 71 code; first at README.md:179
- blastworks.ai: documented, other; 2 docs; first at LICENSE:3
- board.example.com: documented, other; 1 docs; first at docs/workflow-api.md:18
- claude.ai: documented, other; 2 docs; first at docs/design-provenance.md:7
- claude.com: documented, other; 9 docs; first at docs/history/pull-requests/PR-001.md:26
- github.com: documented, other; 4 instructions, 10 docs, 8 code; first at README.md:300

### Confirm-first and prohibited actions in instruction text (6)

- glitch-idea/PyYAML-MIT-NOTICE.txt:13: confirm-first, `publish`, confirmation at line 10: `use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies`
- glitch-idea/references/commands.md:181: confirm-first, `send no fills. If that reply`, confirmation at line 181: `` The reply carries `asset_id`. The order is fixed: upload both files, then `fill` `visualize` with `{"source": "prototype", "assets": [<zip id>, <png id>]}` while the `visual_brief` request is open, then ask the operator to look at the page, then reply `prototype_skill: "available"` last, only once the operator confirms the page shows "Prototype ready". A reply closes the request, so a fill after it is refused `request_closed`; when the skill is missing, reply `prototype_skill: "unavailable"` at once and send no fills. If that reply is refused `request_cancelled` or `request_closed` because the operator already pressed Accept or moved on, the step is done and the agent says nothing more about it. ``
- glitch-idea/references/commands.md:321: confirm-first, `publish`, confirmation at line 321: `` With `--confirm`, in one journaled publish: the detail, `history/<id>/**`, the linked evidence (proposals, assets, handoffs, migration copies), plan evidence, every archive view `archive/<id>/*` (it holds the origin text) and the index row go, and the order renumbers. ``
- glitch-idea/references/commands.md:324: confirm-first, `publish`, confirmation at line 318: `` An immutable tombstone `history/removed/<id>.md` (`<id>.2.md`, `<id>.3.md` … when the same idea was imported again and removed again) is written in the same publish, sealed read-only (0400, or 0440 in a shared store): idea id, actor, time, first words and a manifest of the removed paths with their sha256. ``
- glitch-idea/references/commands.md:331: confirm-first, `publish`, confirmation at line 331: `` With `--confirm` the idea is removed first (store lock, one journaled publish, as above), then the launcher scans again, so a session saved during the removal is caught, and drops every session of this seat that selects the idea, in use or not. ``
- glitch-idea/web/assets/fonts/BlastworksSans-UNLICENSE.txt:3: confirm-first, `publish`, no confirmation step: `Anyone is free to copy, modify, publish, use, compile, sell, or`

### Conditionals (34)

- glitch-idea/SKILL.md:20: absence: if `` when there is no `notice` `` then `Never reword it, add the file names or count them yourself; say nothing about updates.`
- glitch-idea/SKILL.md:50: error: if `if the second run fails too.` then `` If `browser-open` returns `service_readiness_timeout`, the service is still starting (a large store takes a few seconds to load): run the same `browser-open` once more without telling the operator, and report it only ``
- glitch-idea/SKILL.md:53: error: if `after an expired or failed pairing)` then `` Ready first: before a typed code is ever issued (plain `session-open`, or `session-open --resume <binding_id>` ask the operator ONE question, "ready to type a code?", and run the verb only on their yes, then give the origin and the fresh code in the same message that carries it. ``
- glitch-idea/SKILL.md:60: error: if `when the operator says the click failed or the 60 seconds have clearly passed.` then `` `events` does not report a pairing that expired unredeemed (it only appears as `pairing_expired_or_locked` when a redeem is attempted), so do not wait for an event: offer the fresh link ``
- glitch-idea/SKILL.md:86: error: if `after "$idea_after" --timeout 25 --runtime-root "$idea_runtime"` then `"$idea_python" "$idea_tool" --store "$idea_store" events --session "$idea_session" --`
- glitch-idea/SKILL.md:127: clock: if `after 10 minutes without a reply or a wait the agent is` then `Answer within it:`
- glitch-idea/SKILL.md:150: absence: if `when the chosen method does not need them (no top-level fill field may be null; nested nulls are allowed only where documented` then `` Send as many fills as the step needs, with only the agreed keys: never send `null` as a fill field value (a fill is refused `invalid_fill`), and leave out `investment` and `experiment` `preferred_method` inside the memory line and a sketch item's `method`); the page shows each one at once and saves it as the operator's draft. ``
- glitch-idea/SKILL.md:160: absence: if `when no other memory capability is available` then `` Run the bounded memory retrieval ( a read-only `list` of this store's own ideas, with their accepted methods, is an acceptable bounded retrieval) and send a method memory fill only: `fields: {"memory": {status, sources, rationale, preferred_method}}`. ``
- glitch-idea/SKILL.md:178: clock: if `after "How is it handled today?"` then `` Then ask a sixth, **Does it already exist?** Search the web for existing products and open-source projects that do the same job, and fill them under `prior_art` (a list, at most 8, of `{name, link, does, differs, licence}`, all strings): the name, a source link, what it does, how this idea differs, and the licence read from the source itself, the repo's LICENSE file or the product's terms (for example "MIT", "Apache-2.0", "Proprietary", "SaaS, closed", or "Not stated" when the source states none; never guess one). ``
- glitch-idea/SKILL.md:184: absence: if `when the operator has no risks or nothing to learn yet` then `` The page keeps each field locked until the terminal has delivered it, so send `assumptions` and `learning` explicitly as an empty list (`[]`), never null, and never omit them, or the step cannot close. ``
- glitch-idea/SKILL.md:198: absence: if `When the skill is missing` then `` reply `prototype_skill: "unavailable"` at once and send no fills; the page tells the operator where to get it and you say the same in one line; the agent never installs it. ``
- glitch-idea/SKILL.md:232: version: if `If the runtime interpreter lacks PyYAML 6.0.3` then `` the installer fails with `runtime_prerequisite` and prints the exact `"<python>" -m pip install -r "<requirements.txt>"` command for the operator to run, then they rerun the installer. ``
- glitch-idea/SKILL.md:232: version: if `If the interpreter is older than Python 3.10` then `` the installer fails with `install_error` and no pip command: the operator needs a newer Python (a new venv from it), not a package. ``
- glitch-idea/SKILL.md:234: absence: if `` When the browser is on another computer and the seat has no fixed `browser_port` `` then `` tell the operator SSH mode needs a fixed port and a standing tunnel; never print an `ssh -L` line. ``
- glitch-idea/SKILL.md:234: error: if `` If Orca launch fails with `origin_missing` or `usage` `` then `` no session exists yet: report it and have the selectors corrected, without `--resume`. ``
- glitch-idea/SKILL.md:234: error: if `If it fails later` then `` the error carries the `binding_id` but no origin: report the code and the `binding_id`, do not silently open another browser, and let the operator choose between fixing Orca and rerunning `browser-open ... ``
- glitch-idea/SKILL.md:266: error: if `when resuming delivery links or investigating a failure; follow the repair guidance in commands.md.` then `` Check `doctor` ``
- glitch-idea/references/commands.md:3: absence: if `` when the dependency is missing it fails with `runtime_prerequisite` and prints the exact `pip install` command for the operator to run. `` then `` The installer (`install.py`) can create a per-skill venv offline and checks the pinned PyYAML, but it never downloads: ``
- glitch-idea/references/commands.md:23: error: if `after an expired or failed pairing)` then `` Ready first: before a typed code is ever issued (plain `session-open`, or `session-open --resume binding_ID` ask the operator ONE question, "ready to type a code?", and run the verb only on their yes, giving the origin and fresh code in the same message that carries it (60 seconds: measured 12 seconds at the box, expired when the code travels through a prompt first). ``
- glitch-idea/references/commands.md:62: clock: if `after 15 minutes without authenticated activity and with no active requests.` then `The service also exits`
- glitch-idea/references/commands.md:93: error: if `after 0 --timeout 25` then `python3 "$idea_tool" --store /absolute/demo-ideas events --session session_ID_FROM_OUTPUT --`
- glitch-idea/references/commands.md:111: absence: if `after every wait returns; it is a no-op on a paired tab` then `` In Orca mode the same loop runs `browser-open --reconnect <binding_id>` re-pairs a rebuilt one in place without waking the agent, and the loop only records its result. ``
- glitch-idea/references/commands.md:115: absence: if `After 600 seconds with no reply and no wait` then `the agent is disconnected and the request is cancelled.`
- glitch-idea/references/commands.md:131: absence: if `` once and no request waits for a `respond`; the next step's request replaces the open one. `` then `A fill alone is enough: the page shows it at`
- glitch-idea/references/commands.md:181: absence: if `` after it is refused `request_closed`; when the skill is missing `` then `` A reply closes the request, so a fill reply `prototype_skill: "unavailable"` at once and send no fills. ``
- glitch-idea/references/commands.md:204: absence: if `if that signal is missing or unreliable."}` then `{"route": "Fix attention classification first", "reason": "Necessary`
- glitch-idea/references/commands.md:209: absence: if `if the signal is absent."` then `"next_slice": "Inspect one representative summary and compare its count with source records; stop`
- glitch-idea/references/commands.md:232: absence: if `If none was supplied` then `` use the neutral `--reason 'Operator selected this position; no reason supplied'`; do not invent a motive or ask for one unnecessarily. ``
- glitch-idea/references/commands.md:330: absence: if `when none runs) and` then `` The preview adds `sessions_to_drop` (rows of `binding_id` and `in_use`: `true` or `false` when this seat's service answers, `null` when there are any, a `sessions_note` saying that `--confirm` drops them too. ``
- glitch-idea/references/commands.md:336: absence: if `` After a removal `doctor` is healthy and `list` no longer shows the idea. `` then ``
- glitch-idea/references/commands.md:342: absence: if `when its home file or workspace folder is missing` then `` For a moved idea, `doctor` is unhealthy and names the path glitch-idea keeps no copy and cannot restore it, so restore it from your own backup. ``
- glitch-idea/references/commands.md:344: error: if `` If a failure reports `committed `` then `` true`, the authoritative transaction already succeeded. ``
- glitch-idea/tern-plugin/window.luau:99: error: if `if err == nil and type(result) == "table" and result.error == nil and result.ok ~= nil` then ``
- glitch-idea/tern-plugin/window.luau:131: absence: if `if not present[name]` then `seen[name] = nil end`

### Definitions (12)

- glitch-idea/SKILL.md:74: "tabstillpaired" (explicit): `` nothing was wrong; on `tab_not_recorded` or `tab_unreadable`, tell the operator in one line and resume only on their word. ``
- glitch-idea/SKILL.md:134: "session-open" (explicit): `the loop started too late.`
- glitch-idea/SKILL.md:134: "requestcancelled on a fill" (explicit): `the operator moved on: read the next request from the loop's file, never resume the session.`
- glitch-idea/SKILL.md:220: "agentunavailable there" (explicit): `the run is over, not an error.`
- glitch-idea/SKILL.md:228: "unsupportedideaversion now" (explicit): `this one idea could not be updated for this version and was left as it was: give the operator the returned sentence verbatim, and do not try to fix or re-capture it.`
- glitch-idea/references/commands.md:111: "session-open" (explicit): `the loop started too late).`
- glitch-idea/references/commands.md:111: "requestcancelled on a fill" (explicit): `the operator moved on: read the next request from the loop's file, never resume the session.`
- glitch-idea/references/commands.md:132: "and agentunavailable there" (explicit): `the run is over, not an error.`
- glitch-idea/references/commands.md:141: "true" (explicit): `` the agent's idle clock was reset, `false` means no connected agent of that generation, and `n/a` means no agent is attached. ``
- glitch-idea/references/commands.md:147: "session-open --resume bindingid" (explicit): `that session was freed (automatically at Review, to make room) or discarded: say so in one line and open a new session; its ideas are still in the store.`
- glitch-idea/references/commands.md:329: "no runtime folder" (explicit): `` no sessions, which is not an error; a runtime that cannot be read refuses `sessions_unreadable` before anything is touched. ``
- glitch-idea/tern-plugin/window.luau:143: "failed remove" (explicit): `another window already took it.`

### Terms defined more than one way (1)

- "session-open": glitch-idea/SKILL.md:134; glitch-idea/references/commands.md:111

### Safety words defined (0)

None.

### Lines that look like committed secrets (values never shown) (5)

- tests/fake_workflow_api.py:70: generic-api-key (gitleaks, test data)
- tests/test_agent_launch.py:261: generic-api-key (gitleaks, test data)
- tests/test_agent_launch.py:274: generic-api-key (gitleaks, test data)
- tests/test_workflow_api.py:21: generic-api-key (gitleaks, test data)
- tests/web/setup.test.mjs:10: generic-api-key (gitleaks, test data)

### Position of flagged lines in long files (first 10% / middle 80% / last 10%) (0)

None.

### Settings that restrict tools (a fact, never a risk) (0)

None.

### Sentences repeated across files a model reads (5)

- glitch-idea/SKILL.md:102: in 2 files (2 times): `` `respond` is for `visual_brief` only. ``
- glitch-idea/SKILL.md:134: in 2 files (2 times): `` A `request_cancelled` on a fill means the operator moved on: read the next request from the loop's file, never resume the session. ``
- glitch-idea/SKILL.md:191: in 2 files (2 times): `In the page the accepted set is called "the design", and a file only becomes part of it when the operator ticks it: uploading keeps a file with the idea and nothing more. The Claude Design card's buttons read "Choose which files are the des`
- glitch-idea/SKILL.md:199: in 2 files (2 times): `` If that reply is refused `request_cancelled` or `request_closed` because the operator already pressed Accept or moved on, the step is done and the agent says nothing more about it. ``
- glitch-idea/SKILL.md:203: in 2 files (2 times), flagged B.safety-adjective: `` Read its first JSON line for `origin`, `port` and `fixed_port`. ``

### Will it trigger

What each host does with a skill's, agent's, or command's frontmatter is in `stages/04-phrases/trigger.yaml` (dated, with sources).

1 skill: 1 Claude chooses by its description.

Skill descriptions here take about 74 tokens (294 characters). Claude Code's listing of every installed skill holds about 1% of the context: about 320 tokens at 32,000, 2,000 at 200,000.

- `glitch-idea/SKILL.md` (skill): auto; description 294 characters

Every entry has frontmatter its host reads and follows the rules.

### Ready for any AI

What each AI host reads is in `stages/04-phrases/hosts.yaml` (dated, with sources).

For the hosts named (claude, codex):

- Claude Code: no instruction file it reads (CLAUDE.md, CLAUDE.local.md, .claude/CLAUDE.md, and 1 more).
- Codex: no instruction file it reads (AGENTS.md).

- Claude Code: none of its files (it reads CLAUDE.md, CLAUDE.local.md, .claude/CLAUDE.md; skills in .claude/skills).
- Codex: none of its files (it reads AGENTS.md; skills in .agents/skills).
- Gemini CLI: none of its files (it reads GEMINI.md; skills in .gemini/skills, .agents/skills).
- Cursor: none of its files (it reads .cursor/rules/*.mdc, AGENTS.md, .cursorrules; skills in .agents/skills, .cursor/skills, .claude/skills, .codex/skills).
- GitHub Copilot: none of its files (it reads .github/copilot-instructions.md, .github/instructions/*.instructions.md, AGENTS.md; skills in .github/skills, .claude/skills, .agents/skills).
- Windsurf: none of its files (it reads .windsurf/rules/*.md, AGENTS.md, .windsurfrules).
- Other tools that read AGENTS.md: none of its files (it reads AGENTS.md).

Skills no host reads where they sit (1); a host reads them once they are installed (copied into its skill folder, or added as a plugin):

- `glitch-idea/SKILL.md`

Copies kept for two hosts (0):

- None.

No one-host feature found.

### Current and clean

Facts with locations: Walkdown never says a date is past, a model retired, or a TODO matters. The patterns are in `stages/04-phrases/clean.yaml` (dated, with sources).

No unfinished text, dated claims, pinned model IDs, or older tool names.

## 5 What this touches

Can read your data: yes · Can take outside input: yes · Can send data out: yes All three at once: it can read your data, take outside input, and send data out. That is the combination text from outside can steer into sending your data away. Install grants: context-injection, persistence, network. Test data set aside: 1047 findings in test or fixture folders count toward none of the above.

Validation: PASS (gate 81/81, negative 24/24; measured 2026-11-02, same code and fixtures)

A map of capability, derived from stages 1 to 4; it reaches no verdict. A Bash grant is counted as private-data access and execute posture; on its own it does not count as external communication.

### Trifecta legs

- Can read your data: yes (11 citations)
    - stage 04 phrase.K.exfil glitch-idea/references/commands.md:77: phrase.K.exfil: K.data-flow
    - stage 04 phrase.creds glitch-idea/references/commands.md:197: phrase.creds: creds.enumerate
    - stage 04 phrase.K.exfil glitch-idea/references/commands.md:283: phrase.K.exfil: K.data-flow
    - stage 04 phrase.creds glitch-idea/scripts/idea_bridge.py:407: phrase.creds: creds.enumerate
    - stage 04 phrase.creds glitch-idea/scripts/idea_runtime.py:388: phrase.creds: creds.path
    - stage 04 phrase.creds glitch-idea/scripts/idea_runtime.py:393: phrase.creds: creds.path
    - stage 04 phrase.creds glitch-idea/scripts/idea_runtime.py:507: phrase.creds: creds.path
    - stage 04 phrase.creds glitch-idea/scripts/idea_runtime.py:550: phrase.creds: creds.path
    - stage 04 phrase.creds glitch-idea/scripts/idea_runtime.py:713: phrase.creds: creds.path
    - stage 04 phrase.creds glitch-idea/scripts/idea_sessions.py:184: phrase.creds: creds.enumerate
    - stage 04 phrase.creds glitch-idea/scripts/idea_ssh.py:173: phrase.creds: creds.path
- Can take outside input: yes (3 citations)
    - stage 04 phrase.E.env glitch-idea/SKILL.md:232: phrase.E.env: E.install
    - stage 04 phrase.E.env glitch-idea/references/commands.md:3: phrase.E.env: E.install
    - stage 04 phrase.remote-load glitch-idea/references/commands.md:64: phrase.remote-load: RL.branch-ref
- Can send data out: yes (4 citations)
    - stage 04 phrase.remote-load glitch-idea/references/commands.md:64: phrase.remote-load: RL.branch-ref
    - stage 04 phrase.K.exfil glitch-idea/references/commands.md:77: phrase.K.exfil: K.data-flow
    - stage 04 phrase.K.exfil glitch-idea/references/commands.md:283: phrase.K.exfil: K.data-flow
    - stage 04 phrase.K.exfil glitch-idea/scripts/idea_ssh.py:376: phrase.K.exfil: K.http-verb

### Install grants

- context-injection (1 citation)
    - stage 01 struct.description glitch-idea/SKILL.md:3: description: always-on text
- persistence (5 citations)
    - stage 04 phrase.E.perms glitch-idea/scripts/idea_bridge.py:13: phrase.E.perms: E.outlives-session
    - stage 04 phrase.E.perms glitch-idea/scripts/idea_launch.py:563: phrase.E.perms: E.outlives-session
    - stage 04 phrase.E.env glitch-idea/scripts/idea_proposal_evidence.py:121: phrase.E.env: E.memory
    - stage 04 phrase.E.perms glitch-idea/scripts/idea_prototype.py:18: phrase.E.perms: E.outlives-session
    - stage 04 phrase.E.env glitch-idea/scripts/idea_steps/method.py:4: phrase.E.env: E.memory
- network (4 citations)
    - stage 04 phrase.remote-load glitch-idea/references/commands.md:64: phrase.remote-load: RL.branch-ref
    - stage 04 phrase.K.exfil glitch-idea/references/commands.md:77: phrase.K.exfil: K.data-flow
    - stage 04 phrase.K.exfil glitch-idea/references/commands.md:283: phrase.K.exfil: K.data-flow
    - stage 04 phrase.K.exfil glitch-idea/scripts/idea_ssh.py:376: phrase.K.exfil: K.http-verb

### Text in context at load

Bytes at load: descriptions 294 (1, exact).

- glitch-idea/SKILL.md:3: description, 294 bytes, exact

### What it costs and what ships

Expected context: 32,000 tokens (a line for 200,000 beside it). Tokens are estimated from size: about 4 bytes of English text per token; text in other scripts runs high.

- Every session, once installed (descriptions, hooks): 74 tokens, under 1% of 32,000, under 1% of 200,000
- When the largest skill runs: 9,293 tokens, 29% of 32,000, 5% of 200,000
- That skill and everything it names: 21,848 tokens, 68% of 32,000, 11% of 200,000
- The largest is `glitch-idea/SKILL.md`, of 1 skill, agent, or command.

Every skill, agent, or command, by tier (tokens):

- glitch-idea/SKILL.md: runs 9,293, with what it names 21,848, with wildcard loads 21,848; names 1 file outside its folder, not counted: `install.py`

#### Loads into the AI: 4 files, 85.3 KB, 21,848 tokens

- `glitch-idea/SKILL.md`: skills, agents, and commands, 36.3 KB, 9,293 tokens
- `glitch-idea/references/commands.md`: named by a file the AI loads, 43.7 KB, 11,192 tokens, reached from `glitch-idea/SKILL.md`
- `glitch-idea/references/methods.md`: named by a file the AI loads, 5.2 KB, 1,340 tokens, reached from `glitch-idea/SKILL.md`
- `glitch-idea/requirements.txt`: named by a file the AI loads, 89 bytes, 23 tokens, reached from `glitch-idea/SKILL.md`

#### Used another way: 1 file, 30.7 KB, 7,848 tokens

- `glitch-idea/scripts/idea.py`: scripts it runs, 30.7 KB, 7,848 tokens

#### Not used at run time: 275 files, 5.7 MB, 1,078,710 tokens

- `LICENSE`: written for people, 1.0 KB, 268 tokens
- `README.md`: written for people, 19.9 KB, 5,085 tokens
- `docs/acceptance-browser-flow.md`: written for people, 13.5 KB, 3,453 tokens
- `docs/asset-format.md`: written for people, 8.9 KB, 2,291 tokens
- `docs/browser-api.md`: written for people, 52.5 KB, 13,452 tokens
- `docs/browser-runbook.md`: written for people, 25.9 KB, 6,623 tokens
- `docs/cp1-validation.md`: written for people, 5.1 KB, 1,318 tokens
- `docs/cp2-validation.md`: written for people, 8.5 KB, 2,189 tokens
- `docs/cp3-validation.md`: written for people, 8.9 KB, 2,273 tokens
- `docs/cp4-validation.md`: written for people, 13.5 KB, 3,451 tokens
- `docs/design-provenance.md`: written for people, 4.2 KB, 1,085 tokens
- `docs/handoff-format.md`: written for people, 13.8 KB, 3,544 tokens
- `docs/history/pull-requests/PR-001.md`: written for people, 2.4 KB, 616 tokens
- `docs/history/pull-requests/PR-002.md`: written for people, 4.8 KB, 1,218 tokens
- `docs/history/pull-requests/PR-003.md`: written for people, 4.2 KB, 1,072 tokens
- `docs/history/pull-requests/PR-004.md`: written for people, 4.1 KB, 1,049 tokens
- `docs/history/pull-requests/PR-005.md`: written for people, 3.7 KB, 942 tokens
- `docs/history/pull-requests/PR-006.md`: written for people, 4.4 KB, 1,135 tokens
- `docs/history/pull-requests/PR-007.md`: written for people, 4.0 KB, 1,018 tokens
- `docs/history/pull-requests/PR-008.md`: written for people, 2.8 KB, 714 tokens
- `docs/history/pull-requests/README.md`: written for people, 1.5 KB, 374 tokens
- `docs/markdown-format.md`: written for people, 22.6 KB, 5,778 tokens
- `docs/orca-contract.md`: written for people, 22.4 KB, 5,733 tokens
- `docs/screenshots/01-capture.png`: written for people, 115.0 KB, not text
- `docs/screenshots/02-priorities.png`: written for people, 76.6 KB, not text
- `docs/screenshots/03-methods.png`: written for people, 141.9 KB, not text
- `docs/screenshots/04-discovery.png`: written for people, 193.0 KB, not text
- `docs/screenshots/05-exploration.png`: written for people, 245.9 KB, not text
- `docs/screenshots/06-visualize.png`: written for people, 154.3 KB, not text
- `docs/screenshots/07-assess.png`: written for people, 299.9 KB, not text
- `docs/screenshots/08-review.png`: written for people, 150.8 KB, not text
- `docs/screenshots/09-review-planning-prompt.png`: written for people, 157.7 KB, not text
- `docs/workflow-api.md`: written for people, 5.8 KB, 1,497 tokens
- `glitch-idea/tern-plugin/LICENSE`: written for people, 1.0 KB, 268 tokens
- `glitch-idea/tern-plugin/README.md`: written for people, 1.4 KB, 368 tokens
- `glitch-idea/web/assets/NOTICE.md`: written for people, 2.2 KB, 568 tokens
- `install.py`: written for people, 22.4 KB, 5,744 tokens
- `.gitignore`: build material: tests, fixtures, CI, tooling, 885 bytes, 222 tokens
- `glitch-idea/scripts/idea_agent_client.py`: build material: tests, fixtures, CI, tooling, 13.9 KB, 3,548 tokens
- `glitch-idea/scripts/idea_agent_memory.py`: build material: tests, fixtures, CI, tooling, 8.3 KB, 2,136 tokens
- `glitch-idea/scripts/idea_agent_source.py`: build material: tests, fixtures, CI, tooling, 28.1 KB, 7,202 tokens
- `glitch-idea/scripts/idea_assessment.py`: build material: tests, fixtures, CI, tooling, 12.2 KB, 3,121 tokens
- `glitch-idea/scripts/idea_asset_evidence.py`: build material: tests, fixtures, CI, tooling, 12.2 KB, 3,133 tokens
- `glitch-idea/scripts/idea_assets.py`: build material: tests, fixtures, CI, tooling, 19.4 KB, 4,979 tokens
- `glitch-idea/scripts/idea_bridge.py`: build material: tests, fixtures, CI, tooling, 48.2 KB, 12,331 tokens
- `glitch-idea/scripts/idea_chain.py`: build material: tests, fixtures, CI, tooling, 7.2 KB, 1,851 tokens
- `glitch-idea/scripts/idea_chain_v2.py`: build material: tests, fixtures, CI, tooling, 5.7 KB, 1,450 tokens
- `glitch-idea/scripts/idea_domain.py`: build material: tests, fixtures, CI, tooling, 8.5 KB, 2,171 tokens
- `glitch-idea/scripts/idea_handoff.py`: build material: tests, fixtures, CI, tooling, 13.2 KB, 3,373 tokens
- `glitch-idea/scripts/idea_handoff_evidence.py`: build material: tests, fixtures, CI, tooling, 21.0 KB, 5,380 tokens
- `glitch-idea/scripts/idea_launch.py`: build material: tests, fixtures, CI, tooling, 45.4 KB, 11,632 tokens
- `glitch-idea/scripts/idea_markdown.py`: build material: tests, fixtures, CI, tooling, 60.9 KB, 15,601 tokens
- `glitch-idea/scripts/idea_migration.py`: build material: tests, fixtures, CI, tooling, 6.3 KB, 1,621 tokens
- `glitch-idea/scripts/idea_native.py`: build material: tests, fixtures, CI, tooling, 11.0 KB, 2,825 tokens
- `glitch-idea/scripts/idea_platform.py`: build material: tests, fixtures, CI, tooling, 10.3 KB, 2,639 tokens
- `glitch-idea/scripts/idea_proposal_evidence.py`: build material: tests, fixtures, CI, tooling, 12.3 KB, 3,158 tokens
- `glitch-idea/scripts/idea_proposals.py`: build material: tests, fixtures, CI, tooling, 36.5 KB, 9,355 tokens
- `glitch-idea/scripts/idea_prototype.py`: build material: tests, fixtures, CI, tooling, 9.5 KB, 2,439 tokens
- `glitch-idea/scripts/idea_runtime.py`: build material: tests, fixtures, CI, tooling, 51.4 KB, 13,150 tokens
- `glitch-idea/scripts/idea_service.py`: build material: tests, fixtures, CI, tooling, 69.1 KB, 17,691 tokens
- `glitch-idea/scripts/idea_sessions.py`: build material: tests, fixtures, CI, tooling, 30.6 KB, 7,836 tokens
- `glitch-idea/scripts/idea_ssh.py`: build material: tests, fixtures, CI, tooling, 26.8 KB, 6,865 tokens
- `glitch-idea/scripts/idea_steps/__init__.py`: build material: tests, fixtures, CI, tooling, 4.0 KB, 1,028 tokens
- `glitch-idea/scripts/idea_steps/assess.py`: build material: tests, fixtures, CI, tooling, 4.1 KB, 1,052 tokens
- `glitch-idea/scripts/idea_steps/discovery.py`: build material: tests, fixtures, CI, tooling, 965 bytes, 242 tokens
- `glitch-idea/scripts/idea_steps/exploration.py`: build material: tests, fixtures, CI, tooling, 1.2 KB, 299 tokens
- `glitch-idea/scripts/idea_steps/method.py`: build material: tests, fixtures, CI, tooling, 1.0 KB, 259 tokens
- `glitch-idea/scripts/idea_steps/visualize.py`: build material: tests, fixtures, CI, tooling, 4.8 KB, 1,224 tokens
- `glitch-idea/scripts/idea_store.py`: build material: tests, fixtures, CI, tooling, 166.0 KB, 42,502 tokens
- `glitch-idea/scripts/idea_transactions.py`: build material: tests, fixtures, CI, tooling, 27.8 KB, 7,125 tokens
- `glitch-idea/scripts/idea_workflow.py`: build material: tests, fixtures, CI, tooling, 48.1 KB, 12,308 tokens
- `glitch-idea/scripts/idea_workflow_api.py`: build material: tests, fixtures, CI, tooling, 10.8 KB, 2,760 tokens
- `glitch-idea/scripts/idea_workflow_v2.py`: build material: tests, fixtures, CI, tooling, 18.4 KB, 4,710 tokens
- `glitch-idea/web/api.js`: build material: tests, fixtures, CI, tooling, 34.4 KB, 8,794 tokens
- `glitch-idea/web/app.js`: build material: tests, fixtures, CI, tooling, 51.7 KB, 13,243 tokens
- `glitch-idea/web/folds.js`: build material: tests, fixtures, CI, tooling, 102.0 KB, 26,108 tokens
- `glitch-idea/web/ideas.js`: build material: tests, fixtures, CI, tooling, 20.2 KB, 5,173 tokens
- `glitch-idea/web/setup.js`: build material: tests, fixtures, CI, tooling, 10.8 KB, 2,769 tokens
- `glitch-idea/web/steps/assess.js`: build material: tests, fixtures, CI, tooling, 30.0 KB, 7,673 tokens
- `glitch-idea/web/steps/discovery.js`: build material: tests, fixtures, CI, tooling, 15.2 KB, 3,899 tokens
- `glitch-idea/web/steps/exploration.js`: build material: tests, fixtures, CI, tooling, 22.2 KB, 5,672 tokens
- `glitch-idea/web/steps/method.js`: build material: tests, fixtures, CI, tooling, 10.1 KB, 2,575 tokens
- `glitch-idea/web/steps/review.js`: build material: tests, fixtures, CI, tooling, 17.5 KB, 4,484 tokens
- `glitch-idea/web/steps/visualize.js`: build material: tests, fixtures, CI, tooling, 38.0 KB, 9,740 tokens
- `tests/browser_flow_smoke.mjs`: build material: tests, fixtures, CI, tooling, 140.8 KB, 36,038 tokens
- `tests/fake_workflow_api.py`: build material: tests, fixtures, CI, tooling, 4.0 KB, 1,024 tokens
- `tests/fixtures/handoff_plan_validator.py`: build material: tests, fixtures, CI, tooling, 898 bytes, 225 tokens
- `tests/fixtures/make_store_v2.py`: build material: tests, fixtures, CI, tooling, 3.7 KB, 942 tokens
- `tests/fixtures/markdown/IDEAS.md`: build material: tests, fixtures, CI, tooling, 550 bytes, 138 tokens
- `tests/fixtures/markdown/history/idea_00000000000000000000000000000001/r1.md`: build material: tests, fixtures, CI, tooling, 478 bytes, 120 tokens
- `tests/fixtures/markdown/idea_00000000000000000000000000000001.md`: build material: tests, fixtures, CI, tooling, 1.2 KB, 317 tokens
- `tests/fixtures/scrub_store.py`: build material: tests, fixtures, CI, tooling, 8.2 KB, 2,093 tokens
- `tests/fixtures/store-v03-preprior/IDEAS.md`: build material: tests, fixtures, CI, tooling, 645 bytes, 162 tokens
- `tests/fixtures/store-v03-preprior/history/backlog/r1.md`: build material: tests, fixtures, CI, tooling, 1.3 KB, 328 tokens
- `tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/metadata/c8ec69b5c99a05c1685a2fe143ffbb9372a3f113316434bb590e26d49d37112e.md`: build material: tests, fixtures, CI, tooling, 23.9 KB, 6,126 tokens
- `tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r1.md`: build material: tests, fixtures, CI, tooling, 2.3 KB, 599 tokens
- `tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r2.md`: build material: tests, fixtures, CI, tooling, 2.8 KB, 716 tokens
- `tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r3.md`: build material: tests, fixtures, CI, tooling, 3.8 KB, 972 tokens
- `tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r4.md`: build material: tests, fixtures, CI, tooling, 5.7 KB, 1,450 tokens
- `tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r5.md`: build material: tests, fixtures, CI, tooling, 8.4 KB, 2,151 tokens
- `tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r6.md`: build material: tests, fixtures, CI, tooling, 9.2 KB, 2,359 tokens
- `tests/fixtures/store-v03-preprior/history/idea_85f69bb3fc63423ea8a6dde2c86a62cd/r7.md`: build material: tests, fixtures, CI, tooling, 11.7 KB, 3,007 tokens
- `tests/fixtures/store-v03-preprior/idea_85f69bb3fc63423ea8a6dde2c86a62cd.md`: build material: tests, fixtures, CI, tooling, 27.3 KB, 6,992 tokens
- `tests/fixtures/store-v03-preprior/session-recovery/session_1331fc315b8b43ab918762cc8fc35032.json`: build material: tests, fixtures, CI, tooling, 9.8 KB, 2,520 tokens
- `tests/fixtures/store-v03-preprior/session-recovery/session_2b3d87b39c434b35b5fbbeb4dff2c545.json`: build material: tests, fixtures, CI, tooling, 104 bytes, 26 tokens
- `tests/fixtures/store-v03-preprior/session-recovery/session_4f9ce081fbbd477b9b1580136f14464e.json`: build material: tests, fixtures, CI, tooling, 582 bytes, 146 tokens
- `tests/fixtures/store-v2/IDEAS.md`: build material: tests, fixtures, CI, tooling, 705 bytes, 177 tokens
- `tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r1.md`: build material: tests, fixtures, CI, tooling, 1.6 KB, 411 tokens
- `tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r2.md`: build material: tests, fixtures, CI, tooling, 2.0 KB, 518 tokens
- `tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r3.md`: build material: tests, fixtures, CI, tooling, 2.9 KB, 750 tokens
- `tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r4.md`: build material: tests, fixtures, CI, tooling, 3.7 KB, 946 tokens
- `tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r5.md`: build material: tests, fixtures, CI, tooling, 4.4 KB, 1,116 tokens
- `tests/fixtures/store-v2/history/idea_11111111111111111111111111111111/r6.md`: build material: tests, fixtures, CI, tooling, 5.9 KB, 1,501 tokens
- `tests/fixtures/store-v2/history/idea_22222222222222222222222222222222/r1.md`: build material: tests, fixtures, CI, tooling, 1.6 KB, 421 tokens
- `tests/fixtures/store-v2/history/idea_22222222222222222222222222222222/r2.md`: build material: tests, fixtures, CI, tooling, 2.1 KB, 528 tokens
- `tests/fixtures/store-v2/idea_11111111111111111111111111111111.md`: build material: tests, fixtures, CI, tooling, 12.3 KB, 3,158 tokens
- `tests/fixtures/store-v2/idea_22222222222222222222222222222222.md`: build material: tests, fixtures, CI, tooling, 4.8 KB, 1,238 tokens
- `tests/hermetic_cli.py`: build material: tests, fixtures, CI, tooling, 1.1 KB, 276 tokens
- `tests/native_probe.py`: build material: tests, fixtures, CI, tooling, 24.8 KB, 6,348 tokens
- `tests/test_activity_log.py`: build material: tests, fixtures, CI, tooling, 2.8 KB, 715 tokens
- `tests/test_agent_bridge.py`: build material: tests, fixtures, CI, tooling, 46.6 KB, 11,927 tokens
- `tests/test_agent_cli.py`: build material: tests, fixtures, CI, tooling, 6.2 KB, 1,581 tokens
- `tests/test_agent_client.py`: build material: tests, fixtures, CI, tooling, 14.8 KB, 3,778 tokens
- `tests/test_agent_idle_fill.py`: build material: tests, fixtures, CI, tooling, 4.4 KB, 1,137 tokens
- `tests/test_agent_launch.py`: build material: tests, fixtures, CI, tooling, 37.8 KB, 9,682 tokens
- `tests/test_agent_lease_after_supersede.py`: build material: tests, fixtures, CI, tooling, 4.2 KB, 1,066 tokens
- `tests/test_agent_lease_while_composing.py`: build material: tests, fixtures, CI, tooling, 3.3 KB, 843 tokens
- `tests/test_agent_memory.py`: build material: tests, fixtures, CI, tooling, 13.1 KB, 3,361 tokens
- `tests/test_agent_policy.py`: build material: tests, fixtures, CI, tooling, 20.5 KB, 5,251 tokens
- `tests/test_agent_resume.py`: build material: tests, fixtures, CI, tooling, 19.8 KB, 5,063 tokens
- `tests/test_agent_source.py`: build material: tests, fixtures, CI, tooling, 28.4 KB, 7,275 tokens
- `tests/test_agent_transport.py`: build material: tests, fixtures, CI, tooling, 20.1 KB, 5,143 tokens
- `tests/test_agent_v3_protocol.py`: build material: tests, fixtures, CI, tooling, 6.2 KB, 1,600 tokens
- `tests/test_assessment.py`: build material: tests, fixtures, CI, tooling, 30.3 KB, 7,749 tokens
- `tests/test_assessment_source.py`: build material: tests, fixtures, CI, tooling, 25.8 KB, 6,609 tokens
- `tests/test_asset_agent_door.py`: build material: tests, fixtures, CI, tooling, 7.4 KB, 1,895 tokens
- `tests/test_asset_evidence.py`: build material: tests, fixtures, CI, tooling, 19.6 KB, 5,029 tokens
- `tests/test_asset_links.py`: build material: tests, fixtures, CI, tooling, 20.0 KB, 5,108 tokens
- `tests/test_asset_modes.py`: build material: tests, fixtures, CI, tooling, 2.0 KB, 518 tokens
- `tests/test_asset_projection.py`: build material: tests, fixtures, CI, tooling, 13.5 KB, 3,456 tokens
- `tests/test_asset_store.py`: build material: tests, fixtures, CI, tooling, 27.4 KB, 7,005 tokens
- `tests/test_assets.py`: build material: tests, fixtures, CI, tooling, 54.1 KB, 13,863 tokens
- `tests/test_brand_static.py`: build material: tests, fixtures, CI, tooling, 2.0 KB, 501 tokens
- `tests/test_bridge.py`: build material: tests, fixtures, CI, tooling, 60.9 KB, 15,592 tokens
- `tests/test_bridge_control.py`: build material: tests, fixtures, CI, tooling, 9.8 KB, 2,504 tokens
- `tests/test_chain.py`: build material: tests, fixtures, CI, tooling, 9.1 KB, 2,336 tokens
- `tests/test_chain_cli.py`: build material: tests, fixtures, CI, tooling, 4.6 KB, 1,172 tokens
- `tests/test_chain_fixtures.py`: build material: tests, fixtures, CI, tooling, 3.1 KB, 802 tokens
- `tests/test_chain_store.py`: build material: tests, fixtures, CI, tooling, 7.5 KB, 1,908 tokens
- `tests/test_chain_store_held_edit.py`: build material: tests, fixtures, CI, tooling, 7.3 KB, 1,871 tokens
- `tests/test_chain_v2.py`: build material: tests, fixtures, CI, tooling, 14.4 KB, 3,696 tokens
- `tests/test_cli_service.py`: build material: tests, fixtures, CI, tooling, 18.6 KB, 4,753 tokens
- `tests/test_discovery_exploration.py`: build material: tests, fixtures, CI, tooling, 21.6 KB, 5,522 tokens
- `tests/test_encode_state_unchanged.py`: build material: tests, fixtures, CI, tooling, 5.8 KB, 1,483 tokens
- `tests/test_exploration_method.py`: build material: tests, fixtures, CI, tooling, 20.8 KB, 5,314 tokens
- `tests/test_external_edits.py`: build material: tests, fixtures, CI, tooling, 13.1 KB, 3,362 tokens
- `tests/test_fixed_ports.py`: build material: tests, fixtures, CI, tooling, 15.9 KB, 4,068 tokens
- `tests/test_fixed_prototype_port.py`: build material: tests, fixtures, CI, tooling, 9.9 KB, 2,543 tokens
- `tests/test_fragment_pairing.py`: build material: tests, fixtures, CI, tooling, 5.4 KB, 1,380 tokens
- `tests/test_hand_release.py`: build material: tests, fixtures, CI, tooling, 8.1 KB, 2,072 tokens
- `tests/test_handoff.py`: build material: tests, fixtures, CI, tooling, 23.2 KB, 5,952 tokens
- `tests/test_handoff_evidence.py`: build material: tests, fixtures, CI, tooling, 17.9 KB, 4,594 tokens
- `tests/test_handoff_links.py`: build material: tests, fixtures, CI, tooling, 12.9 KB, 3,310 tokens
- `tests/test_handoff_service.py`: build material: tests, fixtures, CI, tooling, 15.2 KB, 3,895 tokens
- `tests/test_handoff_store.py`: build material: tests, fixtures, CI, tooling, 39.1 KB, 10,005 tokens
- `tests/test_hermetic_config.py`: build material: tests, fixtures, CI, tooling, 4.1 KB, 1,040 tokens
- `tests/test_idea.py`: build material: tests, fixtures, CI, tooling, 21.7 KB, 5,566 tokens
- `tests/test_import_cli.py`: build material: tests, fixtures, CI, tooling, 5.2 KB, 1,325 tokens
- `tests/test_import_idea.py`: build material: tests, fixtures, CI, tooling, 24.7 KB, 6,332 tokens
- `tests/test_install.py`: build material: tests, fixtures, CI, tooling, 22.8 KB, 5,846 tokens
- `tests/test_late_pairing_keeps_agent.py`: build material: tests, fixtures, CI, tooling, 4.3 KB, 1,105 tokens
- `tests/test_launch.py`: build material: tests, fixtures, CI, tooling, 18.4 KB, 4,700 tokens
- `tests/test_launcher_cli.py`: build material: tests, fixtures, CI, tooling, 18.0 KB, 4,615 tokens
- `tests/test_legacy_prior_art.py`: build material: tests, fixtures, CI, tooling, 4.6 KB, 1,170 tokens
- `tests/test_link_mode.py`: build material: tests, fixtures, CI, tooling, 11.8 KB, 3,030 tokens
- `tests/test_link_mode_cli.py`: build material: tests, fixtures, CI, tooling, 11.5 KB, 2,932 tokens
- `tests/test_markdown.py`: build material: tests, fixtures, CI, tooling, 32.8 KB, 8,395 tokens
- `tests/test_markdown_store.py`: build material: tests, fixtures, CI, tooling, 16.6 KB, 4,256 tokens
- `tests/test_middle_flow.py`: build material: tests, fixtures, CI, tooling, 45.4 KB, 11,628 tokens
- `tests/test_migration.py`: build material: tests, fixtures, CI, tooling, 16.5 KB, 4,221 tokens
- `tests/test_move_cli.py`: build material: tests, fixtures, CI, tooling, 25.4 KB, 6,495 tokens
- `tests/test_move_store.py`: build material: tests, fixtures, CI, tooling, 21.9 KB, 5,612 tokens
- `tests/test_native.py`: build material: tests, fixtures, CI, tooling, 8.6 KB, 2,210 tokens
- `tests/test_native_probe.py`: build material: tests, fixtures, CI, tooling, 13.2 KB, 3,384 tokens
- `tests/test_navigation.py`: build material: tests, fixtures, CI, tooling, 9.7 KB, 2,481 tokens
- `tests/test_orca_pages_prune.py`: build material: tests, fixtures, CI, tooling, 5.1 KB, 1,308 tokens
- `tests/test_own_fills_reply.py`: build material: tests, fixtures, CI, tooling, 5.3 KB, 1,351 tokens
- `tests/test_platform.py`: build material: tests, fixtures, CI, tooling, 11.7 KB, 2,995 tokens
- `tests/test_port_config_contract.py`: build material: tests, fixtures, CI, tooling, 7.9 KB, 2,011 tokens
- `tests/test_proposal_evidence.py`: build material: tests, fixtures, CI, tooling, 15.5 KB, 3,961 tokens
- `tests/test_proposal_links.py`: build material: tests, fixtures, CI, tooling, 11.5 KB, 2,951 tokens
- `tests/test_proposal_store.py`: build material: tests, fixtures, CI, tooling, 19.1 KB, 4,879 tokens
- `tests/test_prototype_road.py`: build material: tests, fixtures, CI, tooling, 9.3 KB, 2,390 tokens
- `tests/test_prototype_server.py`: build material: tests, fixtures, CI, tooling, 9.7 KB, 2,496 tokens
- `tests/test_rebuilt_tab_repair.py`: build material: tests, fixtures, CI, tooling, 12.8 KB, 3,266 tokens
- `tests/test_remove_cli.py`: build material: tests, fixtures, CI, tooling, 4.3 KB, 1,095 tokens
- `tests/test_remove_idea.py`: build material: tests, fixtures, CI, tooling, 26.9 KB, 6,886 tokens
- `tests/test_remove_idea_in_use.py`: build material: tests, fixtures, CI, tooling, 9.3 KB, 2,393 tokens
- `tests/test_restore_parks_orphaned_session.py`: build material: tests, fixtures, CI, tooling, 7.5 KB, 1,918 tokens
- `tests/test_resume_closes_old_tab.py`: build material: tests, fixtures, CI, tooling, 4.4 KB, 1,138 tokens
- `tests/test_runtime.py`: build material: tests, fixtures, CI, tooling, 35.1 KB, 8,989 tokens
- `tests/test_runtime_identity.py`: build material: tests, fixtures, CI, tooling, 5.2 KB, 1,334 tokens
- `tests/test_runtime_root_fallback.py`: build material: tests, fixtures, CI, tooling, 3.5 KB, 889 tokens
- `tests/test_service.py`: build material: tests, fixtures, CI, tooling, 17.9 KB, 4,571 tokens
- `tests/test_service_start_warms_store.py`: build material: tests, fixtures, CI, tooling, 2.6 KB, 676 tokens
- `tests/test_session_security.py`: build material: tests, fixtures, CI, tooling, 17.1 KB, 4,388 tokens
- `tests/test_session_slots.py`: build material: tests, fixtures, CI, tooling, 21.4 KB, 5,474 tokens
- `tests/test_session_superseded.py`: build material: tests, fixtures, CI, tooling, 3.9 KB, 993 tokens
- `tests/test_session_verbs.py`: build material: tests, fixtures, CI, tooling, 7.1 KB, 1,821 tokens
- `tests/test_shared_store_modes.py`: build material: tests, fixtures, CI, tooling, 7.4 KB, 1,884 tokens
- `tests/test_skill_text.py`: build material: tests, fixtures, CI, tooling, 18.5 KB, 4,742 tokens
- `tests/test_ssh_mode.py`: build material: tests, fixtures, CI, tooling, 41.0 KB, 10,508 tokens
- `tests/test_store_load_cache.py`: build material: tests, fixtures, CI, tooling, 8.2 KB, 2,098 tokens
- `tests/test_store_requests.py`: build material: tests, fixtures, CI, tooling, 20.7 KB, 5,303 tokens
- `tests/test_store_write_then_read_warm.py`: build material: tests, fixtures, CI, tooling, 2.5 KB, 645 tokens
- `tests/test_tab_secret.py`: build material: tests, fixtures, CI, tooling, 6.3 KB, 1,618 tokens
- `tests/test_tern_plugin.py`: build material: tests, fixtures, CI, tooling, 5.4 KB, 1,393 tokens
- `tests/test_transactions.py`: build material: tests, fixtures, CI, tooling, 31.1 KB, 7,973 tokens
- `tests/test_tunnel_probe.py`: build material: tests, fixtures, CI, tooling, 6.7 KB, 1,728 tokens
- `tests/test_two_sessions.py`: build material: tests, fixtures, CI, tooling, 25.2 KB, 6,445 tokens
- `tests/test_visualize_step.py`: build material: tests, fixtures, CI, tooling, 15.4 KB, 3,937 tokens
- `tests/test_web_assets.py`: build material: tests, fixtures, CI, tooling, 33.1 KB, 8,475 tokens
- `tests/test_workflow.py`: build material: tests, fixtures, CI, tooling, 31.0 KB, 7,927 tokens
- `tests/test_workflow_api.py`: build material: tests, fixtures, CI, tooling, 7.6 KB, 1,946 tokens
- `tests/test_workflow_schema.py`: build material: tests, fixtures, CI, tooling, 20.5 KB, 5,250 tokens
- `tests/web/accept-reasons.test.mjs`: build material: tests, fixtures, CI, tooling, 13.2 KB, 3,369 tokens
- `tests/web/app-render.test.mjs`: build material: tests, fixtures, CI, tooling, 35.9 KB, 9,181 tokens
- `tests/web/assess-clarity.test.mjs`: build material: tests, fixtures, CI, tooling, 8.1 KB, 2,071 tokens
- `tests/web/assess.test.mjs`: build material: tests, fixtures, CI, tooling, 27.6 KB, 7,062 tokens
- `tests/web/assessment-controller.test.mjs`: build material: tests, fixtures, CI, tooling, 21.6 KB, 5,536 tokens
- `tests/web/attachment-api.test.mjs`: build material: tests, fixtures, CI, tooling, 10.4 KB, 2,655 tokens
- `tests/web/backlog.test.mjs`: build material: tests, fixtures, CI, tooling, 18.7 KB, 4,776 tokens
- `tests/web/binding.test.mjs`: build material: tests, fixtures, CI, tooling, 42.5 KB, 10,880 tokens
- `tests/web/capture-attachments.test.mjs`: build material: tests, fixtures, CI, tooling, 16.4 KB, 4,193 tokens
- `tests/web/conversation.test.mjs`: build material: tests, fixtures, CI, tooling, 36.2 KB, 9,256 tokens
- `tests/web/cp3-review-fixes.test.mjs`: build material: tests, fixtures, CI, tooling, 17.7 KB, 4,520 tokens
- `tests/web/discovery-proposals.test.mjs`: build material: tests, fixtures, CI, tooling, 24.2 KB, 6,190 tokens
- `tests/web/discovery.test.mjs`: build material: tests, fixtures, CI, tooling, 7.2 KB, 1,845 tokens
- `tests/web/exploration-proposals.test.mjs`: build material: tests, fixtures, CI, tooling, 31.6 KB, 8,088 tokens
- `tests/web/exploration.test.mjs`: build material: tests, fixtures, CI, tooling, 12.7 KB, 3,251 tokens
- `tests/web/folds.test.mjs`: build material: tests, fixtures, CI, tooling, 34.8 KB, 8,907 tokens
- `tests/web/handoff-api.test.mjs`: build material: tests, fixtures, CI, tooling, 18.3 KB, 4,683 tokens
- `tests/web/handoff-controller.test.mjs`: build material: tests, fixtures, CI, tooling, 29.4 KB, 7,530 tokens
- `tests/web/handoff.test.mjs`: build material: tests, fixtures, CI, tooling, 25.3 KB, 6,480 tokens
- `tests/web/idea-markdown-api.test.mjs`: build material: tests, fixtures, CI, tooling, 3.0 KB, 779 tokens
- `tests/web/locks.test.mjs`: build material: tests, fixtures, CI, tooling, 9.6 KB, 2,452 tokens
- `tests/web/method-cards.test.mjs`: build material: tests, fixtures, CI, tooling, 6.1 KB, 1,569 tokens
- `tests/web/method.test.mjs`: build material: tests, fixtures, CI, tooling, 17.4 KB, 4,451 tokens
- `tests/web/moved-ideas.test.mjs`: build material: tests, fixtures, CI, tooling, 5.1 KB, 1,311 tokens
- `tests/web/pairing.test.mjs`: build material: tests, fixtures, CI, tooling, 5.6 KB, 1,447 tokens
- `tests/web/plain-words.test.mjs`: build material: tests, fixtures, CI, tooling, 4.5 KB, 1,148 tokens
- `tests/web/prior-art.test.mjs`: build material: tests, fixtures, CI, tooling, 13.0 KB, 3,334 tokens
- `tests/web/proposals.test.mjs`: build material: tests, fixtures, CI, tooling, 44.4 KB, 11,371 tokens
- `tests/web/rerank-api.test.mjs`: build material: tests, fixtures, CI, tooling, 2.4 KB, 612 tokens
- `tests/web/review-summary.test.mjs`: build material: tests, fixtures, CI, tooling, 9.4 KB, 2,418 tokens
- `tests/web/selected-state.test.mjs`: build material: tests, fixtures, CI, tooling, 2.3 KB, 592 tokens
- `tests/web/setup.test.mjs`: build material: tests, fixtures, CI, tooling, 17.2 KB, 4,401 tokens
- `tests/web/upload-api.test.mjs`: build material: tests, fixtures, CI, tooling, 12.6 KB, 3,230 tokens
- `tests/web/visualize-controller.test.mjs`: build material: tests, fixtures, CI, tooling, 14.1 KB, 3,620 tokens
- `tests/web/visualize.test.mjs`: build material: tests, fixtures, CI, tooling, 54.2 KB, 13,882 tokens
- `capability.json`: nothing points to it, 360 bytes, 90 tokens
- `config.example.json`: nothing points to it, 163 bytes, 41 tokens
- `glitch-idea/PyYAML-MIT-NOTICE.txt`: nothing points to it, 1.4 KB, 348 tokens
- `glitch-idea/agents/openai.yaml`: nothing points to it, 225 bytes, 57 tokens
- `glitch-idea/tern-plugin/plugin.toml`: nothing points to it, 178 bytes, 45 tokens
- `glitch-idea/tern-plugin/window.luau`: nothing points to it, 7.7 KB, 1,971 tokens
- `glitch-idea/web/assets/bwpm/bundle.css`: nothing points to it, 13.5 KB, 3,454 tokens
- `glitch-idea/web/assets/fonts/BlastworksSans-ExtraBold.woff2`: nothing points to it, 25.5 KB, not text
- `glitch-idea/web/assets/fonts/BlastworksSans-Regular.woff2`: nothing points to it, 23.6 KB, not text
- `glitch-idea/web/assets/fonts/BlastworksSans-SemiBold.woff2`: nothing points to it, 25.6 KB, not text
- `glitch-idea/web/assets/fonts/BlastworksSans-UNLICENSE.txt`: nothing points to it, 1.2 KB, 303 tokens
- `glitch-idea/web/assets/logo.svg`: nothing points to it, 8.7 KB, 2,225 tokens
- `glitch-idea/web/index.html`: nothing points to it, 2.6 KB, 666 tokens
- `glitch-idea/web/styles.css`: nothing points to it, 29.0 KB, 7,430 tokens
- `src/.gitkeep`: nothing points to it, 0 bytes, 0 tokens

### Agent and command posture (0)

None.

### Stated limits: read-only wording a model reads, and what backs it (9)

- glitch-idea/SKILL.md:160: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` Run the bounded memory retrieval (when no other memory capability is available, a read-only `list` of this store's own ideas, with their accepted methods, is an acceptable bounded retrieval) and send a method memory fill only: `fields: {"memory": {status, sources, rationale, preferred_method}}`. `preferred_method` is one of the four method ids and is REQUIRED when `status` is `found`; otherwise it is null. Never select, fill or favour a method beyond that memory line: the operator picks one of the four equal cards and writes any reason themselves. The memory status is one of `found` (with `preferred_method`), `varied` (all four in use), `searched_no_preference`, `unavailable` or `error`. Never send `selection` or `reason`. Recommend only when the operator asks in the terminal for a method: one recommendation with its reason, in the terminal only, never in a fill. Unasked, lay out nothing beyond the memory line. ``
- glitch-idea/SKILL.md:220: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` Review sends no request: there is nothing to fill or answer. After the planning prompt the service may end; `agent_unavailable` there means the run is over, not an error. To tell that end from a failure: once Assess is accepted the next `events` may return `agent_unavailable`; do a read-only `show` of the idea. If `workflow.current_step` is `review` and `workflow.steps.assess.acceptance` is set, the run is over: say the review is ready, give no further command, and stop. Otherwise follow the stop list. ``
- glitch-idea/SKILL.md:260: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` **Read-only after the move.** A moved or delivered idea answers `show` and `list`, but every mutation (`exploration` including a next slice, `rate`, `assess`, `propose`, `place`, `handoff`, `record-execution` and browser saves) is refused `idea_moved` with the home in its details. ``
- glitch-idea/references/commands.md:50: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` `--reconnect` reads the pairing mark of the page recorded for that binding (`orca eval`, read-only). Only a page marked unpaired is touched: the service retires its browser credentials and issues a fresh one-time code for the same agent generation, and `orca goto --page` loads `<origin>/#pair=<code>` into that same page, which pairs itself. No tab is created or closed, the agent keeps its credential and lease, and the code is never printed. A paired page returns `browser.reconnected: false` with `reason: tab_still_paired`, and a page still loading returns `tab_not_unpaired`; neither changes anything. `tab_not_recorded` (no Orca page recorded for the binding) and `tab_unreadable` (Orca could not read it, for example the operator closed it) change nothing either: say so in one line and use `--resume` only on the operator's word. `--reconnect` is Orca-only and refuses `--resume`, `--idea-id` and the system browser (`usage`). ``
- glitch-idea/references/commands.md:132: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` Review sends no request; after the planning prompt the service may end, and `agent_unavailable` there means the run is over, not an error. To tell that end from a failure: once Assess is accepted the next `events` may return `agent_unavailable`; a read-only `show` of the idea with `workflow.current_step` `review` and `workflow.steps.assess.acceptance` set means the run is over; otherwise follow the stop list in SKILL.md. ``
- glitch-idea/references/commands.md:144: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` `sessions` is read-only and prints `{ok: true, sessions: [...]}`: one row per retained session with `binding_id`, `selected_idea_id`, `title` (the idea's text, at most 80 characters), `finished` (its Review step is saved) and `in_use` (a browser tab or terminal agent is still connected). ``
- glitch-idea/references/commands.md:259: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` `handoff` is read-only and needs complete Exploration, human ratings and an assessment. It returns the exact trace block and current revision for the planner. Preserve its values, outside the planner's closed `## Build choices` section: ``
- glitch-idea/references/commands.md:281: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` A moved or delivered idea is read-only from glitch-idea. `show` and `list` still work and carry `lifecycle` (`active`, `moved` or `delivered`), `home` and `delivered_ref`; `list` also has a `lifecycles` map. Every mutation (`exploration` including a next slice, `rate`, `assess`, `propose`, `place`, `handoff`, `record-execution`, browser saves) is refused `idea_moved` with `details.home`. The browser bridge answers 409 for `idea_moved`, `not_moved` and `delivery_conflict`. From the move on, next slices happen in the project. ``
- glitch-idea/references/commands.md:324: stated; Stated in the text; Walkdown found no tool setting that enforces it (glitch-idea/SKILL.md has no tools list). `` An immutable tombstone `history/removed/<id>.md` (`<id>.2.md`, `<id>.3.md` … when the same idea was imported again and removed again) is written in the same publish, sealed read-only (0400, or 0440 in a shared store): idea id, actor, time, first words and a manifest of the removed paths with their sha256. ``

### Pairs: Test data a model-read file references directly (3)

- tests/fixtures/markdown/IDEAS.md: referenced from glitch-idea/SKILL.md
- tests/fixtures/store-v03-preprior/IDEAS.md: referenced from glitch-idea/SKILL.md
- tests/fixtures/store-v2/IDEAS.md: referenced from glitch-idea/SKILL.md

### Pairs: Image a model-read file points at (1)

- glitch-idea/web/assets/logo.svg: referenced from glitch-idea/web/index.html; text: svg

### Pairs: Orphan with a phrase hit (28)

- docs/acceptance-browser-flow.md:73: phrase.creds [creds.desktop]: `` 12. Complete the handoff: in Review, choose **Copy planning prompt** with the clipboard permission granted, confirm the clipboard holds exactly the generated prompt, write a minimal real plan carrying its `## Idea trace`, run `register-plan`, and confirm the idea is archived at that revision and `doctor` is healthy. ``
- docs/acceptance-browser-flow.md:142: phrase.I.conditional [I.failure-path]: `` If the error is `origin_missing` or `usage`, no session exists: correct the arguments and rerun without `--resume`. ``
- docs/acceptance-browser-flow.md:158: phrase.K.exfil [K.data-flow]: `Evidence to record: the Orca version, local operating system, the remote host's operating system, the commit, the tunnel command (without credentials), a screenshot per numbered step, the upload file names and sizes, and each error code observed.`
- docs/asset-format.md:7: phrase.J.prohibited [J.confirm-first]: `` Streams use generated `assets/staging/<upload_id>.<nonce>.part`; complete bytes publish immutably at `assets/blobs/<asset_id>.bin`, all on the Store filesystem. Upload display names never select a path. Every path component, root and ancestor must be a real directory/regular file, never a symlink, special file or foreign-device path. The browser selects opaque IDs only. ``
- docs/asset-format.md:11: phrase.J.prohibited [J.confirm-first]: `An upload intent and its request receipt publish together. Network streaming never holds a Store lock. Flush and publish the immutable blob first; then rehash and register complete evidence/detail links and receipt atomically through Store's recoverable transaction. A crash before registration leaves an orphan, never a completed upload. Completed stages are sealed read-only and owner-only (0400, with stages created 0600 and asset directories 0700) before exclusive hardlink blob publication. A retained stage whose generated upload ID and verified read-only inode match the completed blob is a retained success, excluded from orphan diagnostics. Failed, interrupted or unmatched stages and unlinked blobs remain reported orphans; no automatic deletion. Replays return the original receipt before business/CAS checks. Same identity with different bytes refuses. Linked missing/corrupt evidence or blobs fail closed.`
- docs/asset-format.md:40: phrase.H.anti-review [H.sabotage]: `records must name the active request session. This supersedes the unreleased`
- docs/browser-api.md:11: phrase.creds [creds.desktop]: `` All application routes are under `/api/v1/`. Reads require a browser session ``
- docs/browser-api.md:49: phrase.K.exfil [K.data-flow]: `` from the address bar with `history.replaceState` before anything else, and\nredeems the code through `POST /pair` itself; the operator types nothing. ``
- docs/browser-api.md:53: phrase.H.anti-review [H.self-attest]: `because the code is one-time and short-lived; domain Markdown still contains no`
- docs/browser-api.md:69: phrase.K.exfil [K.data-flow]: `` persistent storage, never logged or put in a URL) and sends it as the\n`X-Idea-Tab` header on every `/api/v1/*` call, including `GET /session`. Cookies\nare not port-scoped, so another listener on the same loopback address could ``
- docs/browser-api.md:225: phrase.H.anti-review [H.anti-inspect]: `workspace is trusted resolution or service-host validated explicit selection;`
- docs/browser-api.md:255: phrase.H.anti-review [H.suppress]: `snapshot; it does not silently change the legacy snapshot keys.`
- docs/browser-api.md:419: phrase.B.defs [B.safety-adjective]: `` A moved or delivered idea is read-only: every browser save for it is refused `idea_moved` (409) with `details.home`. ``
- docs/browser-api.md:436: phrase.H.anti-review [H.sabotage]: `usual; the operator accepts. Opening another step's conversation supersedes an`
- docs/browser-api.md:445: phrase.B.defs [B.safety-adjective]: `` The reply is `{ok, code, idea_id, step, hand, released, write_state, revision, draft_version}`, with `released` the number of requests cancelled; the call is idempotent. ``
- docs/browser-api.md:479: phrase.creds [creds.secret-name]: `` `X-Idea-Agent-Binding`, `X-Idea-Agent-Generation` and Bearer authorization headers. ``
- docs/browser-api.md:482: phrase.creds [creds.secret-name]: `refused on every non-agent route; Bearer authorization is accepted only on the`
- docs/browser-api.md:589: phrase.B.defs [B.means]: `result and state reads against this identity; a missing receipt never means a\ncompleted upload. An explicit same-upload retry hashes the supplied bytes. The`
- docs/browser-api.md:671: phrase.H.anti-review [H.evidence]: `rows; removing a local row does not delete retained Store history. Explicit`
- docs/browser-api.md:732: phrase.B.defs [B.safety-adjective]: `` retains current answers and reports `session_persistence_failed`. Reads/Open\n  must not clear unsaved buffers or ambiguous requests implicitly. Selection\n  is idempotent and updates no accepted/draft/backlog counter. Do not add a new ``
- docs/browser-api.md:738: phrase.creds [creds.desktop]: `app. Review/Ideas render names, paths and prompts as text. Copy checks server\nreadiness plus local dirty/pending state; successful clipboard write returns to`
- docs/browser-api.md:807: phrase.B.defs [B.safety-adjective]: `` The app loads six fixed literal modules, including `/ideas.js`; missing HTTP404\nalone means unavailable. Review shows accepted summaries and the full read-only ``
- docs/browser-api.md:809: phrase.creds [creds.desktop]: `prompt as text. Copy checks currentness before clipboard write and again after`
- docs/cp2-validation.md:58: phrase.H.anti-review [H.suppress]: `it does not silently drop the link or discard the human draft.`
- docs/orca-contract.md:30: phrase.H.anti-review [H.self-attest]: `contains no credentials, private host identifiers or personal ideas. The local`
- docs/orca-contract.md:75: phrase.I.conditional [I.state]: `Output contains only the non-secret loopback URL and initial session ID. The`
- docs/orca-contract.md:265: phrase.H.anti-review [H.sabotage]: `This supersedes any inference that the earlier single-process five-wait test`
- docs/orca-contract.md:370: phrase.H.anti-review [H.sabotage]: `This supersedes the earlier unobserved/refused Claude compaction rows. After`

### Pairs: Hidden text with a phrase hit (0)

None.

### Pairs: Load-only file with a phrase hit (20)

- glitch-idea/scripts/idea_service.py:15: phrase.E.perms [E.exec-primitive]: `import subprocess`
- glitch-idea/scripts/idea_service.py:750: phrase.E.perms [E.exec-primitive]: `result=subprocess.run(fixed,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,timeout=config['validator_timeout_seconds'],check=False)`
- glitch-idea/scripts/idea_service.py:755: phrase.E.perms [E.exec-primitive]: `except subprocess.TimeoutExpired as exc:`
- glitch-idea/scripts/idea_steps/method.py:4: phrase.E.env [E.memory]: `checks memory/proposal provenance before this pure handler. The human may choose`
- glitch-idea/scripts/idea_store.py:203: phrase.K.exfil [K.assembly-code]: `validate_record(_agent_record(evidence,actor,'proposal_'+'0'*32,'validation-only'))`
- glitch-idea/scripts/idea_store.py:1519: phrase.J.prohibited [J.confirm-first]: `# Fresh physical inventory plus new immutable evidence, before publish.`
- glitch-idea/scripts/idea_store.py:1540: phrase.J.prohibited [J.confirm-first]: `self._load_cache = None  # any publish attempt invalidates the remembered load`
- glitch-idea/scripts/idea_store.py:1553: phrase.J.prohibited [J.confirm-first]: `result = transactions.publish(self.path, combined, expected, freeze_legacy=True,`
- glitch-idea/scripts/idea_store.py:1562: phrase.J.prohibited [J.confirm-first]: `result = transactions.publish(self.path, combined, expected, move_out=move_out, removals=removals)`
- glitch-idea/scripts/idea_store.py:1642: phrase.J.prohibited [J.confirm-first]: `require(not context.get('request_running'), 'Request mutators cannot publish or perform I/O', 'invalid_transaction')`
- glitch-idea/scripts/idea_store.py:1719: phrase.J.prohibited [J.confirm-first]: `publish: the files, the idea appended last in order, and one placement`
- glitch-idea/scripts/idea_store.py:1853: phrase.J.prohibited [J.confirm-first]: `# Once the journaled publish may have committed, the evidence names these blobs: they stay.`
- glitch-idea/scripts/idea_store.py:1996: phrase.J.prohibited [J.confirm-first]: `"""Remove one idea and everything it owns, for good, in one journaled publish.`
- glitch-idea/scripts/idea_store.py:1998: phrase.L.override [L.skip-confirm]: `Without confirm: a preview and nothing written. With confirm, under the`
- glitch-idea/scripts/idea_store.py:2181: phrase.J.prohibited [J.confirm-first]: `require(not context.get('request_running'), 'Request mutators cannot publish or perform I/O', 'invalid_transaction')`
- glitch-idea/scripts/idea_store.py:2217: phrase.J.prohibited [J.confirm-first]: `require(not context.get('request_running'), 'Request mutators cannot publish or perform I/O', 'invalid_transaction')`
- glitch-idea/scripts/idea_store.py:2278: phrase.J.prohibited [J.confirm-first]: `Neither callback may wait/read network, read files or publish. The business`
- glitch-idea/scripts/idea_store.py:2615: phrase.J.prohibited [J.confirm-first]: `"""Publish suggestion/link/receipt under an existing binding->Store guard.`
- glitch-idea/scripts/idea_store.py:2618: phrase.J.prohibited [J.confirm-first]: `trusted pure code, returning the exact checked source on first publish;`
- glitch-idea/web/assets/fonts/BlastworksSans-UNLICENSE.txt:3: phrase.J.prohibited [J.confirm-first]: `Anyone is free to copy, modify, publish, use, compile, sell, or`

### Pairs: Instruction in a script a context-injecting hook runs (0)

None.

### Do the tools fit the job

Entries checked: 1 (0 with a tools list, 0 agents with none). The yardstick is each entry's own words, over what it reads, against its own grants; families and hook facts are in `stages/05-capability/fit.yaml`, the cues in `stages/04-phrases/asks.yaml`.

Every tool granted is one the words ask for, and nothing asks for a tool it lacks.

## 6 Needs a human read

35 questions (33 labeling, 2 relational). Packet only: no model read (06-packet.md in the run folder).

Validation: PASS (gate 125/125, negative 11/11, recall 0/165; skipped: 124 rows; measured 2026-11-02, same code and fixtures)

Questions a pattern cannot settle, and the answers of the backends named here. Every answer is a located observation; none changes a finding in sections 1 to 5.

- no backend: packet only

### Questions

- glitch-idea/PyYAML-MIT-NOTICE.txt:13 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:53 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:58 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:59 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:132 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:160 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:202 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:203 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:204 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:220 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:232 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:234 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:243 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:260 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:264 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:3 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:23 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:50 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:64 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:77 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:132 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:134 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:143 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:144 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:162 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:197 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:259 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:281 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:283 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:302 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/references/commands.md:324 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/web/assets/fonts/BlastworksSans-UNLICENSE.txt:3 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/web/index.html:29 [label] Does this line tell the reader to do the matched action, tell them not to, describe it, or quote / give an example of it?
    - soft.label: skipped (no labeling backend)
- glitch-idea/SKILL.md:134 [relational] The same word is defined differently in these places. Which instructions elsewhere would read differently under each definition?
    - soft.read: skipped (no relational backend)
- (repo) [relational] Describe, as capability and not intent, how these three capabilities could combine in this artifact, citing the evidence given.
    - soft.read: skipped (no relational backend)

## 7 Not examined

- Stage 02-reader validation INCOMPLETE (gate 20/31, negative 22/24, recall 1/1; skipped: 13 rows; measured 2026-11-02, same code and fixtures): its zeros are not validated for the skipped checks.
- read.divergence skipped for docs/screenshots/01-capture.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for docs/screenshots/02-priorities.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for docs/screenshots/03-methods.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for docs/screenshots/04-discovery.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for docs/screenshots/05-exploration.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for docs/screenshots/06-visualize.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for docs/screenshots/07-assess.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for docs/screenshots/08-review.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for docs/screenshots/09-review-planning-prompt.png: tesseract not installed (no tesseract binary, no pytesseract)
- read.divergence skipped for glitch-idea/web/index.html: html not drawn (playwright not installed)
- (02-reader) tesseract not installed (no tesseract binary, no pytesseract): images and PDF pages are skipped for OCR (read.divergence skip); images and PDFs with no text layer are listed as read.unread
- (02-reader) html render: playwright not installed: HTML files are read with static style only (read.divergence skip, carrier rendered)
- (02-reader) v1 limit: the language check (read.language) reads prose only: Markdown, plain text, PDF, DOCX, and OCR text; Markdown code blocks, comments in code, config values, and HTML are not checked for language, and a paragraph under five words is too short to judge
- (03-graph) v1 limit: manifest versus disk compares skills, agents, and commands, and only the kinds a manifest names; a manifest that names none relies on its folders and is not compared, and plugins a marketplace leaves out are not compared
- (03-graph) graph incomplete by construction: 283 dynamic load(s); targets resolved as of review time only
- (04-phrases) limit: files that do not decode as text (PDF, DOCX, images) are scanned from stage 2's extracted text, phrase patterns only
- (04-phrases) not scanned: .gitignore: pattern list (not instruction text)
- (04-phrases) not scanned: docs/screenshots/01-capture.png: not text (image/png)
- (04-phrases) not scanned: docs/screenshots/02-priorities.png: not text (image/png)
- (04-phrases) not scanned: docs/screenshots/03-methods.png: not text (image/png)
- (04-phrases) not scanned: docs/screenshots/04-discovery.png: not text (image/png)
- (04-phrases) not scanned: docs/screenshots/05-exploration.png: not text (image/png)
- (04-phrases) not scanned: docs/screenshots/06-visualize.png: not text (image/png)
- (04-phrases) not scanned: docs/screenshots/07-assess.png: not text (image/png)
- (04-phrases) not scanned: docs/screenshots/08-review.png: not text (image/png)
- (04-phrases) not scanned: docs/screenshots/09-review-planning-prompt.png: not text (image/png)
- (04-phrases) not scanned: glitch-idea/web/assets/fonts/BlastworksSans-ExtraBold.woff2: not text (application/octet-stream)
- (04-phrases) not scanned: glitch-idea/web/assets/fonts/BlastworksSans-Regular.woff2: not text (application/octet-stream)
- (04-phrases) not scanned: glitch-idea/web/assets/fonts/BlastworksSans-SemiBold.woff2: not text (application/octet-stream)
- (05-capability) stage 5 limit: a Bash grant is recorded under private-data and as execute posture, never as external-comms; Bash can reach the network, as can every shell, so this map does not count it there
- (05-capability) stage 5 limit: hook bytes are an estimate from the sizes of files the hook script references (stage 3 static edges); hooks are never run to measure their output
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/01-capture.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/02-priorities.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/03-methods.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/04-discovery.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/05-exploration.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/06-visualize.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/07-assess.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/08-review.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence docs/screenshots/09-review-planning-prompt.png skipped (tesseract not installed (no tesseract binary, no pytesseract))
- (05-capability) carried forward from stage 02-reader: read.divergence glitch-idea/web/index.html skipped (html not drawn (playwright not installed))
- soft.label skipped for glitch-idea/PyYAML-MIT-NOTICE.txt: no labeling backend
- soft.label skipped for glitch-idea/SKILL.md: no labeling backend
- soft.label skipped for glitch-idea/references/commands.md: no labeling backend
- soft.label skipped for glitch-idea/web/assets/fonts/BlastworksSans-UNLICENSE.txt: no labeling backend
- soft.label skipped for glitch-idea/web/index.html: no labeling backend
- soft.read skipped for glitch-idea/SKILL.md: no relational backend
- soft.read skipped for None: no relational backend
- (06-soft) skipped: soft.label x33: no labeling backend
- (06-soft) skipped: soft.read x2: no relational backend
- Unread: docs/screenshots/01-capture.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: docs/screenshots/02-priorities.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: docs/screenshots/03-methods.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: docs/screenshots/04-discovery.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: docs/screenshots/05-exploration.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: docs/screenshots/06-visualize.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: docs/screenshots/07-assess.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: docs/screenshots/08-review.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: docs/screenshots/09-review-planning-prompt.png: image: no text layer; OCR not run (tesseract not installed (no tesseract binary, no pytesseract))
- Unread: glitch-idea/web/assets/fonts/BlastworksSans-ExtraBold.woff2: binary blob (does not decode as text)
- Unread: glitch-idea/web/assets/fonts/BlastworksSans-Regular.woff2: binary blob (does not decode as text)
- Unread: glitch-idea/web/assets/fonts/BlastworksSans-SemiBold.woff2: binary blob (does not decode as text)
- Unread: tests/test_assets.py: pdf parse error: PdfStreamError: Stream has ended unexpectedly
- Test data is recognized by folder and file name (tests, fixtures, test_*.py and the like): 181 stage 1 and 866 stage 4 findings there were kept out of the capability map and the summary. Test data that a model-read file references directly is listed in section 5.
- Static examination only. Nothing in the artifact was executed, fetched, or installed.
- Stage 6 answers are located observations from the backends section 6 names; they never change a stage 1 to 5 finding. Hit counts carry a benign share only when stage 6 labels ran.
- Version drift (class 8): each run examines one pinned copy. walkdown.py compares it with the previous run of the same repository when there is one (changes.md next to this report); what the artifact becomes after its next update is seen only by auditing it again.
- English-language scope: the phrase layer is blind to non-English text (stage 2 lists non-Latin runs, and prose passages in another language in Latin script; a short line can slip past that check).
- Stage 4 matches patterns; a payload phrased outside every pattern reads as no hit. A zero here is not safety.

## Recommendations

Conditional on what the skill is for. Unranked, in stage order. None: no finding matched a recommendation template.


What this is not: static examination only. "Clean" means these stages found nothing; it does not mean the artifact is safe. This report offers possible issues with evidence and reaches no verdict. What to do with it is yours to decide.
