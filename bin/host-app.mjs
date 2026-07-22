#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export function validateStageTargetDir(targetDir, allowedRoot) {
    const resolvedTarget = path.resolve(targetDir);
    const resolvedRoot = path.resolve(allowedRoot);

    if (resolvedTarget === resolvedRoot) {
        throw new Error(`Target directory ${resolvedTarget} cannot be equal to allowed root ${resolvedRoot}`);
    }

    const rel = path.relative(resolvedRoot, resolvedTarget);
    if (rel.startsWith('..') || path.isAbsolute(rel) || rel === '') {
        throw new Error(`Target directory ${resolvedTarget} is not strictly contained within allowed root ${resolvedRoot}`);
    }

    let curr = resolvedRoot;
    const parts = rel.split(path.sep);
    for (const part of parts) {
        curr = path.join(curr, part);
        if (fs.existsSync(curr)) {
            const lstat = fs.lstatSync(curr);
            if (lstat.isSymbolicLink()) {
                const real = fs.realpathSync(curr);
                const realRel = path.relative(resolvedRoot, real);
                if (realRel.startsWith('..') || path.isAbsolute(realRel)) {
                    throw new Error(`Target directory ${resolvedTarget} traverses symlink ${curr} pointing outside allowed root ${resolvedRoot}`);
                }
            }
        }
    }

    return resolvedTarget;
}

export async function stageHostApp(options = {}) {
    const projectRoot = options.projectRoot || process.cwd();
    const root = path.resolve(projectRoot);
    const hostPackageDir = path.join(root, 'apps/computer-use-host');

    let stagedAppDir;
    if (options.targetDir) {
        const testRoot = options.allowedTestRoot || options.testRoot;
        if (!testRoot) {
            throw new Error(`Test-injected targetDir ${options.targetDir} requires explicit allowedTestRoot option`);
        }
        stagedAppDir = validateStageTargetDir(options.targetDir, testRoot);
    } else {
        const defaultStagingRoot = path.join(hostPackageDir, '.build/staged');
        stagedAppDir = path.join(defaultStagingRoot, 'ComputerUseHost.app');
        validateStageTargetDir(stagedAppDir, defaultStagingRoot);
    }

    const contentsDir = path.join(stagedAppDir, 'Contents');
    const macOSDir = path.join(contentsDir, 'MacOS');
    const resourcesDir = path.join(contentsDir, 'Resources');
    const infoPlistSource = path.join(hostPackageDir, 'Info.plist');
    const releaseBinarySource = path.join(hostPackageDir, '.build/release/ComputerUseHost');
    const binaryTarget = path.join(macOSDir, 'ComputerUseHost');
    const infoPlistTarget = path.join(contentsDir, 'Info.plist');

    const shouldBuild = options.build !== false;
    if (shouldBuild) {
        await execFileAsync('swift', [
            'build',
            '--package-path', hostPackageDir,
            '--configuration', 'release',
            '--product', 'ComputerUseHost',
            '-Xswiftc', '-strict-concurrency=complete',
            '-Xswiftc', '-warnings-as-errors'
        ], { cwd: root });
    } else {
        if (!fs.existsSync(releaseBinarySource)) {
            throw new Error(`Release binary does not exist at ${releaseBinarySource}; cannot stage without build.`);
        }
    }

    if (fs.existsSync(stagedAppDir)) {
        fs.rmSync(stagedAppDir, { recursive: true, force: true });
    }
    fs.mkdirSync(macOSDir, { recursive: true });
    fs.mkdirSync(resourcesDir, { recursive: true });

    fs.copyFileSync(releaseBinarySource, binaryTarget);
    fs.chmodSync(binaryTarget, 0o755);
    fs.copyFileSync(infoPlistSource, infoPlistTarget);

    await execFileAsync('codesign', [
        '--force',
        '--sign', '-',
        '--timestamp=none',
        stagedAppDir
    ], { cwd: root });

    return {
        appPath: stagedAppDir,
        binaryPath: binaryTarget,
        infoPlistPath: infoPlistTarget,
        success: true
    };
}

export function parseAndClassifyPrincipal(codesignInfo, reqInfo, verificationPassed, options = {}) {
    if (!verificationPassed) {
        return { classification: 'unsigned_or_invalid', details: 'Codesign verification failed' };
    }

    const infoLines = (codesignInfo || '').split('\n').map(l => l.trim());
    let identifier = null;
    let signature = null;
    let teamId = null;
    let authority = null;
    let hasContradictoryMeta = false;

    for (const line of infoLines) {
        if (line.startsWith('Identifier=')) {
            if (identifier !== null && identifier !== line.slice(11).trim()) hasContradictoryMeta = true;
            identifier = line.slice(11).trim();
        } else if (line.startsWith('Signature=')) {
            if (signature !== null && signature !== line.slice(10).trim()) hasContradictoryMeta = true;
            signature = line.slice(10).trim();
        } else if (line.startsWith('TeamIdentifier=')) {
            if (teamId !== null && teamId !== line.slice(15).trim()) hasContradictoryMeta = true;
            teamId = line.slice(15).trim();
        } else if (line.startsWith('Authority=')) {
            if (authority !== null && authority !== line.slice(10).trim()) hasContradictoryMeta = true;
            authority = line.slice(10).trim();
        }
    }

    if (hasContradictoryMeta) {
        return { classification: 'unsigned_or_invalid', details: 'Contradictory signature metadata' };
    }

    const expectedIdentifier = 'com.saariuslystoned.agy-computer-use.host';
    if (!identifier || identifier !== expectedIdentifier) {
        return {
            classification: 'unsigned_or_invalid',
            identifier,
            teamId,
            details: `Identifier mismatch: expected ${expectedIdentifier}, got ${identifier}`
        };
    }

    const isExplicitAdHocSignature = (signature === 'adhoc') || (authority === 'adhoc') || (authority && authority.includes('adhoc'));
    const isTeamNotSet = (teamId === 'not set');

    if (isExplicitAdHocSignature && (isTeamNotSet || teamId === null)) {
        if (options.requireStable) {
            return {
                classification: 'ad_hoc_ephemeral',
                identifier,
                teamId: null,
                error: 'Staged app is ad_hoc_ephemeral; --require-stable specified'
            };
        }
        return {
            classification: 'ad_hoc_ephemeral',
            identifier,
            teamId: null,
            details: 'Valid ad-hoc signature'
        };
    }

    if (!teamId || teamId === 'not set') {
        return {
            classification: 'unsigned_or_invalid',
            identifier,
            teamId: null,
            details: 'Non-ad-hoc signature missing valid TeamIdentifier'
        };
    }

    const reqStr = (reqInfo || '').trim();
    if (!reqStr.includes('designated =>')) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Missing designated requirement' };
    }

    const designatedBody = reqStr.split('designated =>')[1].trim();

    if (/\bor\b/i.test(designatedBody) || designatedBody.includes('||')) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Disallowed OR or alternate clauses in designated requirement' };
    }

    const hasExactId = designatedBody.includes(`identifier "${expectedIdentifier}"`);
    const hasExactTeam = designatedBody.includes(`certificate leaf[subject.OU] = "${teamId}"`);

    const idMatches = designatedBody.match(/identifier\s+"([^"]+)"/g) || [];
    const teamMatches = designatedBody.match(/certificate\s+leaf\[subject\.OU\]\s*=\s*"([^"]+)"/g) || [];

    if (idMatches.length !== 1 || teamMatches.length !== 1) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Duplicate or contradictory requirement predicates' };
    }

    if (hasExactId && hasExactTeam) {
        return {
            classification: 'stable_team_signed_candidate',
            identifier,
            teamId,
            details: 'Valid team signature candidate'
        };
    }

    return {
        classification: 'unsigned_or_invalid',
        identifier,
        teamId,
        details: 'Non-ad-hoc signature missing required team designated requirement'
    };
}

export async function classifyPrincipal(appPath, options = {}) {
    const absPath = path.resolve(appPath);
    const binaryPath = path.join(absPath, 'Contents/MacOS/ComputerUseHost');
    const infoPlistPath = path.join(absPath, 'Contents/Info.plist');

    if (!fs.existsSync(absPath) || !fs.existsSync(binaryPath) || !fs.existsSync(infoPlistPath)) {
        return { classification: 'unsigned_or_invalid', details: 'Missing bundle files' };
    }

    let verificationPassed = true;
    try {
        await execFileAsync('codesign', ['--verify', '--strict', absPath]);
    } catch {
        verificationPassed = false;
    }

    let codesignInfo = '';
    try {
        const { stdout, stderr } = await execFileAsync('codesign', ['-dv', '--verbose=4', absPath]);
        codesignInfo = stdout + stderr;
    } catch (e) {
        codesignInfo = String(e);
    }

    let reqInfo = '';
    try {
        const { stdout, stderr } = await execFileAsync('codesign', ['--display', '--requirements', '-', absPath]);
        reqInfo = stdout + stderr;
    } catch {
        reqInfo = '';
    }

    return parseAndClassifyPrincipal(codesignInfo, reqInfo, verificationPassed, options);
}

function sanitizePaths(obj, rootDir) {
    if (!obj || typeof obj !== 'object') return obj;
    const clean = Array.isArray(obj) ? [] : {};
    for (const [key, val] of Object.entries(obj)) {
        if (typeof val === 'string') {
            clean[key] = val.startsWith(rootDir) ? path.relative(rootDir, val) : val;
        } else if (val && typeof val === 'object') {
            clean[key] = sanitizePaths(val, rootDir);
        } else {
            clean[key] = val;
        }
    }
    return clean;
}

async function main() {
    const args = process.argv.slice(2);
    const command = args[0];
    const rootDir = process.cwd();

    if (command === 'stage') {
        const result = await stageHostApp();
        const classification = await classifyPrincipal(result.appPath);
        const output = sanitizePaths({ ...result, principal: classification }, rootDir);
        console.log(JSON.stringify(output, null, 2));
    } else if (command === 'classify' || command === 'host-principal') {
        let appPath = path.resolve('apps/computer-use-host/.build/staged/ComputerUseHost.app');
        let requireStable = false;

        for (let i = 1; i < args.length; i++) {
            if (args[i] === '--app' && args[i + 1]) {
                appPath = path.resolve(args[i + 1]);
                i++;
            } else if (args[i] === '--require-stable') {
                requireStable = true;
            }
        }

        const result = await classifyPrincipal(appPath, { requireStable });
        const output = sanitizePaths(result, rootDir);
        console.log(JSON.stringify(output, null, 2));

        if (requireStable && result.classification !== 'stable_team_signed_candidate') {
            process.exit(1);
        }
    } else {
        console.error('Usage: host-app.mjs <stage|classify> [--app <path>] [--require-stable]');
        process.exit(1);
    }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(import.meta.url.slice(7))) {
    main().catch(err => {
        console.error(err);
        process.exit(1);
    });
}
