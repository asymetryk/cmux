charter_version: 2
setup_complete: true
setup_completed_at: 2026-09-08
repository:
  name: cmux
  canonical_source: https://github.com/manaflow-ai/cmux
  branch: main
  feature_base: v0.64.22
  feature_base_commit: ddd4a01bc5d8ebac19643930f5fd7d40e85f1534
work_management:
  authority: OpenProject
  project_id: 56
  openproject_project: https://openproject.tail21f530.ts.net/projects/cmux
  openproject_wiki: https://openproject.tail21f530.ts.net/projects/cmux/wiki
  bootstrap_wiki_page: https://openproject.tail21f530.ts.net/projects/cmux/wiki/Bootstrap
  evidence_log: https://openproject.tail21f530.ts.net/projects/cmux/wiki/Bootstrap#evidence
  assumptions_log: https://openproject.tail21f530.ts.net/projects/cmux/wiki/Bootstrap#assumptions
  active_work_package: https://openproject.tail21f530.ts.net/work_packages/750
  status_mapping:
    Proposed: Submitted
    Ready: Approved for Dev
    In progress: Developing
    Validating: Validating
    Ready for Howard: Human Review Queue
    Tested: Approved for Merge
    Done: Merged
    Closed: Closed
collaboration:
  authority: Buzz
  buzz_channel: adbe0277-6829-486d-8935-db49d6421884
  channel_name: cmux
  active_thread: a7cf8ace783a791312a18f07866367d8ccfcb9b7df068a4e24e62bd66dcead7a
  policy: one thread per OpenProject work package
surface:
  primary_viewport: 1920x1080
  secondary_viewports: none
  browser: Chrome
  native_surface: tagged macOS cmux application
runtime:
  implementation_runtime: Kubernetes coding-agent-hq-runtime
  primary_uat_host: howards-macbook-pro-2
  primary_uat_runtime: native macOS arm64, Xcode 26.5
  uat_url_or_path: tagged minimax-read-aloud build on remote Mac
  uat_if_busy: spin_new
  localhost_default: false
  production_environment: installed cmux application
  promote_order: remote Mac tagged UAT -> human dogfood -> explicitly approved installation
  production_gate: explicit Howard approval after native functional and visual proof
routing:
  plan_review: OMP openai-codex/gpt-6-astra
  implement: OMP openai-codex/gpt-6-astra on Kubernetes
  bulk_scaffold: OMP openai-codex/gpt-5.6-sol
  image_generation: omniroute-imagegen only
  parent_only: setup, shared contracts, integration, validation, Definition of Done, merge and production promotion
engineering:
  test_commands:
    - swift test --package-path Packages/macOS/CmuxReadAloud
    - ./scripts/setup.sh
    - ./scripts/reload.sh --tag minimax-read-aloud
    - CMUX_TAG=minimax-read-aloud scripts/cmux-debug-cli.sh list-workspaces
    - native selection, streaming audio, cancellation and settings smoke
  graft_required: false
  branch_pattern: wp-750-minimax-read-aloud
  merge_style: squash-via-PR
  secrets_location: existing owner-controlled stores for infrastructure; MiniMax TTS key in macOS Keychain only
  commit_policy: no commits or pushes without explicit human request
  self_improvement_cadence: on_commit
  non_ui_skip_mocked_up: true
  circuit_breaker_strikes: 2
waivers:
  - date: 2026-09-08
    approved_by: Howard
    decision: Reuse native cmux menu and settings styling; no generated North Star mockup required for this incremental feature.
  - date: 2026-09-08
    approved_by: Howard
    decision: Commit the verified feature locally and deploy a private Release from the feature branch after backups, with automatic updates disabled. This does not authorize an upstream push, merge, release tag, or public distribution.
setup_audit:
  project_and_wiki: created and verified via authorized owner session
  buzz: private channel created and scoped WP 750 thread posted
  bootstrap: populated with source, architecture, commands, secrets handles, runtime, approvals, evidence, assumptions and handoff
  scope: terminal selected-text MiniMax read aloud, streaming/cancellation, voice/model/speed settings and Keychain credential entry
  process_precedence: global charter controls lifecycle and commit approval; upstream AGENTS controls product/build/localization facts
  exclusions: no iOS/browser feature expansion, no native TTS fallback, no upstream push/merge or public release
