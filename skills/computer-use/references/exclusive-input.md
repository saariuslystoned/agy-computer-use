# Native exclusive input admission

Shared workstations start in `operator_safe_ax`. Accessibility trust and a fresh
capture do not authorize global input. All six global methods reject with
`OPERATOR_EXCLUSIVE_REQUIRED`, `strategy: rejected` and zero posts before entering
the input engine. The production engine independently rejects missing, replayed,
wrong-action, wrong-capture and foreign-authority permits.

`computer_use_exclusive_control` adds bounded acquire/release operations. It does
not make a shared desktop isolated. A second monitor and a software cursor are
not isolation. No targeted synthetic strategy or global fallback is claimed.

## Admission trust boundary

An administrator who owns an **isolated VM or dedicated worker GUI session** must
provision `/Library/Application Support/AGYComputerUse/exclusive-session.json`.
The host opens every path component relative to a verified directory descriptor,
rejects symlinks, non-root ownership, group/world writes and ACL allow entries,
and bounds the regular file to 4096 bytes. No caller flag, environment override,
MCP parameter or user-owned file substitutes for that record. Provisioning is an
out-of-band operator action, not an agent tool. Never provision it on the shared
operator desktop merely to run a test.

Record format (replace each illustrative value using the intended live host,
controller and GUI session):

```json
{
  "environment_id": "owned-disposable-vm-run-id",
  "environment_kind": "isolated_vm",
  "host_instance_id": "from-computer-use-status",
  "controller_id": "from-the-same-MCP-connection-status",
  "uid": 501,
  "gui_session_id": 1,
  "expires_at_ms": 0
}
```

`environment_kind` accepts only `isolated_vm` or `dedicated_worker`. The host UUID
changes on restart. The controller ID is private to an MCP connection, not an
argument supplied by the model. `uid` and `gui_session_id` must match the current
logged-in, on-console Core Graphics session (`kCGSessionUserIDKey` and
`kCGSessionConsoleSetKey`). Expiry must be in the future and at most five minutes
away. The illustrative expiry above intentionally grants nothing. Identifiers
are non-secret admission metadata; the root-controlled file and owner-only socket
are the trust boundaries. This is an administrator's authorization assertion,
not automatic attestation of hypervisor isolation or protection from malicious
software running as the same user/root.

## Bounded operation

1. In that owned environment, deliberately focus the intended app/window/element.
   The host never activates an arbitrary foreground app or repairs focus itself.
2. On the same MCP connection, acquire with explicit `app_id` and `duration_ms`
   between 1000 and 60000. Admission binds process birth, exact focused window,
   window set and bounds, display topology, and focused AX element. Missing AX
   identity or input-monitor coverage fails closed. One controller owns the host;
   even that controller must release before changing its target.
3. Acquire invalidates an earlier display capture. Observe the intended display,
   then pass the returned `exclusive_lease_id`, fresh `capture_id`, topology and
   intent to one global action. A display is geometry, never a keyboard recipient.
   Captures expire after 30 seconds and are consumed once. Opaque engine permits
   are separately one-shot and cannot be constructed through IPC.
4. Before the first event, preflight every point in the bounded sequence. Before
   each event, recheck root admission, wall-clock and monotonic expiry, process,
   topology, window geometry, target focus and monitor health. Coordinate points
   must hit the admitted window; keyboard calls must still have the same focused,
   enabled, non-secure element. Secure input, termination, focus loss, window
   replacement, foreign input (including mouse movement), coverage loss, policy
   removal/change or expiry revokes authority. No mutation is retried.
5. Release explicitly when finished. MCP close also revokes that controller.
   Abrupt connection/process loss is bounded by expiry; status revalidates active
   authority. Another controller cannot revoke an owner's lease by naming itself.

These checks and macOS event posting are not an atomic transaction with other
applications or hardware. Global mode **can move the physical pointer and change
focus**, and a concurrent takeover can occur after the last check. That is why
an isolated, owned environment remains mandatory even with native enforcement.

## Results and cleanup

Success reports actual `strategy: exclusive_global_hid`, dispatched event count
and capture identity. Preflight errors report `strategy: rejected` and zero posts.
After any post, subsequent failure is `OUTCOME_UNKNOWN` with the underlying typed
cause and total/cleanup post counts. Never infer no mutation from that failure.
Observe and adjudicate a distinct next action.

All event objects and release events are allocated before posting. On failure,
only the releases for this engine's actually posted downs may bypass admission;
otherwise a revoked drag/modifier could remain held. No down is retried. Mouse
release uses the current cursor position, not cursor save/restore. Calling cleanup
without a held input posts nothing. Receipts retain no intent, text or keystream.
Transport uncertainty retains the existing `ACTION_OUTCOME_UNKNOWN` code and also
requires fresh observation without automatic retry.

Shared-mode semantic AX keeps its existing, independent app-scoped intervention
contract: unrelated operator input may coexist with a qualified background target.
The stricter global monitor exists only during admitted exclusive control. Images
remain unredacted; combined AX/image observations remain bracketed, not atomic.

## Reference and qualification boundary

The installed Codex `cua` runtime interface was refreshed September 16, 2026:
explicit App/Tab objects, index-first actions, AX differences, combined AX/image,
automatic waits and action-plus-fresh-state calls. Secondary actions require actual
advertisement. No upstream source/release SHA was exposed; this is not an audited
upstream-main comparison or a claim of universal input isolation.

[OpenAI's public custom-tool guidance](https://developers.openai.com/api/docs/guides/tools-computer-use-integration#use-your-own-ui-tools)
supports retaining custom tools with execution controls, permissions before actions
and current observations. It introduces no OpenAI model dependency here.
[Apple's event tap contract](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
explains why requested event masks must be checked for actual coverage. The
[public event-source PID field](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventsourceunixprocessid)
separates this host's posts from external events without recording key values.

Unit tests use the production authority and CGEvent sequencing with a recording
sink, never a real global event post. Live admitted coordinate/keyboard proof must
run separately on an administrator-admitted owned GUI environment. It is not
established by a green unit test or a caller-controlled `exclusive` boolean.
