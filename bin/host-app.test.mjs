import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { stageHostApp, classifyPrincipal } from './host-app.mjs';

function computeTreeDigest(dirPath) {
    const entries = fs.readdirSync(dirPath, { recursive: true, withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    const hash = crypto.createHash('sha256');

    for (const entry of entries) {
        const fullPath = path.join(entry.path, entry.name);
        const relPath = path.relative(dirPath, fullPath);
        hash.update(relPath);
        if (entry.isFile()) {
            hash.update(fs.readFileSync(fullPath));
        }
    }
    return hash.digest('hex');
}

test('P-4: Classifier pure unit tests for principal states', async (t) => {
    await t.test('Classifies missing or non-existent path as unsigned_or_invalid', async () => {
        const res = await classifyPrincipal('/tmp/nonexistent-app-123456/App.app');
        assert.equal(res.classification, 'unsigned_or_invalid');
    });

    await t.test('Classifies ad-hoc signed app as ad_hoc_ephemeral', async () => {
        const stageRes = await stageHostApp();
        assert.equal(stageRes.success, true);
        const res = await classifyPrincipal(stageRes.appPath);
        assert.equal(res.classification, 'ad_hoc_ephemeral');
        assert.equal(res.identifier, 'com.saariuslystoned.agy-computer-use.host');
    });

    await t.test('Fails closed under --require-stable for ad_hoc_ephemeral', async () => {
        const stagedAppDir = path.resolve('apps/computer-use-host/.build/staged/ComputerUseHost.app');
        const res = await classifyPrincipal(stagedAppDir, { requireStable: true });
        assert.equal(res.classification, 'ad_hoc_ephemeral');
        assert.ok(res.error);
    });
});

test('P-4: Deterministic staging tree digest comparison', async () => {
    const stage1 = await stageHostApp();
    const digest1 = computeTreeDigest(stage1.appPath);

    const stage2 = await stageHostApp();
    const digest2 = computeTreeDigest(stage2.appPath);

    assert.equal(digest1, digest2, 'Tree digests of two consecutive stages must be identical');
});

test('L-4: Real subprocess lifecycle smoke tests for SIGTERM and SIGINT', async (t) => {
    const stageRes = await stageHostApp();
    const stagedAppBinary = stageRes.binaryPath;

    await t.test('Subprocess handles SIGTERM cleanly, unlinks socket, and permits second bind', async () => {
        const tmpDir = fs.mkdtempSync('/tmp/agy-host-smoke-term-');
        const sockPath = path.join(tmpDir, 'host.sock');

        // First launch
        const proc1 = spawn(stagedAppBinary, [], {
            env: { ...process.env, COMPUTER_USE_SOCKET_PATH: sockPath },
            stdio: ['ignore', 'pipe', 'pipe']
        });

        await new Promise((resolve, reject) => {
            const start = Date.now();
            const interval = setInterval(() => {
                if (fs.existsSync(sockPath)) {
                    clearInterval(interval);
                    resolve();
                } else if (Date.now() - start > 5000) {
                    clearInterval(interval);
                    reject(new Error('Timed out waiting for socket creation'));
                }
            }, 50);
        });

        proc1.kill('SIGTERM');

        const exitCode1 = await new Promise((resolve) => {
            proc1.on('exit', (code) => resolve(code));
        });

        assert.equal(exitCode1, 0, 'Subprocess must exit 0 on SIGTERM');
        assert.equal(fs.existsSync(sockPath), false, 'Socket file must be unlinked after exit');

        // Second launch on same directory must succeed (proving lock was released and second bind works)
        const proc2 = spawn(stagedAppBinary, [], {
            env: { ...process.env, COMPUTER_USE_SOCKET_PATH: sockPath },
            stdio: ['ignore', 'pipe', 'pipe']
        });

        await new Promise((resolve, reject) => {
            const start = Date.now();
            const interval = setInterval(() => {
                if (fs.existsSync(sockPath)) {
                    clearInterval(interval);
                    resolve();
                } else if (Date.now() - start > 5000) {
                    clearInterval(interval);
                    reject(new Error('Timed out waiting for second socket creation'));
                }
            }, 50);
        });

        proc2.kill('SIGTERM');
        const exitCode2 = await new Promise((resolve) => {
            proc2.on('exit', (code) => resolve(code));
        });

        assert.equal(exitCode2, 0, 'Second subprocess must exit 0 on SIGTERM');
        assert.equal(fs.existsSync(sockPath), false, 'Socket file must be unlinked after second exit');

        fs.rmSync(tmpDir, { recursive: true, force: true });
    });

    await t.test('Subprocess handles SIGINT cleanly, unlinks socket, and permits second bind', async () => {
        const tmpDir = fs.mkdtempSync('/tmp/agy-host-smoke-int-');
        const sockPath = path.join(tmpDir, 'host.sock');

        // First launch
        const proc1 = spawn(stagedAppBinary, [], {
            env: { ...process.env, COMPUTER_USE_SOCKET_PATH: sockPath },
            stdio: ['ignore', 'pipe', 'pipe']
        });

        await new Promise((resolve, reject) => {
            const start = Date.now();
            const interval = setInterval(() => {
                if (fs.existsSync(sockPath)) {
                    clearInterval(interval);
                    resolve();
                } else if (Date.now() - start > 5000) {
                    clearInterval(interval);
                    reject(new Error('Timed out waiting for socket creation'));
                }
            }, 50);
        });

        proc1.kill('SIGINT');

        const exitCode1 = await new Promise((resolve) => {
            proc1.on('exit', (code) => resolve(code));
        });

        assert.equal(exitCode1, 0, 'Subprocess must exit 0 on SIGINT');
        assert.equal(fs.existsSync(sockPath), false, 'Socket file must be unlinked after exit');

        // Second launch on same directory must succeed
        const proc2 = spawn(stagedAppBinary, [], {
            env: { ...process.env, COMPUTER_USE_SOCKET_PATH: sockPath },
            stdio: ['ignore', 'pipe', 'pipe']
        });

        await new Promise((resolve, reject) => {
            const start = Date.now();
            const interval = setInterval(() => {
                if (fs.existsSync(sockPath)) {
                    clearInterval(interval);
                    resolve();
                } else if (Date.now() - start > 5000) {
                    clearInterval(interval);
                    reject(new Error('Timed out waiting for second socket creation'));
                }
            }, 50);
        });

        proc2.kill('SIGINT');
        const exitCode2 = await new Promise((resolve) => {
            proc2.on('exit', (code) => resolve(code));
        });

        assert.equal(exitCode2, 0, 'Second subprocess must exit 0 on SIGINT');
        assert.equal(fs.existsSync(sockPath), false, 'Socket file must be unlinked after second exit');

        fs.rmSync(tmpDir, { recursive: true, force: true });
    });
});
