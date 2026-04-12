## Explanation for the prompt that is created to orchestrate these translation steps

  Intent detected: AGENTIC (tool-use with iterative reasoning) combined with CREATE (multi-step procedure).

  Framework selection: This is a multi-step orchestration task where each step dispatches subagents and reacts to their output. Two frameworks apply:

  - RISEN for the outer phase structure (Role, Instructions, Steps, End goal, Narrowing)
  - ReAct elements embedded inside each step (dispatch → observe → react)

  I'm going with RISEN as the primary framework with an explicit ReAct pattern inside each agent-dispatch step. RISEN handles the ordered phases and stop conditions; ReAct handles the per-step subagent
  loop.

  Defaults I'm baking in (flag if any are wrong):
  1. Pause between agents — orchestrator stops after each agent and waits for user "continue" before proceeding. Safer for a long-running pipeline.
  2. Never auto-retry — on BLOCKED or verification failure, always escalate to user. No silent re-dispatch.
  3. Never auto-rerun on verdict — Yellow/Red from Agent 4 escalates to user, never triggers automatic Agent 3 re-run.
  4. Screenshots halt — if screenshots/ is empty or sparse (<3 files), halt and instruct user to add them before proceeding.
  5. Verification greps embedded — orchestrator runs automated checks after each agent (iOS terminology in audit/, Android API names in domain/, audit lookup count in design/).
  6. Never commits — produces all files but requires user approval for any git operation.

  Key components of the prompt:
  - Subagent dispatch template with model: sonnet override specified
  - Per-agent verification criteria (grep patterns, expected file counts)
  - Status-reaction rules (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT)
  - Pause points with specific "proceed?" prompts
  - Final status report format
