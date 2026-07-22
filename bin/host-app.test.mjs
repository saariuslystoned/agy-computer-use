import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { stageHostApp, classifyPrincipal, parseAndClassifyPrincipal, validateStageTargetDir } from './host-app.mjs';

function computeTreeDigest(dirPath) {
    const entries = [];
    function walk(current) {
        const items = fs.readdirSync(current, { withFileTypes: true });
        for (const item of items) {
            const fullPath = path.join(current, item.name);
            const relPath = path.relative(dirPath, fullPath);
            const lst = fs.lstatSync(fullPath);
            const mode = lst.mode & 0o777;
            let typeStr = 'other';
            if (lst.isFile()) typeStr = 'file';
            else if (lst.isDirectory()) typeStr = 'directory';
            else if (lst.isSymbolicLink()) typeStr = 'symlink';

            entries.push({ relPath, typeStr, mode, fullPath, isFile: lst.isFile() });
            if (lst.isDirectory()) {
                walk(fullPath);
            }
        }
    }
    walk(dirPath);
    entries.sort((a, b) => a.relPath.localeCompare(b.relPath));

    const hash = crypto.createHash('sha256');
    for (const entry of entries) {
        hash.update(`${entry.relPath}:${entry.typeStr}:${entry.mode}:`);
        if (entry.isFile) {
            hash.update(fs.readFileSync(entry.fullPath));
        }
    }
    return hash.digest('hex');
}

function waitForFile(filePath, timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
        const start = Date.now();
        const interval = setInterval(() => {
            if (fs.existsSync(filePath)) {
                clearInterval(interval);
                resolve();
            } else if (Date.now() - start > timeoutMs) {
                clearInterval(interval);
                reject(new Error(`Timed out waiting for file creation at ${filePath}`));
            }
        }, 50);
    });
}

function waitForExit(proc, timeoutMs = 5000) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            proc.kill('SIGKILL');
            reject(new Error(`Process ${proc.pid} timed out waiting for exit`));
        }, timeoutMs);

        proc.on('exit', (code) => {
            clearTimeout(timer);
            resolve(code);
        });
        proc.on('error', (err) => {
            clearTimeout(timer);
            reject(err);
        });
    });
}

function spawnAndMonitor(binary, args = [], env = {}) {
    const proc = spawn(binary, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let exited = false;
    let exitCode = null;
    let exitErr = null;

    const exitPromise = new Promise((resolve) => {
        proc.on('exit', (code) => {
            exited = true;
            exitCode = code;
            resolve(code);
        });
        proc.on('error', (err) => {
            exited = true;
            exitErr = err;
            resolve(-1);
        });
    });

    return { proc, exitPromise, isExited: () => exited, getExitCode: () => exitCode, getExitErr: () => exitErr };
}

async function waitForSocketOrExit(monitor, sockPath, timeoutMs = 5000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        if (monitor.isExited()) {
            throw new Error(`Subprocess exited prematurely with code ${monitor.getExitCode()} before socket creation`);
        }
        if (fs.existsSync(sockPath)) {
            return;
        }
        await new Promise(r => setTimeout(r, 50));
    }
    throw new Error(`Timed out waiting for socket creation at ${sockPath}`);
}

async function reapChild(monitor, timeoutMs = 5000) {
    if (monitor.isExited()) {
        return await monitor.exitPromise;
    }
    const killTimer = setTimeout(() => {
        if (!monitor.isExited()) {
            monitor.proc.kill('SIGKILL');
        }
    }, timeoutMs);
    const code = await monitor.exitPromise;
    clearTimeout(killTimer);
    return code;
}

async function runBoundedSubprocessTest(stagedAppBinary, signalToTest) {
    const tmpDir = fs.mkdtempSync('/tmp/agy-host-smoke-');
    fs.chmodSync(tmpDir, 0o700);

    const dirMode = fs.statSync(tmpDir).mode & 0o777;
    assert.equal(dirMode, 0o700, 'Temp socket directory must have mode 0700');

    const sockPath = path.join(tmpDir, 'host.sock');
    const lockPath = path.join(tmpDir, 'host.lock');

    let mon1 = null;
    let mon2 = null;

    try {
        const env = { ...process.env, COMPUTER_USE_SOCKET_PATH: sockPath };
        mon1 = spawnAndMonitor(stagedAppBinary, [], env);

        await waitForSocketOrExit(mon1, sockPath, 5000);
        assert.equal(fs.existsSync(lockPath), true, 'host.lock file must exist after first launch');
        const lockLstat1 = fs.lstatSync(lockPath);
        assert.equal(lockLstat1.isFile(), true, 'host.lock must be a regular file');
        assert.equal(lockLstat1.isSymbolicLink(), false, 'host.lock must NOT be a symbolic link');
        assert.equal(lockLstat1.mode & 0o777, 0o600, 'host.lock file must have mode 0600');
        const lockIno1 = lockLstat1.ino;

        mon1.proc.kill(signalToTest);
        const exitCode1 = await reapChild(mon1, 5000);
        assert.equal(exitCode1, 0, `Process 1 must exit 0 on ${signalToTest}`);
        assert.equal(mon1.isExited(), true, 'Process 1 monitor must be marked exited');
        assert.equal(fs.existsSync(sockPath), false, 'Socket file must be unlinked after exit');
        assert.equal(fs.existsSync(lockPath), true, 'host.lock file is intentionally persistent and survives exit');

        mon2 = spawnAndMonitor(stagedAppBinary, [], env);

        await waitForSocketOrExit(mon2, sockPath, 5000);
        const lockLstat2 = fs.lstatSync(lockPath);
        assert.equal(lockLstat2.isFile(), true, 'host.lock must retain regular file type on second launch');
        assert.equal(lockLstat2.isSymbolicLink(), false, 'host.lock must NOT be a symbolic link on second launch');
        assert.equal(lockLstat2.mode & 0o777, 0o600, 'host.lock file must retain mode 0600 on second launch');
        assert.equal(lockLstat2.ino, lockIno1, 'host.lock file must retain exact inode across same-directory restart');

        mon2.proc.kill(signalToTest);
        const exitCode2 = await reapChild(mon2, 5000);
        assert.equal(exitCode2, 0, `Process 2 must exit 0 on ${signalToTest}`);
        assert.equal(mon2.isExited(), true, 'Process 2 monitor must be marked exited');
        assert.equal(fs.existsSync(sockPath), false, 'Socket file must be unlinked after second exit');
        assert.equal(fs.existsSync(lockPath), true, 'host.lock file survives second exit');
    } finally {
        if (mon1) await reapChild(mon1, 1000);
        if (mon2) await reapChild(mon2, 1000);
        fs.rmSync(tmpDir, { recursive: true, force: true });
    }
}

test('RP-1: Discriminator: host-principal argument handling prevents shell injection', async () => {
    const injectionPath = '/tmp/test app; touch /tmp/pwned.txt; echo/App.app';
    const binPath = path.resolve('bin/agy-computer-use');

    if (fs.existsSync('/tmp/pwned.txt')) {
        fs.rmSync('/tmp/pwned.txt');
    }

    let stdout = '';
    try {
        stdout = execFileSync(process.execPath, [binPath, 'host-principal', '--app', injectionPath], {
            encoding: 'utf-8',
            stdio: ['ignore', 'pipe', 'pipe']
        });
    } catch (err) {
        stdout = (err.stdout || '') + (err.stderr || '');
    }

    assert.equal(fs.existsSync('/tmp/pwned.txt'), false, 'Shell injection target file must NOT be created');
    assert.ok(stdout.includes('unsigned_or_invalid'), 'Must report unsigned_or_invalid for non-existent path');
});

test('RP-2: Pure classifier authority for 13 principal states', async (t) => {
    await t.test('1. Verification failed -> unsigned_or_invalid', () => {
        const res = parseAndClassifyPrincipal('Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=adhoc', '', false);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('2. Exact valid ad-hoc -> ad_hoc_ephemeral', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=adhoc\nTeamIdentifier=not set\nAuthority=adhoc';
        const res = parseAndClassifyPrincipal(codesignOutput, '', true);
        assert.equal(res.classification, 'ad_hoc_ephemeral');
        assert.equal(res.identifier, 'com.saariuslystoned.agy-computer-use.host');
        assert.equal(res.teamId, null);
    });

    await t.test('3. Exact valid team candidate -> stable_team_signed_candidate', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=size=4520\nTeamIdentifier=TEAM123456\nAuthority=Developer ID Application: Test (TEAM123456)';
        const reqOutput = 'designated => identifier "com.saariuslystoned.agy-computer-use.host" and anchor apple generic and certificate leaf[subject.OU] = "TEAM123456"';
        const res = parseAndClassifyPrincipal(codesignOutput, reqOutput, true);
        assert.equal(res.classification, 'stable_team_signed_candidate');
        assert.equal(res.identifier, 'com.saariuslystoned.agy-computer-use.host');
        assert.equal(res.teamId, 'TEAM123456');
    });

    await t.test('4. Wrong bundle ID -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.wrong.bundle\nSignature=adhoc\nTeamIdentifier=not set';
        const res = parseAndClassifyPrincipal(codesignOutput, '', true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('5. Missing signature line -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nTeamIdentifier=TEAM123456';
        const res = parseAndClassifyPrincipal(codesignOutput, '', true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('6. Malformed signature -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=CORRUPT_SIG\nTeamIdentifier=TEAM123456';
        const res = parseAndClassifyPrincipal(codesignOutput, '', true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('7. Missing TeamIdentifier on non-ad-hoc -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=signed\nAuthority=Developer ID Application: Test';
        const res = parseAndClassifyPrincipal(codesignOutput, '', true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('8. Missing designated requirement -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=signed\nTeamIdentifier=TEAM123456\nAuthority=Developer ID Application: Test (TEAM123456)';
        const res = parseAndClassifyPrincipal(codesignOutput, '', true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('9. Wrong identifier requirement -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=signed\nTeamIdentifier=TEAM123456\nAuthority=Developer ID Application: Test (TEAM123456)';
        const reqOutput = 'designated => identifier "com.other.app" and certificate leaf[subject.OU] = "TEAM123456"';
        const res = parseAndClassifyPrincipal(codesignOutput, reqOutput, true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('10. Wrong team requirement -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=signed\nTeamIdentifier=TEAM123456\nAuthority=Developer ID Application: Test (TEAM123456)';
        const reqOutput = 'designated => identifier "com.saariuslystoned.agy-computer-use.host" and certificate leaf[subject.OU] = "OTHERTEAM"';
        const res = parseAndClassifyPrincipal(codesignOutput, reqOutput, true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('11. Alternate/OR requirement -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=signed\nTeamIdentifier=TEAM123456\nAuthority=Developer ID Application: Test (TEAM123456)';
        const reqOutput = 'designated => identifier "com.saariuslystoned.agy-computer-use.host" or certificate leaf[subject.OU] = "TEAM123456"';
        const res = parseAndClassifyPrincipal(codesignOutput, reqOutput, true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('12. Contradictory/duplicate requirement predicates -> unsigned_or_invalid', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=signed\nTeamIdentifier=TEAM123456\nAuthority=Developer ID Application: Test (TEAM123456)';
        const reqOutput = 'designated => identifier "com.saariuslystoned.agy-computer-use.host" and identifier "com.other.app" and certificate leaf[subject.OU] = "TEAM123456"';
        const res = parseAndClassifyPrincipal(codesignOutput, reqOutput, true);
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('13. --require-stable on ad-hoc -> ad_hoc_ephemeral with error', () => {
        const codesignOutput = 'Identifier=com.saariuslystoned.agy-computer-use.host\nSignature=adhoc\nTeamIdentifier=not set';
        const res = parseAndClassifyPrincipal(codesignOutput, '', true, { requireStable: true });
        assert.equal(res.classification, 'ad_hoc_ephemeral');
        assert.ok(res.error);
    });
});

test('E2-P2: Component-aware stage target directory validation discriminators', () => {
    const testRoot = fs.mkdtempSync('/tmp/agy-target-val-');
    try {
        // 1. Equal root rejection
        assert.throws(() => validateStageTargetDir(testRoot, testRoot), /cannot be equal to allowed root/);

        // 2. Sibling prefix rejection (/tmp/agy-target-val-sibling vs /tmp/agy-target-val-)
        const siblingDir = testRoot + '-sibling';
        assert.throws(() => validateStageTargetDir(siblingDir, testRoot), /not strictly contained within allowed root/);

        // 3. Parent traversal escape rejection
        const traversalDir = path.join(testRoot, '../outside');
        assert.throws(() => validateStageTargetDir(traversalDir, testRoot), /not strictly contained within allowed root/);

        // 4. Valid nested target passes
        const validSubdir = path.join(testRoot, 'sub/target.app');
        assert.equal(validateStageTargetDir(validSubdir, testRoot), path.join(fs.realpathSync(testRoot), 'sub/target.app'));

        // 5. Symlinked allowed root pointing outside rejection & mutant proof
        const realOutsideDir = fs.mkdtempSync('/tmp/agy-outside-real-');
        const outsideSentinel = path.join(realOutsideDir, 'sentinel.txt');
        fs.writeFileSync(outsideSentinel, 'SAFE');

        const symlinkRoot = path.join(testRoot, 'symlink-root');
        fs.symlinkSync(realOutsideDir, symlinkRoot);

        assert.throws(() => validateStageTargetDir(path.join(symlinkRoot, 'sub.app'), symlinkRoot), /cannot be a symbolic link/);
        assert.equal(fs.existsSync(outsideSentinel), true, 'Outside sentinel must survive symlinked root rejection');
        fs.rmSync(realOutsideDir, { recursive: true, force: true });
    } finally {
        fs.rmSync(testRoot, { recursive: true, force: true });
    }
});

test('AR-P2: Clean-export discriminator for fresh checkout staging', async () => {
    const exportTmpDir = fs.mkdtempSync('/tmp/agy-clean-export-');
    fs.chmodSync(exportTmpDir, 0o700);

    try {
        fs.cpSync(process.cwd(), exportTmpDir, {
            recursive: true,
            filter: (src) => {
                const rel = path.relative(process.cwd(), src);
                if (rel.includes('.build') || rel.includes('.git') || rel.includes('node_modules')) {
                    return false;
                }
                return true;
            }
        });

        assert.equal(fs.existsSync(path.join(exportTmpDir, 'apps/computer-use-host/.build')), false, 'Clean export must not contain pre-existing .build directory');

        const binScript = path.join(exportTmpDir, 'bin/host-app.mjs');
        const { stageHostApp: exportStageHostApp, classifyPrincipal: exportClassifyPrincipal } = await import(`file://${binScript}`);

        const stageRes = await exportStageHostApp({ projectRoot: exportTmpDir, build: true });
        assert.equal(stageRes.success, true);
        assert.equal(fs.existsSync(stageRes.appPath), true, 'Staged app must exist in clean export');

        const classification = await exportClassifyPrincipal(stageRes.appPath);
        assert.equal(classification.classification, 'ad_hoc_ephemeral', 'Staged app in clean export must classify as ad_hoc_ephemeral');

        const stableCheck = await exportClassifyPrincipal(stageRes.appPath, { requireStable: true });
        assert.equal(stableCheck.classification, 'ad_hoc_ephemeral');
        assert.ok(stableCheck.error, '--require-stable must produce error for ad_hoc_ephemeral');
    } finally {
        fs.rmSync(exportTmpDir, { recursive: true, force: true });
    }
});

test('RP-3: Prove deterministic restaging of one built input', async () => {
    const initialStage = await stageHostApp({ build: true });
    assert.equal(initialStage.success, true);
    const initialBinaryHash = crypto.createHash('sha256').update(fs.readFileSync(initialStage.binaryPath)).digest('hex');
    const initialPlistHash = crypto.createHash('sha256').update(fs.readFileSync(initialStage.infoPlistPath)).digest('hex');

    const stage1 = await stageHostApp({ build: false });
    const digest1 = computeTreeDigest(stage1.appPath);
    const binaryHash1 = crypto.createHash('sha256').update(fs.readFileSync(stage1.binaryPath)).digest('hex');
    const plistHash1 = crypto.createHash('sha256').update(fs.readFileSync(stage1.infoPlistPath)).digest('hex');

    assert.equal(binaryHash1, initialBinaryHash, 'Binary hash must match built input');
    assert.equal(plistHash1, initialPlistHash, 'Plist hash must match built input');
    assert.equal(fs.statSync(stage1.binaryPath).mode & 0o777, 0o755, 'Executable mode must be 0755');

    const stage2 = await stageHostApp({ build: false });
    const digest2 = computeTreeDigest(stage2.appPath);

    assert.equal(digest1, digest2, 'Tree digests of restaged built input must be identical');
});

test('RL-3: Bounded real subprocess smoke tests for SIGTERM and SIGINT', async (t) => {
    const stageRes = await stageHostApp();
    const stagedAppBinary = stageRes.binaryPath;

    await t.test('Subprocess handles SIGTERM cleanly, unlinks socket, preserves lock file and inode, and permits second bind', async () => {
        await runBoundedSubprocessTest(stagedAppBinary, 'SIGTERM');
    });

    await t.test('Subprocess handles SIGINT cleanly, unlinks socket, preserves lock file and inode, and permits second bind', async () => {
        await runBoundedSubprocessTest(stagedAppBinary, 'SIGINT');
    });
});

test('A-L3: Bounded supervisor unit tests for spawn error, early exit, timeout, SIGKILL escalation, and idempotent cleanup', async (t) => {
    await t.test('1. Early exit before socket creation is detected cleanly', async () => {
        const mon = spawnAndMonitor('/usr/bin/false', [], {});
        await assert.rejects(
            async () => await waitForSocketOrExit(mon, '/tmp/nonexistent.sock', 1000),
            /exited prematurely with code 1/
        );
        const code = await reapChild(mon, 1000);
        assert.equal(code, 1);
    });

    await t.test('2. Non-existent binary spawn error is captured cleanly', async () => {
        const mon = spawnAndMonitor('/tmp/nonexistent-binary-path-12345', [], {});
        await assert.rejects(
            async () => await waitForSocketOrExit(mon, '/tmp/nonexistent.sock', 1000),
            /exited prematurely/
        );
        const code = await reapChild(mon, 1000);
        assert.equal(code, -1);
    });

    await t.test('3. Bounded readiness timeout triggers when socket never appears', async () => {
        const mon = spawnAndMonitor('/bin/sleep', ['10'], {});
        try {
            await assert.rejects(
                async () => await waitForSocketOrExit(mon, '/tmp/nonexistent.sock', 200),
                /Timed out waiting for socket creation/
            );
        } finally {
            mon.proc.kill('SIGKILL');
            await reapChild(mon, 1000);
        }
    });

    await t.test('4. Graceful termination escalation to SIGKILL if process ignores SIGTERM', async () => {
        const mon = spawnAndMonitor(process.execPath, ['-e', 'process.on("SIGTERM", ()=>{}); setInterval(()=>{}, 1000)'], {});
        await new Promise(r => setTimeout(r, 100));
        mon.proc.kill('SIGTERM');
        const start = Date.now();
        const code = await reapChild(mon, 200);
        const elapsed = Date.now() - start;
        assert.ok(elapsed >= 150, `Must wait for grace period before SIGKILL, got ${elapsed}ms`);
        assert.ok(mon.isExited());
    });

    await t.test('5. Idempotent child reaping handles already exited process without error', async () => {
        const mon = spawnAndMonitor('/usr/bin/true', [], {});
        const code1 = await reapChild(mon, 1000);
        assert.equal(code1, 0);
        const code2 = await reapChild(mon, 1000);
        assert.equal(code2, 0);
    });
});
