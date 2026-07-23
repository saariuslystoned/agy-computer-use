import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn, execFileSync, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { buildHostRelease, stageBuiltHostApp, stageHostApp, classifyPrincipal, parseAndClassifyPrincipal, validateStageTargetDir, TestStagingHarness } from './host-app.mjs';

const execFileAsync = promisify(execFile);

function createOutsideSentinelTree(outsideDir) {
    fs.mkdirSync(path.join(outsideDir, 'sub'), { mode: 0o700 });
    fs.writeFileSync(path.join(outsideDir, 'sentinel.txt'), 'SENTINEL_DATA_MUST_NOT_MUTATE');
    fs.writeFileSync(path.join(outsideDir, 'sub/nested.txt'), 'NESTED_DATA_MUST_NOT_MUTATE');
    fs.symlinkSync('sentinel.txt', path.join(outsideDir, 'link.txt'));
}

function snapshotTree(dirPath) {
    const entries = [];

    let rootLstat;
    try {
        rootLstat = fs.lstatSync(dirPath);
    } catch (e) {
        if (e.code === 'ENOENT') {
            return [{ rel: '.', type: 'missing', exists: false, dev: null, ino: null }];
        }
        throw e;
    }

    if (rootLstat.isSymbolicLink()) {
        entries.push({
            rel: '.',
            type: 'symlink',
            target: fs.readlinkSync(dirPath),
            mode: rootLstat.mode & 0o7777,
            dev: String(rootLstat.dev),
            ino: String(rootLstat.ino),
            exists: true
        });
    } else if (rootLstat.isDirectory()) {
        entries.push({
            rel: '.',
            type: 'directory',
            mode: rootLstat.mode & 0o7777,
            dev: String(rootLstat.dev),
            ino: String(rootLstat.ino),
            exists: true
        });
    } else {
        const content = fs.readFileSync(dirPath);
        const hash = crypto.createHash('sha256').update(content).digest('hex');
        entries.push({
            rel: '.',
            type: 'file',
            hash,
            size: content.length,
            mode: rootLstat.mode & 0o7777,
            dev: String(rootLstat.dev),
            ino: String(rootLstat.ino),
            exists: true
        });
    }

    if (rootLstat.isDirectory()) {
        function walk(currentRel) {
            const fullPath = path.join(dirPath, currentRel);
            const items = fs.readdirSync(fullPath).sort();
            for (const item of items) {
                const rel = path.join(currentRel, item);
                const itemPath = path.join(dirPath, rel);
                const lstat = fs.lstatSync(itemPath);
                if (lstat.isSymbolicLink()) {
                    entries.push({
                        rel,
                        type: 'symlink',
                        target: fs.readlinkSync(itemPath),
                        mode: lstat.mode & 0o7777,
                        dev: String(lstat.dev),
                        ino: String(lstat.ino),
                        exists: true
                    });
                } else if (lstat.isDirectory()) {
                    entries.push({
                        rel,
                        type: 'directory',
                        mode: lstat.mode & 0o7777,
                        dev: String(lstat.dev),
                        ino: String(lstat.ino),
                        exists: true
                    });
                    walk(rel);
                } else {
                    const content = fs.readFileSync(itemPath);
                    const hash = crypto.createHash('sha256').update(content).digest('hex');
                    entries.push({
                        rel,
                        type: 'file',
                        hash,
                        size: content.length,
                        mode: lstat.mode & 0o7777,
                        dev: String(lstat.dev),
                        ino: String(lstat.ino),
                        exists: true
                    });
                }
            }
        }
        walk('');
    }

    return entries;
}

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
    if (proc.stdout) proc.stdout.resume();
    if (proc.stderr) proc.stderr.resume();
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
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-shell-inj-'));
    fs.chmodSync(tmpDir, 0o700);

    const sentinelPath = path.join(tmpDir, 'pwned_sentinel.txt');
    const injectionPath = path.join(tmpDir, `test app; touch "${sentinelPath}"; echo/App.app`);
    const binPath = path.resolve('bin/agy-computer-use');

    try {
        let stdout = '';
        try {
            stdout = execFileSync(process.execPath, [binPath, 'host-principal', '--app', injectionPath], {
                encoding: 'utf-8',
                stdio: ['ignore', 'pipe', 'pipe']
            });
        } catch (err) {
            stdout = (err.stdout || '') + (err.stderr || '');
        }

        assert.equal(fs.existsSync(sentinelPath), false, 'Shell injection target sentinel must NOT be created');
        assert.ok(stdout.includes('unsigned_or_invalid'), 'Must report unsigned_or_invalid for non-existent path');
    } finally {
        fs.rmSync(tmpDir, { recursive: true, force: true });
    }
});

test('RP-2: Complete production-bound principal classification authority table', async (t) => {
    const validAdHocCodesign = 'Executable=/path/to/app\nIdentifier=com.saariuslystoned.agy-computer-use.host\nFormat=app bundle\nSignature=adhoc\nTeamIdentifier=not set';
    const validAdHocReq = 'Executable=/path/to/app\ndesignated => identifier "com.saariuslystoned.agy-computer-use.host"';

    const validCanonicalTeamCodesign = 'Executable=/path/to/app\nIdentifier=com.saariuslystoned.agy-computer-use.host\nFormat=app bundle\nSignature size=4520\nAuthority=Developer ID Application: Test (ABCDE12345)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nSigned Time=Jul 21, 2026\nTeamIdentifier=ABCDE12345';
    const validCanonicalTeamReq = 'Executable=/path/to/app\ndesignated => identifier "com.saariuslystoned.agy-computer-use.host" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = ABCDE12345';

    const validMinimalTeamCodesign = 'Executable=/path/to/app\nIdentifier=com.saariuslystoned.agy-computer-use.host\nSignature size=100\nAuthority=Developer ID Application: Test (ABCDE12345)\nTeamIdentifier=ABCDE12345';
    const validMinimalTeamReq = 'Executable=/path/to/app\ndesignated => identifier "com.saariuslystoned.agy-computer-use.host" and anchor apple generic and certificate leaf[subject.OU] = ABCDE12345';

    await t.test('Positive 1: Canonical ad-hoc -> ad_hoc_ephemeral', () => {
        const res = parseAndClassifyPrincipal(validAdHocCodesign, validAdHocReq, true);
        assert.equal(res.classification, 'ad_hoc_ephemeral');
        assert.equal(res.identifier, 'com.saariuslystoned.agy-computer-use.host');
        assert.equal(res.teamId, null);
    });

    await t.test('Positive 2: Canonical three-authority team -> stable_team_signed_candidate', () => {
        const res = parseAndClassifyPrincipal(validCanonicalTeamCodesign, validCanonicalTeamReq, true);
        assert.equal(res.classification, 'stable_team_signed_candidate');
        assert.equal(res.identifier, 'com.saariuslystoned.agy-computer-use.host');
        assert.equal(res.teamId, 'ABCDE12345');
    });

    await t.test('Positive 3: Minimal one-authority team -> stable_team_signed_candidate', () => {
        const res = parseAndClassifyPrincipal(validMinimalTeamCodesign, validMinimalTeamReq, true);
        assert.equal(res.classification, 'stable_team_signed_candidate');
        assert.equal(res.identifier, 'com.saariuslystoned.agy-computer-use.host');
        assert.equal(res.teamId, 'ABCDE12345');
    });

    function replaceExactToken(sourceStr, targetToken, replacementToken) {
        const count = sourceStr.split(targetToken).length - 1;
        assert.equal(count, 1, `Target token '${targetToken}' must occur exactly once in source template (found ${count})`);
        return sourceStr.replace(targetToken, replacementToken);
    }

    const negativeCases = [
        // Verification negative
        { name: 'Metadata negative: Verification false -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validCanonicalTeamReq, verified: false },

        // Signature negatives
        { name: 'Metadata negative: Missing signature record -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Signature size=4520\n', ''), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Malformed signature -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Signature size=4520', 'Signature=corrupt'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Signature=signed -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Signature size=4520', 'Signature=signed'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Zero signature size -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Signature size=4520', 'Signature size=0'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Leading-zero signature size -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Signature size=4520', 'Signature size=04520'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Invented Signature=size=4520 -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Signature size=4520', 'Signature=size=4520'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Duplicate signature -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign + '\nSignature size=100', req: validCanonicalTeamReq, verified: true },

        // Identifier negatives
        { name: 'Metadata negative: Missing identifier -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Identifier=com.saariuslystoned.agy-computer-use.host\n', ''), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Empty identifier -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Identifier=com.saariuslystoned.agy-computer-use.host', 'Identifier='), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Duplicate identifier -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign + '\nIdentifier=com.saariuslystoned.agy-computer-use.host', req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Wrong identifier -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'com.saariuslystoned.agy-computer-use.host', 'com.other.app'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Leading-whitespace identifier value -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Identifier=com.saariuslystoned.agy-computer-use.host', 'Identifier= com.saariuslystoned.agy-computer-use.host'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Identifier with trailing whitespace -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Identifier=com.saariuslystoned.agy-computer-use.host', 'Identifier=com.saariuslystoned.agy-computer-use.host '), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Identifier prefix -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, '\nIdentifier=', '\nprefix Identifier='), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Identifier substring -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'com.saariuslystoned.agy-computer-use.host', 'com.saariuslystoned.agy-computer-use'), req: validCanonicalTeamReq, verified: true },

        // TeamIdentifier negatives
        { name: 'Metadata negative: Missing TeamIdentifier -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'TeamIdentifier=ABCDE12345', ''), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Empty TeamIdentifier -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'TeamIdentifier=ABCDE12345', 'TeamIdentifier='), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Duplicate TeamIdentifier -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign + '\nTeamIdentifier=ABCDE12345', req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Wrong TeamIdentifier -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'TeamIdentifier=ABCDE12345', 'TeamIdentifier=OTHER12345'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Leading-whitespace TeamIdentifier value -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'TeamIdentifier=ABCDE12345', 'TeamIdentifier= ABCDE12345'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: TeamIdentifier trailing whitespace -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'TeamIdentifier=ABCDE12345', 'TeamIdentifier=ABCDE12345 '), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: TeamIdentifier prefix -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'TeamIdentifier=', 'prefix TeamIdentifier='), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: TeamIdentifier substring -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'TeamIdentifier=ABCDE12345', 'TeamIdentifier=ABCD'), req: validCanonicalTeamReq, verified: true },

        // Authority negatives
        { name: 'Metadata negative: No authority -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Authority=Developer ID Application: Test (ABCDE12345)\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\n', ''), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Empty first authority -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Authority=Developer ID Application: Test (ABCDE12345)', 'Authority='), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Empty middle authority -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Authority=Developer ID Certification Authority', 'Authority='), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Empty final authority -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Authority=Apple Root CA', 'Authority='), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Authority=adhoc -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Authority=Developer ID Application: Test (ABCDE12345)', 'Authority=adhoc'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Authority=not set -> unsigned_or_invalid', codesign: replaceExactToken(validCanonicalTeamCodesign, 'Authority=Developer ID Application: Test (ABCDE12345)', 'Authority=not set'), req: validCanonicalTeamReq, verified: true },
        { name: 'Metadata negative: Exact ad hoc plus Authority=adhoc -> unsigned_or_invalid', codesign: validAdHocCodesign + '\nAuthority=adhoc', req: validAdHocReq, verified: true },
        { name: 'Metadata negative: Exact ad hoc plus Authority=not set -> unsigned_or_invalid', codesign: validAdHocCodesign + '\nAuthority=not set', req: validAdHocReq, verified: true },
        { name: 'Metadata negative: Exact ad hoc plus non-not set TeamIdentifier -> unsigned_or_invalid', codesign: replaceExactToken(validAdHocCodesign, 'TeamIdentifier=not set', 'TeamIdentifier=ABCDE12345'), req: validAdHocReq, verified: true },
        { name: 'Metadata negative: Ad-hoc plus team authority -> unsigned_or_invalid', codesign: validAdHocCodesign + '\nAuthority=Developer ID Application: Test', req: validAdHocReq, verified: true },

        // Requirement record negatives
        { name: 'Requirement record negative: Missing Executable= -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'Executable=/path/to/app\n', ''), verified: true },
        { name: 'Requirement record negative: Empty Executable= value -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'Executable=/path/to/app', 'Executable='), verified: true },
        { name: 'Requirement record negative: Duplicate Executable= -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: 'Executable=/path/to/app\n' + validCanonicalTeamReq, verified: true },
        { name: 'Requirement record negative: Reordered requirement records -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: 'designated => identifier "com.saariuslystoned.agy-computer-use.host" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = ABCDE12345\nExecutable=/path/to/app', verified: true },
        { name: 'Requirement record negative: Prefixed Executable= -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'Executable=', 'prefix Executable='), verified: true },
        { name: 'Requirement record negative: Suffixed Executable= -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'Executable=/path/to/app', 'Executable=/path/to/app '), verified: true },
        {
            name: 'Requirement record negative: Record-leading-whitespace Executable= -> unsigned_or_invalid',
            codesign: validCanonicalTeamCodesign,
            req: (() => {
                const r = replaceExactToken(validCanonicalTeamReq, 'Executable=', ' Executable=');
                assert.ok(r.startsWith(' Executable='), 'Fixture must begin with leading space before Executable=');
                return r;
            })(),
            verified: true
        },
        { name: 'Requirement record negative: Value-leading-whitespace Executable= -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'Executable=', 'Executable= '), verified: true },
        { name: 'Requirement record negative: Missing designated record -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: 'Executable=/path/to/app', verified: true },
        { name: 'Requirement record negative: Empty designated record -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: 'Executable=/path/to/app\ndesignated => ', verified: true },
        { name: 'Requirement record negative: Duplicate designated record -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validCanonicalTeamReq + '\ndesignated => identifier "com.saariuslystoned.agy-computer-use.host"', verified: true },
        { name: 'Requirement record negative: Prefixed designated record -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'designated => ', 'prefix designated => '), verified: true },
        { name: 'Requirement record negative: Suffixed designated record -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validCanonicalTeamReq + ' ', verified: true },
        {
            name: 'Requirement record negative: Record-leading-whitespace designated => -> unsigned_or_invalid',
            codesign: validCanonicalTeamCodesign,
            req: (() => {
                const r = replaceExactToken(validCanonicalTeamReq, '\ndesignated =>', '\n designated =>');
                assert.ok(r.includes('\n designated =>'), 'Second record fixture must begin with leading space before designated =>');
                return r;
            })(),
            verified: true
        },
        { name: 'Requirement record negative: Value-leading-whitespace designated => -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'designated => ', 'designated =>  '), verified: true },
        { name: 'Requirement record negative: Extra third record -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validCanonicalTeamReq + '\nExtraField=123', verified: true },
        { name: 'Requirement record negative: Leading blank record -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: '\n' + validCanonicalTeamReq, verified: true },
        { name: 'Requirement record negative: Interior blank record -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, '\ndesignated =>', '\n\ndesignated =>'), verified: true },
        { name: 'Requirement record negative: Multiple trailing blank records -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validCanonicalTeamReq + '\n\n', verified: true },
        { name: 'Requirement record negative: and without exact surrounding spaces -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validMinimalTeamReq, ' and anchor apple generic', 'and anchor apple generic'), verified: true },

        {
            name: 'Requirement record negative: Doubled conjunction token -> unsigned_or_invalid',
            codesign: validCanonicalTeamCodesign,
            req: (() => {
                const doubledConjFix = replaceExactToken(validMinimalTeamReq, ' and anchor apple generic', ' and and anchor apple generic');
                const emptyAtomFix = replaceExactToken(validMinimalTeamReq, ' and anchor apple generic', ' and  and anchor apple generic');
                assert.notEqual(doubledConjFix, emptyAtomFix, 'Doubled conjunction token and empty atom fixtures must be byte-distinct strings');
                assert.equal((doubledConjFix.match(/\band\b/g) || []).length, 3, 'Doubled conjunction token fixture must contain 3 lexical and tokens');
                assert.ok(!doubledConjFix.split(' and ').includes(''), 'Doubled conjunction token fixture must not produce empty atom under split(" and ")');
                return doubledConjFix;
            })(),
            verified: true
        },
        {
            name: 'Requirement record negative: Empty atom in requirement -> unsigned_or_invalid',
            codesign: validCanonicalTeamCodesign,
            req: (() => {
                const emptyAtomFix = replaceExactToken(validMinimalTeamReq, ' and anchor apple generic', ' and  and anchor apple generic');
                assert.ok(emptyAtomFix.split(' and ').includes(''), 'Empty atom fixture must produce empty string element under split(" and ")');
                return emptyAtomFix;
            })(),
            verified: true
        },
        { name: 'Requirement record negative: Alternate whitespace around separator -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validMinimalTeamReq, ' and anchor apple generic', '  and  anchor apple generic'), verified: true },
        { name: 'Requirement record negative: Disallowed OR -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validMinimalTeamReq, ' and anchor apple generic', ' or anchor apple generic'), verified: true },
        { name: 'Requirement record negative: Disallowed || -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validMinimalTeamReq, ' and anchor apple generic', ' || anchor apple generic'), verified: true },

        // Requirement atom negatives
        { name: 'Requirement atom negative: Metadata/requirement identifier mismatch -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'identifier "com.saariuslystoned.agy-computer-use.host"', 'identifier "com.other.app"'), verified: true },
        { name: 'Requirement atom negative: Team ID/OU mismatch -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'certificate leaf[subject.OU] = ABCDE12345', 'certificate leaf[subject.OU] = OTHER12345'), verified: true },
        { name: 'Requirement atom negative: Quoted OU -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'certificate leaf[subject.OU] = ABCDE12345', 'certificate leaf[subject.OU] = "ABCDE12345"'), verified: true },
        { name: 'Requirement atom negative: OU prefix -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'certificate leaf[subject.OU] = ABCDE12345', 'prefix certificate leaf[subject.OU] = ABCDE12345'), verified: true },
        { name: 'Requirement atom negative: OU substring -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'certificate leaf[subject.OU] = ABCDE12345', 'certificate leaf[subject.OU] = ABCD'), verified: true },
        { name: 'Requirement atom negative: Unterminated OU quote -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'certificate leaf[subject.OU] = ABCDE12345', 'certificate leaf[subject.OU] = "ABCDE12345'), verified: true },
        { name: 'Requirement atom negative: Malformed quote in identifier -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'identifier "com.saariuslystoned.agy-computer-use.host"', 'identifier "com.saariuslystoned.agy-computer-use.host'), verified: true },
        { name: 'Requirement atom negative: Requirement identifier prefix -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'identifier "com.saariuslystoned.agy-computer-use.host"', 'prefix identifier "com.saariuslystoned.agy-computer-use.host"'), verified: true },
        { name: 'Requirement atom negative: Requirement identifier substring -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'identifier "com.saariuslystoned.agy-computer-use.host"', 'identifier "com.saariuslystoned.agy-computer-use"'), verified: true },
        { name: 'Requirement atom negative: Unrelated leading atom -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'designated => ', 'designated => extraAtom and '), verified: true },
        { name: 'Requirement atom negative: Missing identifier atom -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validMinimalTeamReq, 'identifier "com.saariuslystoned.agy-computer-use.host" and ', ''), verified: true },
        { name: 'Requirement atom negative: Missing anchor atom -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validMinimalTeamReq, 'and anchor apple generic ', ''), verified: true },
        { name: 'Requirement atom negative: Missing OU atom -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validMinimalTeamReq, ' and certificate leaf[subject.OU] = ABCDE12345', ''), verified: true },
        { name: 'Requirement atom negative: Duplicate identifier atom -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validMinimalTeamReq + ' and identifier "com.saariuslystoned.agy-computer-use.host"', verified: true },
        { name: 'Requirement atom negative: Duplicate anchor atom -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validMinimalTeamReq + ' and anchor apple generic', verified: true },
        { name: 'Requirement atom negative: Duplicate OU atom -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validMinimalTeamReq + ' and certificate leaf[subject.OU] = ABCDE12345', verified: true },
        { name: 'Requirement atom negative: Unknown OID -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: replaceExactToken(validCanonicalTeamReq, 'certificate 1[field.1.2.840.113635.100.6.2.6]', 'certificate 1.2.840.113635.100.6.1.99'), verified: true },
        { name: 'Requirement atom negative: Duplicate allowlisted OID 1 -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validCanonicalTeamReq + ' and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */', verified: true },
        { name: 'Requirement atom negative: Duplicate allowlisted OID 2 -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validCanonicalTeamReq + ' and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */', verified: true },
        { name: 'Requirement atom negative: Unrelated trailing atom -> unsigned_or_invalid', codesign: validCanonicalTeamCodesign, req: validCanonicalTeamReq + ' and extraAtom', verified: true },

        // --require-stable option test
        { name: 'Option negative: --require-stable on ad-hoc -> ad_hoc_ephemeral with error', codesign: validAdHocCodesign, req: validAdHocReq, verified: true, requireStable: true }
    ];

    for (const c of negativeCases) {
        await t.test(c.name, () => {
            const res = parseAndClassifyPrincipal(c.codesign, c.req, c.verified, { requireStable: c.requireStable });
            if (c.requireStable) {
                assert.equal(res.classification, 'ad_hoc_ephemeral');
                assert.equal(res.error, 'Staged app is ad_hoc_ephemeral; --require-stable specified');
            } else {
                assert.equal(res.classification, 'unsigned_or_invalid', `Must return unsigned_or_invalid for case '${c.name}'`);
            }
        });
    }
});

test('AR-P1: Recording runner test for classifyPrincipal', async () => {
    const stageRes = await stageHostApp();
    const appPath = stageRes.appPath;

    const recordedCalls = [];

    const canonicalStderrDV = 'Executable=/path/to/ComputerUseHost\nIdentifier=com.saariuslystoned.agy-computer-use.host\nFormat=app bundle\nSignature size=4520\nAuthority=Developer ID Application: Test (ABCDE12345)\nTeamIdentifier=ABCDE12345\n';
    const canonicalStderrExec = 'Executable=/path/to/ComputerUseHost\n';
    const canonicalStdoutR = 'designated => identifier "com.saariuslystoned.agy-computer-use.host" and anchor apple generic and certificate leaf[subject.OU] = ABCDE12345\n';

    const fakeSuccessRunner = async (cmd, args) => {
        recordedCalls.push({ cmd, args });
        if (args.includes('--verify')) {
            return { stdout: '', stderr: '' };
        }
        if (args.includes('-dv')) {
            return { stdout: '', stderr: canonicalStderrDV };
        }
        if (args.includes('-r-')) {
            return { stdout: canonicalStdoutR, stderr: canonicalStderrExec };
        }
        throw new Error(`Unexpected args: ${args.join(' ')}`);
    };

    const res = await classifyPrincipal(appPath, { execFileAsync: fakeSuccessRunner });
    assert.equal(res.classification, 'stable_team_signed_candidate');
    assert.equal(res.teamId, 'ABCDE12345');

    assert.equal(recordedCalls.length, 3, 'Must record exactly 3 codesign invocations');
    assert.deepEqual(recordedCalls[0], { cmd: 'codesign', args: ['--verify', '--strict', appPath] });
    assert.deepEqual(recordedCalls[1], { cmd: 'codesign', args: ['-dv', '--verbose=4', appPath] });
    assert.deepEqual(recordedCalls[2], { cmd: 'codesign', args: ['-d', '-r-', appPath] });

    const failRecordedCalls = [];
    const failingRunner = async (cmd, args) => {
        failRecordedCalls.push({ cmd, args });
        if (args.includes('--verify')) {
            throw new Error('Verification failed');
        }
        if (args.includes('-dv')) {
            return { stdout: '', stderr: canonicalStderrDV };
        }
        if (args.includes('-r-')) {
            return { stdout: canonicalStdoutR, stderr: canonicalStderrExec };
        }
        throw new Error(`Unexpected args: ${args.join(' ')}`);
    };

    const failRes = await classifyPrincipal(appPath, { execFileAsync: failingRunner });
    assert.equal(failRes.classification, 'unsigned_or_invalid', 'Must report unsigned_or_invalid on verification failure');
    assert.equal(failRecordedCalls.length, 3, 'Must execute all 3 commands even on verification failure');
    assert.deepEqual(failRecordedCalls[0], { cmd: 'codesign', args: ['--verify', '--strict', appPath] });
    assert.deepEqual(failRecordedCalls[1], { cmd: 'codesign', args: ['-dv', '--verbose=4', appPath] });
    assert.deepEqual(failRecordedCalls[2], { cmd: 'codesign', args: ['-d', '-r-', appPath] });

    const mutantRes = parseAndClassifyPrincipal(canonicalStderrDV, canonicalStderrExec + canonicalStdoutR, true);
    assert.equal(mutantRes.classification, 'stable_team_signed_candidate', 'Mutant ignoring verification would return stable_team_signed_candidate');
});

function runAllDeferredCleanups(cleanups) {
    let firstError = null;
    for (const fn of cleanups) {
        try {
            fn();
        } catch (e) {
            if (!firstError) {
                firstError = e;
            }
        }
    }
    if (firstError) {
        throw firstError;
    }
}

test('E2-P2: Rejection table for stage target directory validation', async () => {
    // Helper to test each rejection sub-case with complete outside tree snapshot validation
    async function testRejectionSubcase(name, fn) {
        const parentTmp = fs.mkdtempSync(path.join(os.tmpdir(), `agy-rej-${name}-`));
        fs.chmodSync(parentTmp, 0o700);
        const outsideDir = path.join(parentTmp, 'outside');
        fs.mkdirSync(outsideDir, { mode: 0o700 });
        createOutsideSentinelTree(outsideDir);
        const beforeSnap = snapshotTree(outsideDir);

        const deferredCleanupFns = [];
        const deferCleanup = (cFn) => deferredCleanupFns.push(cFn);

        try {
            await fn(parentTmp, outsideDir, deferCleanup);
            const afterSnap = snapshotTree(outsideDir);
            assert.deepStrictEqual(afterSnap, beforeSnap, `Outside tree must remain completely unchanged for subcase ${name}`);
        } finally {
            try {
                runAllDeferredCleanups(deferredCleanupFns);
            } finally {
                fs.rmSync(parentTmp, { recursive: true, force: true });
            }
        }
    }

    // 1. Missing allowed root rejection
    await testRejectionSubcase('missing', async (parentTmp) => {
        const missingRoot = path.join(parentTmp, 'missing_root');
        assert.throws(
            () => validateStageTargetDir(path.join(missingRoot, 'target.app'), missingRoot),
            /does not exist/
        );
    });

    // 2. Regular file allowed root rejection
    await testRejectionSubcase('regfile', async (parentTmp) => {
        const regFileRoot = path.join(parentTmp, 'reg_file_root');
        fs.writeFileSync(regFileRoot, 'NOT_A_DIR');
        assert.throws(
            () => validateStageTargetDir(path.join(regFileRoot, 'target.app'), regFileRoot),
            /must be a directory/
        );
    });

    // 3. Symlink allowed root rejection
    await testRejectionSubcase('symroot', async (parentTmp, outsideDir) => {
        const symlinkRoot = path.join(parentTmp, 'symlink_root');
        fs.symlinkSync(outsideDir, symlinkRoot);
        assert.throws(
            () => validateStageTargetDir(path.join(symlinkRoot, 'target.app'), symlinkRoot),
            /cannot be a symbolic link/
        );
    });

    // 4. Non-private mode allowed root rejection
    await testRejectionSubcase('nonpriv', async (parentTmp) => {
        const nonPrivRoot = path.join(parentTmp, 'non_priv_root');
        fs.mkdirSync(nonPrivRoot, { mode: 0o755 });
        assert.throws(
            () => validateStageTargetDir(path.join(nonPrivRoot, 'target.app'), nonPrivRoot),
            /must have private 0700 permissions/
        );
    });

    // 5. Escaping target path rejection
    await testRejectionSubcase('escape', async (parentTmp) => {
        const rootDir = path.join(parentTmp, 'root');
        fs.mkdirSync(rootDir, { mode: 0o700 });
        assert.throws(
            () => validateStageTargetDir(path.join(parentTmp, 'outside.app'), rootDir),
            /is not strictly contained within allowed root/
        );
    });

    // 6. Target equal to root rejection
    await testRejectionSubcase('rootequal', async (parentTmp) => {
        const rootDir = path.join(parentTmp, 'root');
        fs.mkdirSync(rootDir, { mode: 0o700 });
        assert.throws(
            () => validateStageTargetDir(rootDir, rootDir),
            /cannot be equal to allowed root/
        );
    });

    // 7. Sibling prefix escape rejection
    await testRejectionSubcase('sibprefix', async (parentTmp) => {
        const rootDir = path.join(parentTmp, 'root');
        fs.mkdirSync(rootDir, { mode: 0o700 });
        assert.throws(
            () => validateStageTargetDir(path.join(parentTmp, 'root_sibling/target.app'), rootDir),
            /is not strictly contained within allowed root/
        );
    });

    // 8. Target symlink rejection (cleanup deferred until after comparison)
    await testRejectionSubcase('targetsym', async (parentTmp, outsideDir, deferCleanup) => {
        const harness = new TestStagingHarness();
        deferCleanup(() => harness.cleanup());
        const targetSymlink = path.join(harness.rootDir, 'ComputerUseHost.app');
        fs.symlinkSync(outsideDir, targetSymlink);

        await assert.rejects(
            async () => await stageHostApp({ harness, build: false }),
            /cannot be a symbolic link/
        );
        assert.equal(harness.removalSpyCount, 0, 'Removal spy count must be 0 on target symlink rejection');
    });

    // 9. Intermediate component symlink rejection (cleanup deferred until after comparison)
    await testRejectionSubcase('intersym', async (parentTmp, outsideDir, deferCleanup) => {
        const harness = new TestStagingHarness();
        deferCleanup(() => harness.cleanup());
        const interSymlink = path.join(harness.rootDir, 'inter_sym');
        fs.symlinkSync(outsideDir, interSymlink);

        await assert.rejects(
            async () => await stageHostApp({ harness, relativeTarget: 'inter_sym/target.app', build: false }),
            /cannot be a symbolic link/
        );
        assert.equal(harness.removalSpyCount, 0, 'Removal spy count must be 0 on intermediate symlink rejection');
    });

    // 10. Dangling target symlink rejection (cleanup deferred until after comparison)
    await testRejectionSubcase('dangtarget', async (parentTmp, outsideDir, deferCleanup) => {
        const harness = new TestStagingHarness();
        deferCleanup(() => harness.cleanup());
        const danglingTarget = path.join(harness.rootDir, 'ComputerUseHost.app');
        fs.symlinkSync(path.join(outsideDir, 'nonexistent_target'), danglingTarget);
        assert.equal(fs.existsSync(danglingTarget), false, 'Dangling target must return false for existsSync');

        await assert.rejects(
            async () => await stageHostApp({ harness, build: false }),
            /cannot be a symbolic link/
        );
        assert.equal(harness.removalSpyCount, 0, 'Removal spy count must be 0 on dangling target rejection');
    });

    // 11. Dangling intermediate component symlink rejection (cleanup deferred until after comparison)
    await testRejectionSubcase('danginter', async (parentTmp, outsideDir, deferCleanup) => {
        const harness = new TestStagingHarness();
        deferCleanup(() => harness.cleanup());
        const danglingInter = path.join(harness.rootDir, 'dangling_inter');
        fs.symlinkSync(path.join(outsideDir, 'nonexistent_dir'), danglingInter);
        assert.equal(fs.existsSync(danglingInter), false, 'Dangling intermediate must return false for existsSync');

        await assert.rejects(
            async () => await stageHostApp({ harness, relativeTarget: 'dangling_inter/target.app', build: false }),
            /cannot be a symbolic link/
        );
        assert.equal(harness.removalSpyCount, 0, 'Removal spy count must be 0 on dangling intermediate rejection');
    });

    // 12. Parent fixture removal survives a throwing deferred cleanup (ARP2-I2b)
    let capturedParentTmp = null;
    let laterCleanupRan = false;
    const subcaseCleanupErr = new Error('UNIQUE_SUBCASE_CLEANUP_ERROR_67890');

    let caughtSubcaseErr = null;
    try {
        await testRejectionSubcase('cleanuperr', async (parentTmp, outsideDir, deferCleanup) => {
            capturedParentTmp = parentTmp;
            deferCleanup(() => {
                throw subcaseCleanupErr;
            });
            deferCleanup(() => {
                laterCleanupRan = true;
            });
            const missingRoot = path.join(parentTmp, 'missing_root');
            assert.throws(
                () => validateStageTargetDir(path.join(missingRoot, 'target.app'), missingRoot),
                /does not exist/
            );
        });
    } catch (e) {
        caughtSubcaseErr = e;
    }

    assert.strictEqual(caughtSubcaseErr, subcaseCleanupErr, 'testRejectionSubcase must reject with the exact deferred cleanup Error object');
    assert.equal(laterCleanupRan, true, 'Later deferred cleanup must still run after earlier cleanup throws');
    assert.ok(capturedParentTmp, 'Parent tmp directory path must have been captured');
    assert.equal(fs.existsSync(capturedParentTmp), false, 'Captured parentTmp must be deleted even when deferred cleanup throws');
    assert.throws(
        () => fs.lstatSync(capturedParentTmp),
        (e) => e.code === 'ENOENT',
        'lstatSync on capturedParentTmp must throw ENOENT'
    );
});

test('AR-P2: Final revalidation race authority - fixed production target in disposable child', async () => {
    const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
    const parentStagedDir = path.join(repoRoot, 'apps/computer-use-host/.build/staged');
    const parentPreStagedSnap = snapshotTree(parentStagedDir);

    const parentTmp = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-race-prod-child-'));
    fs.chmodSync(parentTmp, 0o700);

    const outsideDir = path.join(parentTmp, 'outside');
    fs.mkdirSync(outsideDir, { mode: 0o700 });
    createOutsideSentinelTree(outsideDir);

    const childScript = path.join(parentTmp, 'child_race.mjs');

    const scriptContent = `
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

function snapshotTree(dirPath) {
    const entries = [];
    let rootLstat;
    try { rootLstat = fs.lstatSync(dirPath); } catch (e) { return [{ rel: '.', type: 'missing', exists: false, dev: null, ino: null }]; }
    if (rootLstat.isSymbolicLink()) entries.push({ rel: '.', type: 'symlink', target: fs.readlinkSync(dirPath), mode: rootLstat.mode & 0o7777, dev: String(rootLstat.dev), ino: String(rootLstat.ino), exists: true });
    else if (rootLstat.isDirectory()) entries.push({ rel: '.', type: 'directory', mode: rootLstat.mode & 0o7777, dev: String(rootLstat.dev), ino: String(rootLstat.ino), exists: true });
    else { entries.push({ rel: '.', type: 'file', hash: crypto.createHash('sha256').update(fs.readFileSync(dirPath)).digest('hex'), size: fs.statSync(dirPath).size, mode: rootLstat.mode & 0o7777, dev: String(rootLstat.dev), ino: String(rootLstat.ino), exists: true }); }
    if (rootLstat.isDirectory()) {
        function walk(currentRel) {
            const fullPath = path.join(dirPath, currentRel);
            const items = fs.readdirSync(fullPath).sort();
            for (const item of items) {
                const rel = path.join(currentRel, item);
                const itemPath = path.join(dirPath, rel);
                const lstat = fs.lstatSync(itemPath);
                if (lstat.isSymbolicLink()) entries.push({ rel, type: 'symlink', target: fs.readlinkSync(itemPath), mode: lstat.mode & 0o7777, dev: String(lstat.dev), ino: String(lstat.ino), exists: true });
                else if (lstat.isDirectory()) { entries.push({ rel, type: 'directory', mode: lstat.mode & 0o7777, dev: String(lstat.dev), ino: String(lstat.ino), exists: true }); walk(rel); }
                else { const content = fs.readFileSync(itemPath); entries.push({ rel, type: 'file', hash: crypto.createHash('sha256').update(content).digest('hex'), size: content.length, mode: lstat.mode & 0o7777, dev: String(lstat.dev), ino: String(lstat.ino), exists: true }); }
            }
        }
        walk('');
    }
    return entries;
}

const outsideDir = process.argv[2];
const repoRoot = process.argv[3];

const hostPackageDir = path.join(repoRoot, 'apps/computer-use-host');
const stagedDir = path.join(hostPackageDir, '.build/staged');
const fixedTargetApp = path.join(stagedDir, 'ComputerUseHost.app');
const backupTargetApp = path.join(stagedDir, 'ComputerUseHost.app.race_backup_' + Date.now());

const origLstatSync = fs.lstatSync;
const origRmSync = fs.rmSync;

function lstatExists(p) {
    try { origLstatSync.call(fs, p); return true; } catch (e) { return false; }
}

const preRenameTargetSnap = snapshotTree(fixedTargetApp);

let preExisted = false;
if (lstatExists(fixedTargetApp)) {
    preExisted = true;
    fs.renameSync(fixedTargetApp, backupTargetApp);
}

let rmCount = 0;
let trackTargetLstat = false;
let targetLstatCount = 0;

fs.lstatSync = function(p, opts) {
    const resolvedP = path.resolve(p);
    const resolvedTarget = path.resolve(fixedTargetApp);
    if (trackTargetLstat && resolvedP === resolvedTarget) {
        targetLstatCount++;
        if (targetLstatCount === 2) {
            trackTargetLstat = false;
            if (lstatExists(fixedTargetApp)) {
                if (origLstatSync.call(fs, fixedTargetApp).isSymbolicLink()) {
                    fs.unlinkSync(fixedTargetApp);
                } else {
                    origRmSync.call(fs, fixedTargetApp, { recursive: true, force: true });
                }
            }
            fs.symlinkSync(outsideDir, fixedTargetApp);
            trackTargetLstat = true;
        }
    }
    return origLstatSync.call(fs, p, opts);
};

fs.rmSync = function(p, opts) {
    const resolvedP = path.resolve(p);
    const resolvedTarget = path.resolve(fixedTargetApp);
    if (trackTargetLstat && resolvedP === resolvedTarget) {
        rmCount++;
    }
    return origRmSync.call(fs, p, opts);
};

let rejected = false;
const beforeSnap = snapshotTree(outsideDir);

try {
    const { stageHostApp } = await import(path.join(repoRoot, 'bin/host-app.mjs'));
    try {
        trackTargetLstat = true;
        await stageHostApp({ build: false });
    } catch (e) {
        if (/cannot be a symbolic link/.test(e.message)) {
            rejected = true;
        } else {
            throw e;
        }
    } finally {
        trackTargetLstat = false;
    }

    const afterSnap = snapshotTree(outsideDir);
    const outsideEqual = JSON.stringify(afterSnap) === JSON.stringify(beforeSnap);

    if (!rejected) throw new Error('Child race expected rejection was not observed');
    if (targetLstatCount !== 2) throw new Error('Child race targetLstatCount must be 2, got ' + targetLstatCount);
    if (rmCount !== 0) throw new Error('Child race rmCount must be 0, got ' + rmCount);
    if (!outsideEqual) throw new Error('Child race outside tree mutated');
} finally {
    fs.rmSync = origRmSync;
    fs.lstatSync = origLstatSync;
    if (lstatExists(fixedTargetApp) && origLstatSync.call(fs, fixedTargetApp).isSymbolicLink()) {
        fs.unlinkSync(fixedTargetApp);
    }
    if (preExisted && lstatExists(backupTargetApp)) {
        fs.renameSync(backupTargetApp, fixedTargetApp);
    }
}

const postRestoreTargetSnap = snapshotTree(fixedTargetApp);
const targetRestored = JSON.stringify(postRestoreTargetSnap) === JSON.stringify(preRenameTargetSnap);
const backupAbsent = !lstatExists(backupTargetApp);

if (!targetRestored) throw new Error('Target snapshot post-restore does not match pre-rename snapshot');
if (!backupAbsent) throw new Error('Backup entry still exists post-restore');

console.log(JSON.stringify({ restored: true, targetLstatCount: 2, rmCount: 0, rejected: true, outsideEqual: true }));
    `;

    fs.writeFileSync(childScript, scriptContent);

    try {
        const stdout = execFileSync(process.execPath, [childScript, outsideDir, repoRoot], {
            encoding: 'utf-8',
            stdio: ['ignore', 'pipe', 'pipe']
        });
        const proof = JSON.parse(stdout.trim());
        assert.equal(proof.rejected, true, 'Child proof rejected must be true');
        assert.equal(proof.targetLstatCount, 2, 'Child proof targetLstatCount must be 2');
        assert.equal(proof.rmCount, 0, 'Child proof rmCount must be 0');
        assert.equal(proof.outsideEqual, true, 'Child proof outsideEqual must be true');
        assert.equal(proof.restored, true, 'Child proof restored must be true');

        const parentPostStagedSnap = snapshotTree(parentStagedDir);
        assert.deepStrictEqual(parentPostStagedSnap, parentPreStagedSnap, 'Parent staging directory snapshot post-child execution must equal pre-child snapshot');
    } finally {
        fs.rmSync(parentTmp, { recursive: true, force: true });
    }
});

test('ARP2-F2: Zero public fixed-production seam module-namespace assertion and ordinary importer staging probe', async () => {
    const hostAppModule = await import('./host-app.mjs');
    const exports = Object.keys(hostAppModule);

    assert.equal(exports.includes('_testValidationHook'), false, '_testValidationHook must NOT be exported');
    assert.equal(exports.includes('_setTestValidationHook'), false, '_setTestValidationHook must NOT be exported');
    assert.deepEqual(exports.sort(), ['TestStagingHarness', 'buildHostRelease', 'classifyPrincipal', 'parseAndClassifyPrincipal', 'stageBuiltHostApp', 'stageHostApp', 'validateStageTargetDir'].sort());

    const hostAppAbsPath = path.resolve('bin/host-app.mjs');
    const probeCode = `
        import * as mod from ${JSON.stringify(hostAppAbsPath)};
        if ('_testValidationHook' in mod || '_setTestValidationHook' in mod) {
            process.exit(2);
        }
        const options = { build: false };
        await mod.stageHostApp(options);
        console.log(JSON.stringify({ staged: true }));
        process.exit(0);
    `;
    const tmpScript = path.join(os.tmpdir(), `agy-seam-probe-${Date.now()}.mjs`);
    fs.writeFileSync(tmpScript, probeCode);
    try {
        const stdout = execFileSync(process.execPath, [tmpScript], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] });
        const res = JSON.parse(stdout.trim());
        assert.equal(res.staged, true, 'Importer probe stageHostApp must resolve cleanly');
    } finally {
        fs.rmSync(tmpScript, { force: true });
    }

    function runObsoleteHookChildProbe(hookKey) {
        const hookProbeCode = `
            import * as mod from ${JSON.stringify(hostAppAbsPath)};
            let callbackCount = 0;
            const harness = new mod.TestStagingHarness();
            const removalsBefore = harness.removalSpyCount;

            let rejected = false;
            try {
                await mod.stageHostApp({
                    harness,
                    build: false,
                    [${JSON.stringify(hookKey)}]: () => { callbackCount++; }
                });
            } catch {
                rejected = true;
            }

            const removalsAfter = harness.removalSpyCount;
            harness.cleanup();

            console.log(JSON.stringify({
                rejected,
                callbackCount,
                removalsBefore,
                removalsAfter
            }));
            process.exit(0);
        `;
        const childScript = path.join(os.tmpdir(), `agy-hook-child-${hookKey}-${Date.now()}.mjs`);
        fs.writeFileSync(childScript, hookProbeCode);
        try {
            const stdout = execFileSync(process.execPath, [childScript], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] });
            const res = JSON.parse(stdout.trim());
            assert.equal(res.rejected, true, `Obsolete hook ${hookKey} child probe must reject`);
            assert.equal(res.callbackCount, 0, `Obsolete hook ${hookKey} callback count must be 0`);
            assert.equal(res.removalsAfter, res.removalsBefore, `Obsolete hook ${hookKey} must not execute removal`);
        } finally {
            fs.rmSync(childScript, { force: true });
        }
    }

    runObsoleteHookChildProbe('_testValidationHook');
    runObsoleteHookChildProbe('_setTestValidationHook');
});

test('ARP2-S3: Nonvacuous snapshotTree oracle direct test', async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-snap-oracle-test-'));
    fs.chmodSync(tmpDir, 0o700);

    try {
        createOutsideSentinelTree(tmpDir);
        const baseSnap = snapshotTree(tmpDir);

        // Mutant 1: chmod root 0700 -> 0755
        fs.chmodSync(tmpDir, 0o755);
        const chmodSnap = snapshotTree(tmpDir);
        assert.notDeepStrictEqual(chmodSnap, baseSnap, 'Chmod of root must alter snapshotTree');

        // Restore chmod
        fs.chmodSync(tmpDir, 0o700);
        assert.deepStrictEqual(snapshotTree(tmpDir), baseSnap, 'Restoring chmod must restore exact snapshotTree equality');

        // Mutant 2: add adjacent file
        const addedFile = path.join(tmpDir, 'added.txt');
        fs.writeFileSync(addedFile, 'ADDED');
        const addSnap = snapshotTree(tmpDir);
        assert.notDeepStrictEqual(addSnap, baseSnap, 'Adding adjacent file must alter snapshotTree');

        // Restore added file
        fs.unlinkSync(addedFile);
        assert.deepStrictEqual(snapshotTree(tmpDir), baseSnap, 'Removing added file must restore exact snapshotTree equality');
    } finally {
        fs.rmSync(tmpDir, { recursive: true, force: true });
    }
});

test('ARP2-I1: Restoration snapshot inode discriminator test', async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-ino-oracle-test-'));
    fs.chmodSync(tmpDir, 0o700);

    try {
        const testFile = path.join(tmpDir, 'recreated.txt');
        fs.writeFileSync(testFile, 'SAME_CONTENT_AND_MODE', { mode: 0o644 });

        const snapBefore = snapshotTree(tmpDir);

        // Recreate file at same path with identical content and mode but new inode
        fs.unlinkSync(testFile);
        fs.writeFileSync(testFile, 'SAME_CONTENT_AND_MODE', { mode: 0o644 });

        const snapAfter = snapshotTree(tmpDir);

        assert.notDeepStrictEqual(snapAfter, snapBefore, 'Recreated file with identical bytes and mode but different inode must alter snapshotTree');
    } finally {
        fs.rmSync(tmpDir, { recursive: true, force: true });
    }
});

test('ARP2-I2a: Deferred cleanup first-error retention and execution order discriminator test', async () => {
    const callOrder = [];
    const firstErr = new Error('UNIQUE_FIRST_CLEANUP_ERROR');
    const secondErr = new Error('UNIQUE_SECOND_CLEANUP_ERROR');

    const cb1 = () => { callOrder.push(1); };
    const cb2 = () => { callOrder.push(2); throw firstErr; };
    const cb3 = () => { callOrder.push(3); throw secondErr; };
    const cb4 = () => { callOrder.push(4); };

    let caughtErr = null;
    try {
        runAllDeferredCleanups([cb1, cb2, cb3, cb4]);
    } catch (e) {
        caughtErr = e;
    }

    assert.strictEqual(caughtErr, firstErr, 'runAllDeferredCleanups must rethrow the exact first Error object by reference');
    assert.notStrictEqual(caughtErr, secondErr, 'runAllDeferredCleanups must NOT rethrow the second Error object');
    assert.deepStrictEqual(callOrder, [1, 2, 3, 4], 'All deferred cleanups must execute in exact registration order');
});

test('ARP2-C2: Negative authority discriminators for TestStagingHarness private identity and state', async () => {
    // 1. Forged truthy brand
    await assert.rejects(
        async () => await stageHostApp({ harness: { _isHarness: true }, build: false }),
        /must be an instance of TestStagingHarness/
    );

    // 2. Proxy around genuine instance with get & getPrototypeOf trap checks
    let trapCount = 0;
    const genuineInstance = new TestStagingHarness();
    const proxyAroundGenuine = new Proxy(genuineInstance, {
        get(target, prop, receiver) {
            trapCount++;
            throw new Error(`Proxy get trap hit for ${String(prop)}`);
        },
        getPrototypeOf(target) {
            trapCount++;
            throw new Error('Proxy getPrototypeOf trap hit');
        }
    });
    await assert.rejects(
        async () => await stageHostApp({ harness: proxyAroundGenuine, build: false }),
        /must be an instance of TestStagingHarness/
    );
    assert.equal(trapCount, 0, 'Proxy get/getPrototypeOf traps must be 0 (WeakMap rejects proxy without dereferencing)');
    genuineInstance.cleanup();

    // 3. Prototype counterfeit rejection
    const prototypeCounterfeit = Object.create(TestStagingHarness.prototype);
    await assert.rejects(
        async () => await stageHostApp({ harness: prototypeCounterfeit, build: false }),
        /must be an instance of TestStagingHarness/
    );

    // 4. Getter / proxy property traps on plain object
    const fakeProxy = new Proxy({}, {
        get() { throw new Error('Proxy trap hit'); }
    });
    await assert.rejects(
        async () => await stageHostApp({ harness: fakeProxy, build: false }),
        /must be an instance of TestStagingHarness/
    );

    // 5. Constructor option rejection
    assert.throws(
        () => new TestStagingHarness({ productionMode: true }),
        /accepts no arguments/
    );
    assert.throws(
        () => new TestStagingHarness('invalid_arg'),
        /accepts no arguments/
    );

    // 6. Direct strict-mode assignment on genuine harness
    const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-shadow-outside-'));
    fs.chmodSync(outsideDir, 0o700);
    createOutsideSentinelTree(outsideDir);
    const beforeSnap = snapshotTree(outsideDir);

    const assignHarness = new TestStagingHarness();
    const assignAuthRoot = assignHarness.rootDir;

    assert.throws(
        () => { 'use strict'; assignHarness.rootDir = outsideDir; },
        TypeError
    );
    assert.equal(Object.prototype.hasOwnProperty.call(assignHarness, 'rootDir'), false, 'Direct assignment must not create own property rootDir');
    await stageHostApp({ harness: assignHarness, build: false });
    assert.deepStrictEqual(snapshotTree(outsideDir), beforeSnap, 'Outside tree must remain untouched');
    assignHarness.cleanup();
    assert.equal(fs.existsSync(assignAuthRoot), false, 'Authentic root must be cleaned after assignment attempt');

    // 7. Instance property shadowing & root assignment ignored by stageHostApp & cleanup
    const harness = new TestStagingHarness();
    const authRoot = harness.rootDir;

    // Subclass rootDir getter override cannot retarget private state
    class SubHarness extends TestStagingHarness {
        get rootDir() { return outsideDir; }
    }
    const subHarness = new SubHarness();
    assert.equal(subHarness.rootDir, outsideDir, 'Subclass getter must return outsideDir');
    await stageHostApp({ harness: subHarness, build: false });
    assert.deepStrictEqual(snapshotTree(outsideDir), beforeSnap, 'Outside tree must be untouched by subHarness staging');
    subHarness.cleanup();
    assert.deepStrictEqual(snapshotTree(outsideDir), beforeSnap, 'Outside tree must be untouched by subHarness cleanup');

    Object.defineProperty(harness, 'rootDir', { value: outsideDir, configurable: true });
    Object.defineProperty(harness, 'beforeRemovalHook', { value: () => { throw new Error('Property hook must not be called'); }, configurable: true });
    Object.defineProperty(harness, 'removalSpyCount', { value: 999, writable: true, configurable: true });

    assert.equal(harness.rootDir, outsideDir, 'Own-property rootDir must shadow getter');

    // stageHostApp must use authentic private root, not assigned outsideDir
    await stageHostApp({ harness, build: false });
    assert.deepStrictEqual(snapshotTree(outsideDir), beforeSnap, 'Outside tree must be untouched by stageHostApp');

    // Remove own-property counter shadow and verify private counter incremented to 1
    delete harness.removalSpyCount;
    assert.equal(harness.removalSpyCount, 1, 'Private removal counter must be exactly 1 after staging');

    // cleanup must clean authentic private root, not assigned outsideDir
    harness.cleanup();
    assert.equal(fs.existsSync(authRoot), false, 'Authentic root must be cleaned');
    assert.deepStrictEqual(snapshotTree(outsideDir), beforeSnap, 'Outside tree must be untouched by cleanup');
    fs.rmSync(outsideDir, { recursive: true, force: true });

    // 8. Cleanup retarget to another prefix-matching private victim seeded with sentinel tree
    const victimHarness = new TestStagingHarness();
    createOutsideSentinelTree(victimHarness.rootDir);
    const victimSnap = snapshotTree(victimHarness.rootDir);

    const attackerHarness = new TestStagingHarness();
    const attackerAuthRoot = attackerHarness.rootDir;

    Object.defineProperty(attackerHarness, 'rootDir', { value: victimHarness.rootDir, configurable: true });
    attackerHarness.cleanup();

    assert.equal(fs.existsSync(victimHarness.rootDir), true, 'Victim directory must exist after attacker cleanup');
    assert.deepStrictEqual(snapshotTree(victimHarness.rootDir), victimSnap, 'Victim tree must be snapshot-identical');
    assert.equal(fs.existsSync(attackerAuthRoot), false, 'Authentic attacker root must be deleted by cleanup');

    victimHarness.cleanup();
    attackerHarness.cleanup();

    // 9. Cleanup after authentic root replaced with new same-path real 0700 directory (inode change)
    const inodeHarness = new TestStagingHarness();
    const inodeAuthRoot = inodeHarness.rootDir;
    fs.rmSync(inodeAuthRoot, { recursive: true, force: true });
    fs.mkdirSync(inodeAuthRoot, { mode: 0o700 });
    fs.writeFileSync(path.join(inodeAuthRoot, 'new_inode_file.txt'), 'NEW_INODE');

    inodeHarness.cleanup();
    assert.equal(fs.existsSync(path.join(inodeAuthRoot, 'new_inode_file.txt')), true, 'Same-path new inode directory must NOT be deleted by cleanup');
    fs.rmSync(inodeAuthRoot, { recursive: true, force: true });

    // 10. Cleanup after authentic root replaced with symlink to outside target
    const symOutside = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-sym-outside-'));
    fs.chmodSync(symOutside, 0o700);
    createOutsideSentinelTree(symOutside);
    const symOutsideSnap = snapshotTree(symOutside);

    const symHarness = new TestStagingHarness();
    const symAuthRoot = symHarness.rootDir;
    fs.rmSync(symAuthRoot, { recursive: true, force: true });
    fs.symlinkSync(symOutside, symAuthRoot);

    symHarness.cleanup();
    assert.deepStrictEqual(snapshotTree(symOutside), symOutsideSnap, 'Target of authentic-root symlink must not be touched');
    fs.unlinkSync(symAuthRoot);
    fs.rmSync(symOutside, { recursive: true, force: true });
});

test('AR-P2: Rejection of ordinary stageHostApp raw and obsolete options', async () => {
    const forbiddenOptions = [
        { key: 'projectRoot', val: '/tmp' },
        { key: 'targetDir', val: '/tmp/target.app' },
        { key: 'allowedTestRoot', val: '/tmp' },
        { key: 'testRoot', val: '/tmp' },
        { key: 'beforeRemovalHook', val: () => {} }
    ];

    for (const item of forbiddenOptions) {
        await assert.rejects(
            async () => await stageHostApp({ [item.key]: item.val, build: false }),
            new RegExp(`Option '${item.key}' is forbidden`)
        );
    }

    await assert.rejects(
        async () => await stageHostApp({ relativeTarget: 'sub.app', build: false }),
        /Option relativeTarget is forbidden without a test harness/
    );

    await assert.rejects(
        async () => await stageHostApp({ harness: {}, build: false }),
        /Option harness must be an instance of TestStagingHarness/
    );
});

test('AR-P2: Clean-export discriminator for fresh checkout staging', async () => {
    const parentTmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-export-authority-'));
    fs.chmodSync(parentTmpDir, 0o700);

    const outsideDir = path.join(parentTmpDir, 'outside');
    fs.mkdirSync(outsideDir, { mode: 0o700 });
    createOutsideSentinelTree(outsideDir);

    const cloneDir = path.join(parentTmpDir, 'clone');
    const exportDir = path.join(parentTmpDir, 'export');
    fs.mkdirSync(exportDir, { mode: 0o700 });

    try {
        const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

        // 1. Create a private local clone at exact candidate HEAD without shell interpolation
        execFileSync('git', ['clone', repoRoot, cloneDir], { stdio: 'ignore' });

        // 2. Deliberately add a dirty marker to tracked bin/host-app.mjs and an untracked file in the clone
        const cloneHostAppMjs = path.join(cloneDir, 'bin/host-app.mjs');
        fs.appendFileSync(cloneHostAppMjs, '\n// DIRTY_WORKTREE_MARKER_MUST_NOT_BE_EXPORTED\n');
        const cloneUntrackedFile = path.join(cloneDir, 'UNTRACKED_FILE_MUST_NOT_BE_EXPORTED.txt');
        fs.writeFileSync(cloneUntrackedFile, 'UNTRACKED');

        // 3. Archive committed HEAD from clone into exportDir without shell interpolation
        const archiveTarPath = path.join(parentTmpDir, 'export.tar');
        execFileSync('git', ['archive', '--output', archiveTarPath, 'HEAD'], { cwd: cloneDir, stdio: 'ignore' });
        execFileSync('tar', ['-xf', archiveTarPath, '-C', exportDir], { stdio: 'ignore' });

        // 4. Assert dirty marker and untracked marker are absent
        const exportedHostAppPath = path.join(exportDir, 'bin/host-app.mjs');
        const exportedHostAppBytes = fs.readFileSync(exportedHostAppPath);
        assert.equal(exportedHostAppBytes.includes('DIRTY_WORKTREE_MARKER'), false, 'Dirty worktree marker must NOT be in clean export');
        assert.equal(fs.existsSync(path.join(exportDir, 'UNTRACKED_FILE_MUST_NOT_BE_EXPORTED.txt')), false, 'Untracked file must NOT be in clean export');

        // 5. Assert exported bin/host-app.mjs bytes match git show HEAD:bin/host-app.mjs
        const gitShowBytes = execFileSync('git', ['show', 'HEAD:bin/host-app.mjs'], { cwd: repoRoot });
        assert.equal(Buffer.compare(exportedHostAppBytes, gitShowBytes), 0, 'Exported bin/host-app.mjs bytes must equal git show HEAD:bin/host-app.mjs');

        // 6. Assert clean export structure (.build, .git, node_modules absent)
        assert.equal(fs.existsSync(path.join(exportDir, 'apps/computer-use-host/.build')), false, 'Clean export must not contain pre-existing .build directory');
        assert.equal(fs.existsSync(path.join(exportDir, '.git')), false, 'Clean export must not contain .git directory');
        assert.equal(fs.existsSync(path.join(exportDir, 'node_modules')), false, 'Clean export must not contain node_modules directory');

        // 7. Execute real exported ./bin/agy-computer-use wrapper for stage-host-app
        const beforeSnap1 = snapshotTree(outsideDir);
        const stageStdout = execFileSync('./bin/agy-computer-use', ['stage-host-app'], { cwd: exportDir, encoding: 'utf-8' });
        const stageRes = JSON.parse(stageStdout.slice(stageStdout.indexOf('{')));

        assert.equal(stageRes.success, true);
        assert.equal(stageRes.appPath, 'apps/computer-use-host/.build/staged/ComputerUseHost.app');
        assert.equal(fs.existsSync(path.join(exportDir, stageRes.appPath)), true, 'Staged app must exist in clean export');

        const stagingRootPath = path.join(exportDir, 'apps/computer-use-host/.build/staged');
        const stagingRootStat = fs.statSync(stagingRootPath);
        assert.equal(stagingRootStat.mode & 0o777, 0o700, 'Staging root in clean export must have 0700 mode');

        const afterSnap1 = snapshotTree(outsideDir);
        assert.deepStrictEqual(afterSnap1, beforeSnap1, 'Outside tree must remain completely unchanged after stage-host-app');

        // 8. Execute real exported ./bin/agy-computer-use host-principal
        const beforeSnap2 = snapshotTree(outsideDir);
        const principalStdout = execFileSync('./bin/agy-computer-use', ['host-principal'], { cwd: exportDir, encoding: 'utf-8' });
        const principalRes = JSON.parse(principalStdout.slice(principalStdout.indexOf('{')));
        assert.equal(principalRes.classification, 'ad_hoc_ephemeral');
        assert.equal(principalRes.identifier, 'com.saariuslystoned.agy-computer-use.host');
        assert.equal(principalRes.teamId, null);

        const afterSnap2 = snapshotTree(outsideDir);
        assert.deepStrictEqual(afterSnap2, beforeSnap2, 'Outside tree must remain completely unchanged after host-principal');

        // 9. Execute real exported ./bin/agy-computer-use host-principal --require-stable
        let stableExit = 0;
        let stableSignal = null;
        let stableStdout = '';
        const beforeSnap3 = snapshotTree(outsideDir);
        try {
            execFileSync('./bin/agy-computer-use', ['host-principal', '--require-stable'], { cwd: exportDir, encoding: 'utf-8' });
            assert.fail('Expected host-principal --require-stable to fail');
        } catch (e) {
            stableExit = e.status;
            stableSignal = e.signal;
            stableStdout = (e.stdout || '') + (e.stderr || '');
        }

        assert.equal(stableExit, 1, 'host-principal --require-stable must exit 1 on ad-hoc app');
        assert.equal(stableSignal, null, 'host-principal --require-stable signal must be null');
        const stableRes = JSON.parse(stableStdout.slice(stableStdout.indexOf('{')));
        assert.equal(stableRes.classification, 'ad_hoc_ephemeral');
        assert.equal(stableRes.error, 'Staged app is ad_hoc_ephemeral; --require-stable specified');

        const afterSnap3 = snapshotTree(outsideDir);
        assert.deepStrictEqual(afterSnap3, beforeSnap3, 'Outside tree must remain completely unchanged after host-principal --require-stable');
    } finally {
        fs.rmSync(parentTmpDir, { recursive: true, force: true });
    }
});

test('ARP3-2: Actual one-build/two-stage ledger and immutable source authority', async () => {
    const harness = new TestStagingHarness();
    assert.equal(harness.removalSpyCount, 0, 'Initial removal count must be zero');

    const hostPackageDir = path.resolve('apps/computer-use-host');
    const productionStagedDir = path.join(hostPackageDir, '.build/staged');
    const preBuildSnap = snapshotTree(productionStagedDir);

    const opLedger = [];

    // Call buildHostRelease real seam
    const buildRes = await buildHostRelease();
    assert.equal(buildRes.success, true, 'buildHostRelease must return success: true');
    opLedger.push({ op: 'build', result: buildRes });

    assert.equal(harness.removalSpyCount, 0, 'buildHostRelease must not remove harness root');
    const postBuildSnap = snapshotTree(productionStagedDir);
    assert.deepStrictEqual(postBuildSnap, preBuildSnap, 'buildHostRelease must not mutate production staging tree');

    const releaseSourceBinary = buildRes.releaseBinaryPath;
    const releaseSourcePlist = buildRes.infoPlistPath;

    assert.equal(fs.existsSync(releaseSourceBinary), true, 'Release source binary must exist');
    assert.equal(fs.existsSync(releaseSourcePlist), true, 'Release source Info.plist must exist');

    const binLstat = fs.lstatSync(releaseSourceBinary);
    assert.equal(binLstat.isFile(), true, 'Release source binary must be regular file');
    assert.equal(binLstat.isSymbolicLink(), false, 'Release source binary must not be symlink');

    const plistLstat = fs.lstatSync(releaseSourcePlist);
    assert.equal(plistLstat.isFile(), true, 'Release source Info.plist must be regular file');
    assert.equal(plistLstat.isSymbolicLink(), false, 'Release source Info.plist must not be symlink');

    const sourceBinHash = crypto.createHash('sha256').update(fs.readFileSync(releaseSourceBinary)).digest('hex');
    const sourcePlistHash = crypto.createHash('sha256').update(fs.readFileSync(releaseSourcePlist)).digest('hex');

    // Stage 1
    const stage1Res = await stageBuiltHostApp({ harness });
    assert.equal(stage1Res.success, true);
    opLedger.push({ op: 'stage', result: stage1Res, removals: harness.removalSpyCount });
    assert.equal(harness.removalSpyCount, 1, 'Harness removal spy count must transition to 1 after Stage 1');

    const stage1Digest = computeTreeDigest(stage1Res.appPath);

    const stage1BinLstat = fs.lstatSync(stage1Res.binaryPath);
    assert.equal(stage1BinLstat.isFile(), true);
    assert.equal(stage1BinLstat.isSymbolicLink(), false);
    assert.equal(stage1BinLstat.mode & 0o777, 0o755);
    const stage1BinHash = crypto.createHash('sha256').update(fs.readFileSync(stage1Res.binaryPath)).digest('hex');

    const stage1PlistLstat = fs.lstatSync(stage1Res.infoPlistPath);
    assert.equal(stage1PlistLstat.isFile(), true);
    assert.equal(stage1PlistLstat.isSymbolicLink(), false);
    assert.equal(stage1PlistLstat.mode & 0o777, 0o644);
    const stage1PlistHash = crypto.createHash('sha256').update(fs.readFileSync(stage1Res.infoPlistPath)).digest('hex');
    assert.equal(stage1PlistHash, sourcePlistHash, 'Stage 1 Info.plist hash must match release source');

    // Stage 2
    const stage2Res = await stageBuiltHostApp({ harness });
    assert.equal(stage2Res.success, true);
    opLedger.push({ op: 'stage', result: stage2Res, removals: harness.removalSpyCount });
    assert.equal(harness.removalSpyCount, 2, 'Harness removal spy count must transition to 2 after Stage 2');

    const stage2Digest = computeTreeDigest(stage2Res.appPath);
    assert.equal(stage2Digest, stage1Digest, 'Stage 1 and Stage 2 tree digests must be identical');

    const stage2BinLstat = fs.lstatSync(stage2Res.binaryPath);
    assert.equal(stage2BinLstat.isFile(), true);
    assert.equal(stage2BinLstat.isSymbolicLink(), false);
    assert.equal(stage2BinLstat.mode & 0o777, 0o755);
    const stage2BinHash = crypto.createHash('sha256').update(fs.readFileSync(stage2Res.binaryPath)).digest('hex');
    assert.equal(stage2BinHash, stage1BinHash, 'Stage 2 binary hash must match Stage 1 binary hash');

    const stage2PlistLstat = fs.lstatSync(stage2Res.infoPlistPath);
    assert.equal(stage2PlistLstat.isFile(), true);
    assert.equal(stage2PlistLstat.isSymbolicLink(), false);
    assert.equal(stage2PlistLstat.mode & 0o777, 0o644);
    const stage2PlistHash = crypto.createHash('sha256').update(fs.readFileSync(stage2Res.infoPlistPath)).digest('hex');
    assert.equal(stage2PlistHash, sourcePlistHash, 'Stage 2 Info.plist hash must match release source');

    // Verify release source binary unchanged
    const postStageSourceBinHash = crypto.createHash('sha256').update(fs.readFileSync(releaseSourceBinary)).digest('hex');
    assert.equal(postStageSourceBinHash, sourceBinHash, 'Release source binary must remain unchanged after staging');

    // Assert exact ledger shape
    assert.deepEqual(opLedger.map(l => l.op), ['build', 'stage', 'stage'], 'Operation ledger must record exact build -> stage -> stage sequence');
    assert.equal(opLedger.length, 3, 'Ledger must contain exactly 3 operations (no third stage)');

    harness.cleanup();
});

test('ARP3-3 & A3-1: Nonvacuous digest and count mutants authority', async () => {
    // Stage app to produce reference staged tree
    const harness = new TestStagingHarness();
    try {
        await buildHostRelease();
        const stageRes = await stageBuiltHostApp({ harness });
        const refAppPath = stageRes.appPath;
        const refDigest = computeTreeDigest(refAppPath);

        // 1. Chmod-only mutant: copy ref tree to private derived clone, change Info.plist mode 0644 -> 0600
        const clone1Dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-mut-chmod-'));
        fs.chmodSync(clone1Dir, 0o700);
        try {
            const clone1App = path.join(clone1Dir, 'ComputerUseHost.app');
            execFileSync('cp', ['-R', refAppPath, clone1App]);
            const clone1DigestInitial = computeTreeDigest(clone1App);
            assert.equal(clone1DigestInitial, refDigest, 'Clone 1 initial digest must equal baseline digest');

            const clone1Plist = path.join(clone1App, 'Contents/Info.plist');
            fs.chmodSync(clone1Plist, 0o600);
            const clone1MutantDigest = computeTreeDigest(clone1App);
            assert.notEqual(clone1MutantDigest, refDigest, 'Chmod-only mutant (0644 -> 0600 Info.plist) digest MUST differ from baseline digest');
        } finally {
            fs.rmSync(clone1Dir, { recursive: true, force: true });
        }

        // 2. Type-only mutant (A3-1): replace empty Contents/Resources directory with a 0-byte regular file at same path & mode 0755
        const clone2Dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-mut-type-'));
        fs.chmodSync(clone2Dir, 0o700);
        try {
            const clone2App = path.join(clone2Dir, 'ComputerUseHost.app');
            execFileSync('cp', ['-R', refAppPath, clone2App]);
            const clone2DigestInitial = computeTreeDigest(clone2App);
            assert.equal(clone2DigestInitial, refDigest, 'Clone 2 initial digest must equal baseline digest');

            const resourcesPath = path.join(clone2App, 'Contents/Resources');
            const resLstatBefore = fs.lstatSync(resourcesPath);
            assert.equal(resLstatBefore.isDirectory(), true, 'Resources before mutant must be directory');
            assert.equal(fs.readdirSync(resourcesPath).length, 0, 'Resources before mutant must be empty directory');

            fs.rmdirSync(resourcesPath);
            fs.writeFileSync(resourcesPath, Buffer.alloc(0), { mode: 0o755 });
            fs.chmodSync(resourcesPath, 0o755);

            const resLstatAfter = fs.lstatSync(resourcesPath);
            assert.equal(resLstatAfter.isFile(), true, 'Resources after mutant must be regular file');
            assert.equal(resLstatAfter.size, 0, 'Resources after mutant must be 0-byte file');
            assert.equal(resLstatAfter.mode & 0o777, 0o755, 'Resources after mutant must have 0755 mode');

            const clone2MutantDigest = computeTreeDigest(clone2App);
            assert.notEqual(clone2MutantDigest, refDigest, 'Type-only mutant (empty dir -> 0-byte file at same path & mode) digest MUST differ from baseline digest');
        } finally {
            fs.rmSync(clone2Dir, { recursive: true, force: true });
        }
    } finally {
        harness.cleanup();
    }
});

test('ARP3-4 & A3-2 & A3-3: Fresh tracked export, missing release, and nonvacuous ledger authority', async () => {
    const parentTmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-p3-export-'));
    fs.chmodSync(parentTmpDir, 0o700);

    const outsideDir = path.join(parentTmpDir, 'outside');
    fs.mkdirSync(outsideDir, { mode: 0o700 });
    createOutsideSentinelTree(outsideDir);

    const exportDir = path.join(parentTmpDir, 'export');
    fs.mkdirSync(exportDir, { mode: 0o700 });

    try {
        const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

        // Create fresh clean git export from HEAD
        const archiveTarPath = path.join(parentTmpDir, 'export.tar');
        execFileSync('git', ['archive', '--output', archiveTarPath, 'HEAD'], { cwd: repoRoot, stdio: 'ignore' });
        execFileSync('tar', ['-xf', archiveTarPath, '-C', exportDir], { stdio: 'ignore' });

        assert.equal(fs.existsSync(path.join(exportDir, '.git')), false, 'Export must not contain .git');
        assert.equal(fs.existsSync(path.join(exportDir, 'apps/computer-use-host/.build')), false, 'Export must not contain .build');
        assert.equal(fs.existsSync(path.join(exportDir, 'node_modules')), false, 'Export must not contain node_modules');

        const expHostAppBytes = fs.readFileSync(path.join(exportDir, 'bin/host-app.mjs'));
        const headHostAppBytes = execFileSync('git', ['show', 'HEAD:bin/host-app.mjs'], { cwd: repoRoot });
        assert.equal(Buffer.compare(expHostAppBytes, headHostAppBytes), 0, 'Exported bin/host-app.mjs bytes must match HEAD');

        const expTestBytes = fs.readFileSync(path.join(exportDir, 'bin/host-app.test.mjs'));
        const headTestBytes = execFileSync('git', ['show', 'HEAD:bin/host-app.test.mjs'], { cwd: repoRoot });
        assert.equal(Buffer.compare(expTestBytes, headTestBytes), 0, 'Exported bin/host-app.test.mjs bytes must match HEAD');

        // A3-2: Missing release fails before any stage mutation
        const exportHostAppPath = path.join(exportDir, 'bin/host-app.mjs');
        const { stageBuiltHostApp: expStageBuilt, buildHostRelease: expBuildRelease } = await import(exportHostAppPath);

        const expStagedDir = path.join(exportDir, 'apps/computer-use-host/.build/staged');
        const outsideBeforeA32 = snapshotTree(outsideDir);

        await assert.rejects(
            async () => await expStageBuilt(),
            /Release binary does not exist/
        );
        assert.equal(fs.existsSync(expStagedDir), false, 'Staging root must remain absent on missing-release rejection');
        assert.deepStrictEqual(snapshotTree(outsideDir), outsideBeforeA32, 'Outside tree must remain unchanged on missing-release rejection');

        // Now run build-only and two stages from export
        const buildRes = await expBuildRelease();
        assert.equal(buildRes.success, true);
        assert.equal(fs.existsSync(expStagedDir), false, 'Staging root must remain absent immediately after build-only');

        const releaseSourceBinary = buildRes.releaseBinaryPath;
        const sourceBinHash = crypto.createHash('sha256').update(fs.readFileSync(releaseSourceBinary)).digest('hex');
        const sourcePlistHash = crypto.createHash('sha256').update(fs.readFileSync(buildRes.infoPlistPath)).digest('hex');

        // Stage 1 in export
        const stage1Res = await expStageBuilt();
        assert.equal(stage1Res.success, true);
        assert.equal(fs.existsSync(expStagedDir), true, 'Staging root must exist after Stage 1');
        const stage1Digest = computeTreeDigest(stage1Res.appPath);
        const stage1BinHash = crypto.createHash('sha256').update(fs.readFileSync(stage1Res.binaryPath)).digest('hex');
        const stage1PlistHash = crypto.createHash('sha256').update(fs.readFileSync(stage1Res.infoPlistPath)).digest('hex');
        assert.equal(stage1PlistHash, sourcePlistHash);

        // Stage 2 in export
        const stage2Res = await expStageBuilt();
        assert.equal(stage2Res.success, true);
        const stage2Digest = computeTreeDigest(stage2Res.appPath);
        const stage2BinHash = crypto.createHash('sha256').update(fs.readFileSync(stage2Res.binaryPath)).digest('hex');
        const stage2PlistHash = crypto.createHash('sha256').update(fs.readFileSync(stage2Res.infoPlistPath)).digest('hex');
        assert.equal(stage2Digest, stage1Digest);
        assert.equal(stage2BinHash, stage1BinHash);
        assert.equal(stage2PlistHash, sourcePlistHash);

        assert.deepStrictEqual(snapshotTree(outsideDir), outsideBeforeA32, 'Outside tree must remain unchanged after export build and stages');

        // A3-3: Pre-filled ledger rejection discriminator
        function validateLedger(ledger, actualCalls) {
            if (!Array.isArray(ledger) || ledger.length !== actualCalls.length) {
                throw new Error('Ledger length mismatch');
            }
            for (let i = 0; i < ledger.length; i++) {
                if (ledger[i].op !== actualCalls[i].op || ledger[i].completed !== true) {
                    throw new Error(`Ledger entry ${i} invalid`);
                }
            }
        }
        const prefilledLedger = [{ op: 'build', completed: true }, { op: 'stage', completed: true }, { op: 'stage', completed: true }];
        assert.throws(
            () => validateLedger(prefilledLedger, []),
            /Ledger length mismatch/
        );
    } finally {
        fs.rmSync(parentTmpDir, { recursive: true, force: true });
    }
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

async function assertBoundaryRejection(label, makeOptions) {
    const harness = new TestStagingHarness();
    const productionStage = path.resolve('apps/computer-use-host/.build/staged');
    const productionBefore = snapshotTree(productionStage);
    const harnessBefore = snapshotTree(harness.rootDir);
    const removalsBefore = harness.removalSpyCount;

    let rejected = false;
    try {
        await stageHostApp(makeOptions(harness));
    } catch {
        rejected = true;
    }

    assert.equal(rejected, true, `${label}: malformed options must reject`);
    assert.equal(harness.removalSpyCount, removalsBefore, `${label}: rejection must happen before harness removal`);
    assert.deepStrictEqual(snapshotTree(harness.rootDir), harnessBefore, `${label}: rejection must not mutate harness root`);
    assert.deepStrictEqual(snapshotTree(productionStage), productionBefore, `${label}: rejection must not mutate production staging`);
    harness.cleanup();
}

test('ARP3-G1: Strict stageHostApp public option grammar and obsolete-hook rejection', async (t) => {
    await t.test('1. Valid stageHostApp call variants resolve cleanly', async () => {
        const harness = new TestStagingHarness();
        try {
            const res1 = await stageHostApp({ harness, build: false });
            assert.equal(res1.success, true);

            const res2 = await stageHostApp({ harness, build: false, relativeTarget: 'custom.app' });
            assert.equal(res2.appPath, path.join(harness.rootDir, 'custom.app'));
        } finally {
            harness.cleanup();
        }
    });

    await t.test('2. Option type and prototype rejections with side-effect oracle', async () => {
        const invalidOptionsFns = [
            ['null options', () => null],
            ['numeric options', () => 123],
            ['string options', () => 'invalid'],
            ['boolean options', () => true],
            ['symbol options', () => Symbol('opt')],
            ['function options', (h) => Object.assign(function options() {}, { harness: h, build: false })],
            ['array options', (h) => Object.assign([], { harness: h, build: false })],
            ['null prototype', (h) => Object.assign(Object.create(null), { harness: h, build: false })],
            ['custom prototype with inherited unknown/build', (h) => Object.assign(Object.create({ build: false }), { harness: h })],
            ['custom prototype with inherited relativeTarget', (h) => Object.assign(Object.create({ relativeTarget: 'inherited.app' }), { harness: h, build: false })]
        ];
        for (const [label, makeOpt] of invalidOptionsFns) {
            await assertBoundaryRejection(label, makeOpt);
        }
    });

    await t.test('3. Symbol, non-enumerable, and unknown key rejections with side-effect oracle', async () => {
        await assertBoundaryRejection('own Symbol key', (h) => ({ harness: h, build: false, [Symbol('key')]: true }));
        await assertBoundaryRejection('non-enumerable own unknown key', (h) => {
            const opt = { harness: h, build: false };
            Object.defineProperty(opt, 'nonEnumKey', { value: 1, enumerable: false });
            return opt;
        });
        await assertBoundaryRejection('unknown own key', (h) => ({ harness: h, build: false, execFileAsync: () => {} }));
    });

    await t.test('4. Field type validation for build, harness, relativeTarget with side-effect oracle', async () => {
        await assertBoundaryRejection('invalid build string', (h) => ({ harness: h, build: 'false' }));
        await assertBoundaryRejection('invalid harness object', () => ({ harness: {} }));
        await assertBoundaryRejection('relativeTarget without harness', () => ({ relativeTarget: 'foo.app' }));
        await assertBoundaryRejection('invalid relativeTarget type', (h) => ({ harness: h, relativeTarget: 123 }));
    });

    await t.test('5. Bounded Object.prototype pollution and ownership poisoning discriminators', async () => {
        try {
            Object.prototype.enumerableUnknownInheritedKey = 'poison';
            await assertBoundaryRejection('enumerable inherited unknown', (h) => ({ harness: h, build: false }));
        } finally {
            delete Object.prototype.enumerableUnknownInheritedKey;
        }

        try {
            Object.defineProperty(Object.prototype, 'build', { value: false, writable: true, configurable: true, enumerable: false });
            await assertBoundaryRejection('non-enumerable inherited build', (h) => ({ harness: h }));
        } finally {
            delete Object.prototype.build;
        }

        try {
            Object.defineProperty(Object.prototype, 'relativeTarget', { value: 'INHERITED.app', writable: true, configurable: true, enumerable: false });
            await assertBoundaryRejection('non-enumerable inherited relativeTarget', (h) => ({ harness: h, build: false }));
        } finally {
            delete Object.prototype.relativeTarget;
        }

        const symKey = Symbol('inheritedSymbolKey');
        try {
            Object.prototype[symKey] = 'poison';
            await assertBoundaryRejection('inherited Symbol key', (h) => ({ harness: h, build: false }));
        } finally {
            delete Object.prototype[symKey];
        }

        const origHasOwnProperty = Object.prototype.hasOwnProperty;
        try {
            Object.defineProperty(Object.prototype, 'build', { value: false, writable: true, configurable: true, enumerable: false });
            Object.defineProperty(Object.prototype, 'relativeTarget', { value: 'INHERITED.app', writable: true, configurable: true, enumerable: false });
            Object.prototype.hasOwnProperty = function () { return true; };

            await assertBoundaryRejection('poisoned hasOwnProperty with inherited build/relativeTarget', (h) => ({ harness: h }));
        } finally {
            Object.prototype.hasOwnProperty = origHasOwnProperty;
            delete Object.prototype.build;
            delete Object.prototype.relativeTarget;
        }
    });
});

test('ARP3-BUILD-ARG: buildHostRelease strict argument rejection and state immutability matrix', async () => {
    const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
    const hostPackageDir = path.join(repoRoot, 'apps/computer-use-host');
    const releaseBinaryPath = path.join(hostPackageDir, '.build/release/ComputerUseHost');
    const infoPlistPath = path.join(hostPackageDir, 'Info.plist');
    const stagingRoot = path.join(hostPackageDir, '.build/staged');

    function captureStateIdentity() {
        return {
            stagingExists: fs.existsSync(stagingRoot),
            stagingSnapshot: fs.existsSync(stagingRoot) ? snapshotTree(stagingRoot) : null,
            releaseBinExists: fs.existsSync(releaseBinaryPath),
            releaseBinStat: fs.existsSync(releaseBinaryPath) ? (({ mode, size, dev, ino }) => ({ mode: mode & 0o777, size, dev, ino }))(fs.statSync(releaseBinaryPath)) : null,
            releaseBinHash: fs.existsSync(releaseBinaryPath) ? crypto.createHash('sha256').update(fs.readFileSync(releaseBinaryPath)).digest('hex') : null,
            infoPlistExists: fs.existsSync(infoPlistPath),
            infoPlistStat: fs.existsSync(infoPlistPath) ? (({ mode, size, dev, ino }) => ({ mode: mode & 0o777, size, dev, ino }))(fs.statSync(infoPlistPath)) : null,
            infoPlistHash: fs.existsSync(infoPlistPath) ? crypto.createHash('sha256').update(fs.readFileSync(infoPlistPath)).digest('hex') : null,
        };
    }

    const stateBeforeAll = captureStateIdentity();

    const invalidArgsMatrix = [
        ['empty object {}', {}],
        ['caller runner { runner: "custom" }', { runner: 'custom' }],
        ['caller project root { projectRoot: "/tmp" }', { projectRoot: '/tmp' }],
        ['explicit undefined', undefined],
    ];

    for (const [label, arg] of invalidArgsMatrix) {
        const stateBefore = captureStateIdentity();

        await assert.rejects(
            async () => await buildHostRelease(arg),
            (err) => {
                assert.equal(err instanceof Error, true);
                assert.equal(err.message, 'buildHostRelease accepts no arguments');
                return true;
            },
            `buildHostRelease with ${label} must reject with exact error message`
        );

        const stateAfter = captureStateIdentity();
        assert.deepStrictEqual(stateAfter, stateBefore, `State identity must be invariant across ${label} rejection`);
    }

    assert.deepStrictEqual(captureStateIdentity(), stateBeforeAll, 'Overall state identity must be invariant across full matrix');
});
