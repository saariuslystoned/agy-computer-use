import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
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
