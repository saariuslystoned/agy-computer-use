#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export function validateStageTargetDir(targetDir, allowedRoot) {
    const resolvedRoot = path.resolve(allowedRoot);
    let resolvedTarget = path.resolve(targetDir);

    if (!fs.existsSync(resolvedRoot)) {
        throw new Error(`Allowed root ${resolvedRoot} does not exist`);
    }

    const rootLstat = fs.lstatSync(resolvedRoot);
    if (rootLstat.isSymbolicLink()) {
        throw new Error(`Allowed root ${resolvedRoot} cannot be a symbolic link`);
    }

    const canonicalRoot = fs.realpathSync(resolvedRoot);

    // Canonicalize existing target or deepest existing parent of target
    let currTarget = resolvedTarget;
    let tail = [];
    while (!fs.existsSync(currTarget) && currTarget !== path.dirname(currTarget)) {
        tail.unshift(path.basename(currTarget));
        currTarget = path.dirname(currTarget);
    }
    if (fs.existsSync(currTarget)) {
        const canonicalCurr = fs.realpathSync(currTarget);
        resolvedTarget = path.join(canonicalCurr, ...tail);
    }

    if (resolvedTarget === canonicalRoot) {
        throw new Error(`Target directory ${resolvedTarget} cannot be equal to allowed root ${canonicalRoot}`);
    }

    const rel = path.relative(canonicalRoot, resolvedTarget);
    if (rel.startsWith('..') || path.isAbsolute(rel) || rel === '') {
        throw new Error(`Target directory ${resolvedTarget} is not strictly contained within allowed root ${canonicalRoot}`);
    }

    let curr = canonicalRoot;
    const parts = rel.split(path.sep);
    for (const part of parts) {
        curr = path.join(curr, part);
        if (fs.existsSync(curr)) {
            const lstat = fs.lstatSync(curr);
            if (lstat.isSymbolicLink()) {
                throw new Error(`Target directory component ${curr} cannot be a symbolic link`);
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

    // Revalidate target immediately before removal
    if (options.targetDir) {
        const testRoot = options.allowedTestRoot || options.testRoot;
        validateStageTargetDir(options.targetDir, testRoot);
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
    const identifiers = [];
    const signatures = [];
    const teamIds = [];
    const authorities = [];

    for (const line of infoLines) {
        if (line.startsWith('Identifier=')) {
            identifiers.push(line.slice(11).trim());
        } else if (line.startsWith('Signature=')) {
            signatures.push(line.slice(10).trim());
        } else if (line.startsWith('TeamIdentifier=')) {
            teamIds.push(line.slice(15).trim());
        } else if (line.startsWith('Authority=')) {
            authorities.push(line.slice(10).trim());
        }
    }

    // Check for duplicate metadata keys
    if (identifiers.length > 1 || signatures.length > 1 || teamIds.length > 1 || authorities.length > 1) {
        return { classification: 'unsigned_or_invalid', details: 'Duplicate metadata keys detected' };
    }

    const identifier = identifiers[0] || null;
    const signature = signatures[0] || null;
    const teamId = teamIds[0] || null;
    const authority = authorities[0] || null;

    const expectedIdentifier = 'com.saariuslystoned.agy-computer-use.host';
    if (!identifier || identifier !== expectedIdentifier) {
        return {
            classification: 'unsigned_or_invalid',
            identifier,
            teamId,
            details: `Identifier mismatch: expected ${expectedIdentifier}, got ${identifier}`
        };
    }

    if (!signature) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Missing signature line' };
    }

    // Exact ad-hoc checks
    if (signature === 'adhoc') {
        if (teamId !== 'not set') {
            return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Ad-hoc signature cannot have non-"not set" TeamIdentifier' };
        }
        if (authority && authority !== 'not set' && authority !== 'adhoc') {
            return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Ad-hoc signature cannot have conflicting authority' };
        }
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

    // Non-ad-hoc team signature checks
    const isRecognizedTeamSignature = /^size=\d+$/.test(signature);
    if (!isRecognizedTeamSignature) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Unrecognized signature format' };
    }

    if (!teamId || teamId === 'not set') {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Team signature missing TeamIdentifier' };
    }

    const reqStr = (reqInfo || '').trim();
    if (!reqStr.includes('designated =>')) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Missing designated requirement' };
    }

    const designatedBody = reqStr.split('designated =>')[1].trim();

    if (/\bor\b/i.test(designatedBody) || designatedBody.includes('||')) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Disallowed OR or alternate clauses in designated requirement' };
    }

    // Parse exact conjunction predicates: identifier "<expected>", anchor apple generic, certificate leaf[subject.OU] = "<teamId>"
    const predicates = designatedBody.split('and').map(p => p.trim());
    if (predicates.length !== 3) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Requirement must contain exactly three conjunctive predicates' };
    }

    const expectedPred0 = `identifier "${expectedIdentifier}"`;
    const expectedPred1 = 'anchor apple generic';
    const expectedPred2 = `certificate leaf[subject.OU] = "${teamId}"`;

    if (predicates[0] !== expectedPred0 || predicates[1] !== expectedPred1 || predicates[2] !== expectedPred2) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Designated requirement predicates do not match exact canonical conjunction' };
    }

    return {
        classification: 'stable_team_signed_candidate',
        identifier,
        teamId,
        details: 'Valid team signature candidate'
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
