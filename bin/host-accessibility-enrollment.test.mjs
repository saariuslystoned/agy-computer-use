import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ACCESSIBILITY_REQUEST_ARGUMENT,
  buildNativeLaunchArguments,
  ProductionHostSupervisor
} from './host-lifecycle-core.mjs';
import {
  assertAccessibilityEnrollmentOwnership,
  parseLifecycleOptions
} from './host-lifecycle.mjs';

const HERMETIC_RUNTIME = `/tmp/agy-accessibility-enrollment-test-${process.pid}`;

test('public enrollment parsing is exact and ordinary lifecycle commands remain silent', () => {
  assert.deepEqual(
    parseLifecycleOptions('host-start', []),
    { requestAccessibility: false }
  );
  assert.deepEqual(
    parseLifecycleOptions('host-start', [ACCESSIBILITY_REQUEST_ARGUMENT]),
    { requestAccessibility: true }
  );
  assert.deepEqual(
    parseLifecycleOptions('daemon', [ACCESSIBILITY_REQUEST_ARGUMENT]),
    { requestAccessibility: true },
    'The internal daemon hop must preserve the exact explicit opt-in'
  );
  assert.throws(
    () => parseLifecycleOptions('host-start', [
      ACCESSIBILITY_REQUEST_ARGUMENT,
      ACCESSIBILITY_REQUEST_ARGUMENT
    ]),
    /accepts only the optional exact flag/
  );
  assert.throws(
    () => parseLifecycleOptions(
      'host-start',
      [`${ACCESSIBILITY_REQUEST_ARGUMENT}-near-match`]
    ),
    /accepts only the optional exact flag/
  );
  assert.throws(
    () => parseLifecycleOptions('host-status', [ACCESSIBILITY_REQUEST_ARGUMENT]),
    /accepts no extra arguments/
  );
});

test('native argv omits the prompt by default and core exclusively injects one opt-in', () => {
  const ordinaryBase = ['--agy-launch-generation', 'generation-1'];
  const ordinaryArgs = buildNativeLaunchArguments(ordinaryBase, false);
  assert.deepEqual(ordinaryArgs, ordinaryBase);
  assert.equal(ordinaryArgs.includes(ACCESSIBILITY_REQUEST_ARGUMENT), false);
  assert.notEqual(ordinaryArgs, ordinaryBase, 'Builder must not mutate caller argv');

  const enrollmentArgs = buildNativeLaunchArguments(ordinaryBase, true);
  assert.deepEqual(enrollmentArgs, [
    ...ordinaryBase,
    ACCESSIBILITY_REQUEST_ARGUMENT
  ]);
  assert.equal(
    enrollmentArgs.filter((arg) => arg === ACCESSIBILITY_REQUEST_ARGUMENT).length,
    1
  );
});

test('binaryArgs cannot bypass, duplicate, or suppress the core enrollment option', () => {
  for (const requestAccessibility of [false, true]) {
    assert.throws(
      () => buildNativeLaunchArguments(
        ['--fixture', ACCESSIBILITY_REQUEST_ARGUMENT],
        requestAccessibility
      ),
      /is reserved/
    );
    assert.throws(
      () => buildNativeLaunchArguments(
        [ACCESSIBILITY_REQUEST_ARGUMENT, ACCESSIBILITY_REQUEST_ARGUMENT],
        requestAccessibility
      ),
      /is reserved/
    );
  }
  assert.throws(
    () => buildNativeLaunchArguments([], 'true'),
    /must be a boolean/
  );
});

test('strict enrollment request fails closed on an already-running core supervisor', async () => {
  const supervisor = new ProductionHostSupervisor({
    runtimeDir: HERMETIC_RUNTIME,
    processInspector: () => []
  });
  supervisor.state = 'running';
  supervisor.child = { pid: 4242 };

  let statusChecks = 0;
  supervisor.checkNativeStatus = async () => {
    statusChecks += 1;
    return {
      alive: true,
      data: {
        pid: 4242,
        tcc_permission_state: 'granted'
      }
    };
  };

  await assert.rejects(
    supervisor.start({ requestAccessibility: true }),
    /must be fully stopped first/
  );
  assert.equal(
    statusChecks,
    0,
    'Enrollment rejection must happen before idempotent-running success'
  );

  const ordinary = await supervisor.start({ requestAccessibility: false });
  assert.equal(ordinary.status, 'running');
  assert.equal(ordinary.idempotent, true);
  assert.equal(statusChecks, 1);
});

test('explicit enrollment fails closed when its daemon loses launch ownership', () => {
  assert.doesNotThrow(() => {
    assertAccessibilityEnrollmentOwnership(
      { requestAccessibility: false },
      false
    );
  });
  assert.doesNotThrow(() => {
    assertAccessibilityEnrollmentOwnership(
      { requestAccessibility: true },
      true
    );
  });
  assert.throws(
    () => assertAccessibilityEnrollmentOwnership(
      { requestAccessibility: true },
      false
    ),
    (err) => {
      assert.equal(err.code, 'ACCESSIBILITY_PROMPT_REQUIRES_RESTART');
      assert.match(err.message, /did not win the exact host launch/);
      return true;
    }
  );
});
