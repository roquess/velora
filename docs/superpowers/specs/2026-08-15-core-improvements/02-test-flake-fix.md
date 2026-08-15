# 02 — test flake fix

## Problem

During the Emergence work, full `rebar3 eunit` runs occasionally showed 1–2
failures that vanished on rerun, reported by two subagents:
- a `velora_api_tests` raster-processing assertion (`result_uri` / `status:
  error`) that is timing-sensitive;
- coordinator/supervisor teardown timing failures.

Flaky tests erode trust and will intermittently redden CI on unrelated PRs.

## Approach

Use systematic-debugging — do **not** paper over with `timer:sleep`. Steps:

1. **Reproduce deterministically.** Run the suspect suites in a tight loop
   (`for i in $(seq 1 30); do rtk rebar3 eunit --module=velora_api_tests; done`)
   and capture a failing run's output. Identify the exact assertion and the
   race (likely: the test asserts a job's terminal state before the coordinator
   has transitioned, or a supervisor child is still terminating when the test
   inspects it).
2. **Find the missing synchronization.** The correct fix is to *wait for the
   real condition*, not a fixed delay: poll the job/coordinator state with a
   bounded retry helper (`wait_until(Fun, Timeout)`), or subscribe to the
   completion signal the code already emits, or make teardown synchronous
   (e.g. `gen_server:stop/3` + wait for `DOWN`) so the next assertion sees a
   settled system.
3. **Add a shared `wait_until/2,3` test helper** if several tests need it, and
   replace the racy assertions.
4. **Verify.** Run the previously-flaky suites 30× with zero failures.

## Scope

Test-only changes plus, if the race is a real product bug (e.g. a state
transition that is observable in an inconsistent intermediate form), a minimal
product fix with its own test. Report which it was.

## Testing

- The loop-30× green run is the acceptance criterion.
- If a `wait_until/2` helper is added, unit-test it (returns early on success,
  errors on timeout).

## Risks

- The flake may be environment-specific (Windows GDAL spawn latency). If so,
  the fix is still "wait for the condition", and the helper must have a generous
  but bounded timeout so CI on slower runners is stable.
