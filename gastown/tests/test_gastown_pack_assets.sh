#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
GASTOWN="$ROOT/gastown"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

parse_toml() {
    python3 - "$@" <<'PY'
import sys
import tomllib

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
PY
}

test_dog_assets_are_pack_local() {
    [[ -f "$GASTOWN/agents/dog/agent.toml" ]] || fail "missing dog agent config"
    [[ -f "$GASTOWN/agents/dog/prompt.template.md" ]] || fail "missing dog prompt"
    [[ -f "$GASTOWN/formulas/mol-shutdown-dance.toml" ]] || fail "missing shutdown dance formula"
    parse_toml "$GASTOWN/agents/dog/agent.toml" "$GASTOWN/formulas/mol-shutdown-dance.toml"
    grep -F 'wake_mode = "fresh"' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "dog agent should own wake_mode"
    grep -F 'work_dir = ".gc/agents/dogs/{{.AgentBase}}"' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "dog agent should own work_dir"
    ! grep -F 'fallback = true' "$GASTOWN/agents/dog/agent.toml" >/dev/null ||
        fail "gastown dog should be authoritative over fallback dog providers"
    ! grep -A3 -F '[[patches.agent]]' "$GASTOWN/pack.toml" | grep -F 'name = "dog"' >/dev/null ||
        fail "dog should not be split between pack-local agent and same-name patch"
    [[ ! -e "$GASTOWN/agents/dog/overlay/.gitkeep" ]] ||
        fail "dog overlay placeholder should not be present without an overlay contract"
}

test_retired_dog_formulas_are_not_reintroduced() {
    [[ ! -e "$GASTOWN/formulas/mol-dog-jsonl.toml" ]] || fail "mol-dog-jsonl formula should remain retired"
    [[ ! -e "$GASTOWN/formulas/mol-dog-reaper.toml" ]] || fail "mol-dog-reaper formula should remain retired"
    ! grep -R --exclude='test_gastown_pack_assets.sh' "mol-dog-jsonl\\|mol-dog-reaper" "$GASTOWN" >/dev/null ||
        fail "gastown pack should not advertise retired dog formulas"
}

test_shutdown_dance_contracts_are_executable() {
    local formula="$GASTOWN/formulas/mol-shutdown-dance.toml"

    ! grep -F '[vars.warrant_id]' "$formula" >/dev/null ||
        fail "warrant_id should be the claimed work bead, not a required formula var"
    grep -F 'gc bd show "$GC_BEAD_ID"' "$formula" >/dev/null ||
        fail "shutdown dance should inspect the claimed warrant bead"
    grep -F 'gc bd close "$GC_BEAD_ID"' "$formula" >/dev/null ||
        fail "shutdown dance should close the claimed warrant bead"
    ! grep -F '<wisp-id>' "$formula" >/dev/null ||
        fail "shutdown dance should not contain raw wisp placeholders"
    ! grep -F '<work-bead>' "$formula" >/dev/null ||
        fail "shutdown dance should not contain raw work bead placeholders"
    ! grep -F 'gc mail send {{requester}}/' "$formula" >/dev/null ||
        fail "routine dog requester reporting must use nudge, not mail"
    grep -F 'requester_endpoint="${requester%/}/"' "$formula" >/dev/null ||
        fail "shutdown dance should normalize requester endpoints"
    grep -F 'gc session nudge "$requester_endpoint" "DOG_DONE:' "$formula" >/dev/null ||
        fail "shutdown dance should notify requester with DOG_DONE nudges"
    ! grep -F 'gc session peek "{{target}}"' "$formula" >/dev/null ||
        fail "shutdown dance should use quoted target shell variables for peeks"
    ! grep -F 'gc session kill "{{target}}"' "$formula" >/dev/null ||
        fail "shutdown dance should use quoted target shell variables for kills"
    grep -F 'Verify the warrant bead exists and is not closed' "$formula" >/dev/null ||
        fail "receive step should verify the warrant is not closed rather than demanding open"
    grep -F 'Both `open` and `in_progress` are valid warrant states' "$formula" >/dev/null ||
        fail "receive step should explicitly accept open and in_progress warrant states"
    ! grep -F 'exists and is open' "$formula" >/dev/null ||
        fail "receive step must not regress to an open-only warrant instruction; claimed warrants are in_progress"
}

test_shutdown_dance_lifecycle_and_audit_contracts() {
    local formula="$GASTOWN/formulas/mol-shutdown-dance.toml"
    local prompt="$GASTOWN/agents/dog/prompt.template.md"

    ! grep -Fi 'burn' "$formula" >/dev/null ||
        fail "early-exit paths should drain-ack and exit, not burn a wisp that was never poured"
    [[ "$(grep -c 'gc runtime drain-ack' "$formula")" -ge 8 ]] ||
        fail "every early-exit path and the epitaph should end with gc runtime drain-ack"
    local malformed_branches malformed_closes malformed_drains
    malformed_branches="$(grep -c 'is missing target or reason' "$formula" || true)"
    malformed_closes="$(grep -A4 'is missing target or reason' "$formula" | grep -cF 'gc bd close "$GC_BEAD_ID"' || true)"
    malformed_drains="$(grep -A4 'is missing target or reason' "$formula" | grep -cF 'gc runtime drain-ack' || true)"
    [[ "$malformed_branches" -ge 1 ]] ||
        fail "shutdown dance should validate warrant target/reason metadata"
    [[ "$malformed_closes" -eq "$malformed_branches" ]] ||
        fail "every malformed-warrant branch must close the claimed warrant before exiting"
    [[ "$malformed_drains" -eq "$malformed_branches" ]] ||
        fail "every malformed-warrant branch must drain-ack before exiting, not leak the claimed warrant"
    grep -F 'MALFORMED_WARRANT' "$formula" >/dev/null ||
        fail "malformed warrants should close with a malformed-warrant audit reason"
    ! grep -E '^\[vars' "$formula" >/dev/null ||
        fail "warrant values come from bead metadata; the formula should not declare pour vars"
    grep -F 'EXECUTE_FAILED: kill did not take effect' "$formula" >/dev/null ||
        fail "kill failures should close the warrant as EXECUTE_FAILED, not Executed"
    grep -F 'DOG_DONE: $target - EXECUTE_FAILED (escalated)' "$formula" >/dev/null ||
        fail "kill failures should notify the requester with EXECUTE_FAILED, not EXECUTED"
    grep -F 'gone or shows fresh startup output' "$formula" >/dev/null ||
        fail "execute verification should treat gone-or-freshly-restarted as kill success"
    ! grep -F '{{requester}}' "$prompt" >/dev/null ||
        fail "dog prompt should use the normalized requester endpoint, not raw requester templates"
    ! grep -F 'nudge deacon/' "$prompt" >/dev/null ||
        fail "dog prompt should notify the warrant's requester, not a hardcoded deacon endpoint"
    grep -F 'gc session nudge "$requester_endpoint"' "$prompt" >/dev/null ||
        fail "dog prompt DOG_DONE guidance should use the normalized requester endpoint"
}

test_composition_is_documented() {
    # The retired maintenance pack is gone: the runtime composes the builtin
    # core pack via explicit city.toml includes, and gastown owns the only
    # mol-shutdown-dance. The docs must describe that model, not the old
    # fallback/ordering workarounds.
    grep -F 'builtin core pack' "$GASTOWN/README.md" >/dev/null ||
        fail "README should attribute mechanical housekeeping to the builtin core pack"
    ! grep -F '[imports.maintenance]' "$GASTOWN/README.md" >/dev/null ||
        fail "README should not reference the retired maintenance pack import"
    ! grep -Fi 'implicit maintenance' "$GASTOWN/README.md" >/dev/null ||
        fail "README should not describe implicit maintenance injection"
    grep -F 'gc formula show mol-shutdown-dance' "$GASTOWN/README.md" >/dev/null ||
        fail "README should document how to verify the effective shutdown-dance formula"
    grep -F 'builtin core' "$GASTOWN/pack.toml" >/dev/null ||
        fail "pack.toml should attribute mechanical housekeeping to the builtin core pack"
    ! grep -F '[imports.maintenance]' "$GASTOWN/pack.toml" >/dev/null ||
        fail "pack.toml should not reference the retired maintenance pack import"
}

test_polecat_startup_uses_standard_hook_claim() {
    local agent prompt propulsion
    agent="$GASTOWN/agents/polecat/agent.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"
    propulsion="$GASTOWN/template-fragments/propulsion.template.md"

    grep -F 'gc hook --claim --json' "$agent" >/dev/null ||
        fail "polecat nudge should call the standard hook claim path"
    grep -F 'gc hook --claim --json' "$prompt" >/dev/null ||
        fail "polecat prompt should call the standard hook claim path"
    grep -F 'gc hook --claim --json' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment should call the standard hook claim path"
    grep -F 'After closing any formula step bead, immediately run' "$prompt" >/dev/null ||
        fail "polecat prompt must require hook continuation after each formula step"
    grep -F 'After closing a step bead,' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment must require hook continuation after each formula step"
    ! grep -F 'run `gc hook` or' "$prompt" >/dev/null ||
        fail "polecat prompt must not regress to an unclaimed hook/work-query choice"
    ! grep -F 'run `gc hook` or' "$propulsion" >/dev/null ||
        fail "polecat propulsion fragment must not regress to an unclaimed hook/work-query choice"
}

test_review_leg_contract_forbids_synthetic_mutation() {
    local formula prompt
    formula="$GASTOWN/formulas/mol-review-leg.toml"
    prompt="$GASTOWN/agents/polecat/prompt.template.md"

    grep -F 'Do not create synthetic/test beads' "$formula" >/dev/null ||
        fail "review-leg formula must forbid synthetic test beads"
    grep -F 'Do not create test beads' "$formula" >/dev/null ||
        fail "review-leg load-assignment must forbid test bead creation"
    grep -F 'The only allowed bead mutations are the formula-prescribed' "$formula" >/dev/null ||
        fail "review-leg formula must define allowed mutation boundary"
    grep -F 'treat that text as' "$formula" >/dev/null ||
        fail "review-leg formula must treat plans/checklists as review subject matter"
    grep -F 'Do not start cities, spawn sessions, route extra work' "$formula" >/dev/null ||
        fail "review-leg formula must forbid executing reviewed checklist items"
    grep -F 'Formula-specific non-implementation assignments may explicitly tell you' "$prompt" >/dev/null ||
        fail "polecat prompt must allow formula-specific review/control close steps"
    ! grep -F '`gc bd close`, `gc bd close`' "$prompt" >/dev/null ||
        fail "polecat prompt must not duplicate its close prohibition"
    grep -F 'Default implementation formula: `mol-polecat-work`' "$prompt" >/dev/null ||
        fail "polecat prompt must describe mol-polecat-work as the default implementation formula"
    ! grep -F '**You MUST NOT close beads. EVER. No exceptions.**' "$prompt" >/dev/null ||
        fail "polecat prompt must not globally forbid review-leg close steps"
}

test_refinery_direct_merge_is_worktree_safe_and_fail_closed() {
    local formula direct_block
    formula="$GASTOWN/formulas/mol-refinery-patrol.toml"

    direct_block=$(python3 - "$formula" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
print(text[start:end])
PY
)

    [[ "$direct_block" == *'git worktree add --detach "$MERGE_WT" "origin/$TARGET"'* ]] ||
        fail "direct refinery merge must use a detached target worktree"
    [[ "$direct_block" == *'+refs/heads/${TARGET}:refs/remotes/origin/${TARGET}'* ]] ||
        fail "direct refinery merge refspecs must brace TARGET for zsh-safe expansion"
    [[ "$direct_block" == *'git -C "$MERGE_WT" push origin "HEAD:$TARGET"'* ]] ||
        fail "direct refinery merge must push the verified merge worktree HEAD"
    [[ "$direct_block" == *'[ "$MERGED_SHA" != "$REMOTE" ]'* ]] ||
        fail "direct refinery merge must compare merged SHA to origin target"
    [[ "$direct_block" == *'STOP. Do not mutate bead state.'* ]] ||
        fail "direct refinery merge must fail closed before metadata writes"
    ! printf '%s\n' "$direct_block" | grep -E '^[[:space:]]*git checkout \$TARGET([[:space:]]|$)' >/dev/null ||
        fail "direct refinery merge must not checkout target branch in the active worktree"

    python3 - "$formula" <<'PY' || fail "direct refinery merge must verify origin before setting merged metadata"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index('**If MERGE_STRATEGY = "direct"')
end = text.index('**If MERGE_STRATEGY = "mr"')
block = text[start:end]
verify = block.index('[ "$MERGED_SHA" != "$REMOTE" ]')
metadata = block.index('--set-metadata merge_result=merged')
if verify >= metadata:
    raise SystemExit(1)
PY
}

test_next_iteration_excludes_current_wisp_from_successor_queries() {
    local witness_prompt deacon_prompt witness_formula
    witness_prompt="$GASTOWN/agents/witness/prompt.template.md"
    deacon_prompt="$GASTOWN/agents/deacon/prompt.template.md"
    witness_formula="$GASTOWN/formulas/mol-witness-patrol.toml"

    # A patrol agent's current wisp is still status=open until it transitions,
    # so an unfiltered --status=open successor query returns the current wisp
    # itself. The reconciler then reads "a successor is already queued", burns
    # the current wisp without pouring one, and leaves the agent with zero
    # wisps until a human notices.
    grep -F 'jq -r --arg cur "$CURRENT_WISP"' "$witness_prompt" >/dev/null ||
        fail "witness fallback must pass CURRENT_WISP to the successor query"
    grep -F 'select(.id != $cur)' "$witness_prompt" >/dev/null ||
        fail "witness fallback must exclude CURRENT_WISP from OPEN_WISPS"
    grep -F 'jq -r --arg cur "$CURRENT_WISP"' "$deacon_prompt" >/dev/null ||
        fail "deacon fallback must pass CURRENT_WISP to the successor query"
    grep -F 'select(.id != $cur)' "$deacon_prompt" >/dev/null ||
        fail "deacon fallback must exclude CURRENT_WISP from ASSIGNED_WISP"

    # mol-witness-patrol's next-iteration step had no CURRENT_WISP guard at
    # all: it picked NEXT off the raw open-wisp list, then burned "this wisp"
    # by hand-substituted placeholder — which could be the same bead.
    grep -F 'CURRENT_WISP=${GC_BEAD_ID:-}' "$witness_formula" >/dev/null ||
        fail "mol-witness-patrol next-iteration must resolve the current wisp"
    grep -F 'jq -r --arg cur "$CURRENT_WISP"' "$witness_formula" >/dev/null ||
        fail "mol-witness-patrol next-iteration must pass CURRENT_WISP to the successor query"
    grep -F 'select(.id != $cur)' "$witness_formula" >/dev/null ||
        fail "mol-witness-patrol next-iteration must exclude CURRENT_WISP from OPEN_WISPS"
    grep -F 'gc bd mol burn "$CURRENT_WISP" --force' "$witness_formula" >/dev/null ||
        fail "mol-witness-patrol must burn the resolved current wisp"
    ! grep -F 'gc bd mol burn <this-wisp-id>' "$witness_formula" >/dev/null ||
        fail "mol-witness-patrol must not burn a hand-substituted wisp placeholder"

    # Guard every sibling site: once a shell block resolves CURRENT_WISP, any
    # open-molecule query in that block is deriving a successor and must filter
    # the current wisp out. The startup reconcilers, which union open and
    # in_progress to pick one wisp to resume, never set CURRENT_WISP and are
    # correctly exempt.
    python3 - "$GASTOWN" <<'PY' || fail "successor wisp query does not exclude CURRENT_WISP"
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
open_fence = re.compile(r"^\s*```bash\s*$")
close_fence = re.compile(r"^\s*```\s*$")
QUERY = "--status=open --type=molecule"
EXCLUSION = "select(.id != $cur)"

violations = []
for path in sorted(root.rglob("*")):
    if path.suffix not in {".md", ".toml"} or not path.is_file():
        continue
    block = None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if block is None:
            if open_fence.match(line):
                block = []
            continue
        if close_fence.match(line):
            if any("CURRENT_WISP=" in entry for entry, _ in block):
                violations += [
                    f"{path.relative_to(root)}:{where}: {entry.strip()}"
                    for entry, where in block
                    if QUERY in entry and EXCLUSION not in entry
                ]
            block = None
            continue
        block.append((line, number))

if violations:
    print("\n".join(violations))
    raise SystemExit(1)
PY
}

test_refinery_patrol_is_bounded_by_merge_count() {
    local formula
    formula="$GASTOWN/formulas/mol-refinery-patrol.toml"

    # A wisp bounds the WORK ITEM, not the process: pouring the next wisp keeps
    # the same conversation, so every prior merge stays in context. A refinery
    # was measured at 606,783 tokens over 23h16m with zero compactions. That is
    # a correctness problem — handle-failures asks the refinery to judge whether
    # a failure is a branch regression or pre-existing on target, and that
    # judgement's inputs drift as context grows.
    grep -F '[vars.max_merges_per_session]' "$formula" >/dev/null ||
        fail "mol-refinery-patrol must declare max_merges_per_session"
    grep -F '[vars.merges_this_session]' "$formula" >/dev/null ||
        fail "mol-refinery-patrol must declare merges_this_session"
    grep -F 'MERGES_DONE=$(( {{merges_this_session}} + 1 ))' "$formula" >/dev/null ||
        fail "next-iteration must count the merge it just completed"
    grep -F 'gc runtime request-restart' "$formula" >/dev/null ||
        fail "next-iteration must restart the process once the bound is reached"

    # Ordering is load-bearing: pour, assign, burn, THEN restart. Restarting
    # before the successor is poured and assigned brings the refinery back with
    # an empty hook and stops the patrol (upstream sys-x3g8i is that bug in
    # mol-witness-patrol). Assert the restart is the LAST thing next-iteration
    # does, after the burn.
    python3 - "$formula" <<'PY' || fail "next-iteration must restart only after pour+assign+burn"
import pathlib
import re
import sys
import tomllib

formula = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
step = next(s for s in formula["steps"] if s["id"] == "next-iteration")

# Only executable lines count. The step's prose also names these commands while
# explaining them, and prose that trails the code would satisfy any ordering
# check run over the raw description.
code = "\n".join(re.findall(r"```bash\n(.*?)```", step["description"], re.S))

burn = code.rfind('gc bd mol burn "$CURRENT_WISP" --force')
assign = code.rfind('gc bd update "$NEXT" --assignee="$GC_AGENT"')
pour = code.rfind("gc bd mol wisp mol-refinery-patrol")
restart = code.rfind("gc runtime request-restart")

missing = [n for n, i in (("pour", pour), ("assign", assign), ("burn", burn),
                          ("restart", restart)) if i < 0]
if missing:
    raise SystemExit("next-iteration is missing: " + ", ".join(missing))
if not pour < assign < burn < restart:
    raise SystemExit(
        "next-iteration order must be pour < assign < burn < restart; got "
        f"pour={pour} assign={assign} burn={burn} restart={restart}"
    )
PY

    # Every executable pour must thread the counter. A pour that omits it falls
    # back to the default (0), so the bound silently never fires on that path —
    # the same class of invisible regression this bound exists to prevent. The
    # bootstrap pour in the formula description is exempt: it is the FIRST pour
    # and correctly starts at the default, and it lives outside a bash fence.
    python3 - "$formula" <<'PY' || fail "a refinery pour does not thread merges_this_session"
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
open_fence = re.compile(r"^\s*```bash\s*$")
close_fence = re.compile(r"^\s*```\s*$")

violations = []
in_block = False
for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
    if not in_block:
        in_block = bool(open_fence.match(line))
        continue
    if close_fence.match(line):
        in_block = False
        continue
    if "gc bd mol wisp mol-refinery-patrol" in line and "--var merges_this_session=" not in line:
        violations.append(f"{path.name}:{number}: {line.strip()}")

if violations:
    print("\n".join(violations))
    raise SystemExit(1)
PY
}

test_dog_assets_are_pack_local
test_retired_dog_formulas_are_not_reintroduced
test_shutdown_dance_contracts_are_executable
test_shutdown_dance_lifecycle_and_audit_contracts
test_composition_is_documented
test_polecat_startup_uses_standard_hook_claim
test_review_leg_contract_forbids_synthetic_mutation
test_refinery_direct_merge_is_worktree_safe_and_fail_closed
test_next_iteration_excludes_current_wisp_from_successor_queries
test_refinery_patrol_is_bounded_by_merge_count

echo "gastown pack asset tests passed"
