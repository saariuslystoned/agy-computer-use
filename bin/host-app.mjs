#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

export function validateStageTargetDir(targetDir, allowedRoot) {
    const resolvedRoot = path.resolve(allowedRoot);

    let rootLstat;
    try {
        rootLstat = fs.lstatSync(resolvedRoot);
    } catch (e) {
        if (e.code === 'ENOENT') {
            throw new Error(`Allowed root ${resolvedRoot} does not exist`);
        }
        throw e;
    }

    if (rootLstat.isSymbolicLink()) {
        throw new Error(`Allowed root ${resolvedRoot} cannot be a symbolic link`);
    }
    if (!rootLstat.isDirectory()) {
        throw new Error(`Allowed root ${resolvedRoot} must be a directory, not a regular file or non-directory`);
    }
    if ((rootLstat.mode & 0o077) !== 0) {
        throw new Error(`Allowed root ${resolvedRoot} must have private 0700 permissions`);
    }

    const rawTarget = path.resolve(targetDir);

    if (rawTarget === resolvedRoot) {
        throw new Error(`Target directory ${rawTarget} cannot be equal to allowed root ${resolvedRoot}`);
    }

    const lexRel = path.relative(resolvedRoot, rawTarget);
    if (lexRel === '' || lexRel.startsWith('..') || path.isAbsolute(lexRel)) {
        throw new Error(`Target directory ${rawTarget} is not strictly contained within allowed root ${resolvedRoot}`);
    }

    let curr = resolvedRoot;
    const parts = lexRel.split(path.sep);
    for (const part of parts) {
        curr = path.join(curr, part);
        try {
            const lstat = fs.lstatSync(curr);
            if (lstat.isSymbolicLink()) {
                throw new Error(`Target directory component ${curr} cannot be a symbolic link`);
            }
        } catch (e) {
            if (e.code !== 'ENOENT') throw e;
        }
    }

    const canonicalRoot = fs.realpathSync(resolvedRoot);
    let currTarget = rawTarget;
    let tail = [];
    while (!fs.existsSync(currTarget) && currTarget !== path.dirname(currTarget)) {
        tail.unshift(path.basename(currTarget));
        currTarget = path.dirname(currTarget);
    }
    let canonicalTarget = rawTarget;
    if (fs.existsSync(currTarget)) {
        const canonicalCurr = fs.realpathSync(currTarget);
        canonicalTarget = path.join(canonicalCurr, ...tail);
    }

    const canRel = path.relative(canonicalRoot, canonicalTarget);
    if (canRel === '' || canRel.startsWith('..') || path.isAbsolute(canRel)) {
        throw new Error(`Target directory ${canonicalTarget} is not strictly contained within canonical root ${canonicalRoot}`);
    }

    return rawTarget;
}

export async function stageHostApp(options = {}) {
    if (options.projectRoot) {
        throw new Error('Obsolete projectRoot option is not allowed for production staging');
    }

    const root = REPO_ROOT;
    const hostPackageDir = path.join(root, 'apps/computer-use-host');

    let stagedAppDir;
    let stagingRoot;

    if (options.targetDir) {
        stagingRoot = options.allowedTestRoot || options.testRoot;
        if (!stagingRoot) {
            throw new Error(`Test-injected targetDir ${options.targetDir} requires explicit allowedTestRoot option`);
        }
        stagedAppDir = validateStageTargetDir(options.targetDir, stagingRoot);
    } else {
        stagingRoot = path.join(hostPackageDir, '.build/staged');
        if (!fs.existsSync(stagingRoot)) {
            fs.mkdirSync(stagingRoot, { recursive: true, mode: 0o700 });
        }
        const rootLstat = fs.lstatSync(stagingRoot);
        if (rootLstat.isSymbolicLink()) {
            throw new Error(`Staging root ${stagingRoot} cannot be a symbolic link`);
        }
        if (!rootLstat.isDirectory()) {
            throw new Error(`Staging root ${stagingRoot} must be a directory`);
        }
        if ((rootLstat.mode & 0o077) !== 0) {
            fs.chmodSync(stagingRoot, 0o700);
        }
        stagedAppDir = path.join(stagingRoot, 'ComputerUseHost.app');
        validateStageTargetDir(stagedAppDir, stagingRoot);
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

    if (typeof options.beforeRemovalHook === 'function') {
        await options.beforeRemovalHook();
    }

    // Revalidate target immediately before removal
    validateStageTargetDir(stagedAppDir, stagingRoot);

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

    const infoLines = (codesignInfo || '').split('\n').map(l => l.replace(/\r$/, ''));
    const identifiers = [];
    const signatures = [];
    const teamIds = [];
    const authorities = [];

    for (const rawLine of infoLines) {
        if (rawLine === '') continue;
        const line = rawLine;

        if (line.startsWith('Identifier=')) {
            const val = line.slice(11);
            if (val === '' || val.trim() !== val) return { classification: 'unsigned_or_invalid', details: 'Identifier has whitespace or is empty' };
            identifiers.push(val);
        } else if (line.startsWith('Signature=')) {
            const val = line.slice(10);
            if (val === 'adhoc') {
                signatures.push('adhoc');
            } else {
                return { classification: 'unsigned_or_invalid', details: 'Invalid Signature= format' };
            }
        } else if (line.startsWith('Signature size=')) {
            const sizeStr = line.slice(15);
            if (!/^[1-9][0-9]*$/.test(sizeStr)) {
                return { classification: 'unsigned_or_invalid', details: 'Invalid Signature size format' };
            }
            signatures.push(`Signature size=${sizeStr}`);
        } else if (line.startsWith('TeamIdentifier=')) {
            const val = line.slice(15);
            if (val === '' || val.trim() !== val) {
                return { classification: 'unsigned_or_invalid', details: 'TeamIdentifier cannot have whitespace or be empty' };
            }
            teamIds.push(val);
        } else if (line.startsWith('Authority=')) {
            const val = line.slice(10);
            if (val === '' || val.trim() !== val || val === 'adhoc' || val === 'not set') {
                return { classification: 'unsigned_or_invalid', details: 'Invalid Authority value' };
            }
            authorities.push(val);
        } else {
            if (/^\s*(Identifier|Signature|TeamIdentifier|Authority)[\s=:]/i.test(line)) {
                return { classification: 'unsigned_or_invalid', details: 'Malformed metadata record' };
            }
        }
    }

    if (identifiers.length !== 1 || signatures.length !== 1 || teamIds.length !== 1) {
        return { classification: 'unsigned_or_invalid', details: 'Missing or duplicate metadata records' };
    }

    const identifier = identifiers[0];
    const signature = signatures[0];
    const teamId = teamIds[0];

    const expectedIdentifier = 'com.saariuslystoned.agy-computer-use.host';
    if (identifier !== expectedIdentifier) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Identifier mismatch' };
    }

    if (signature === 'adhoc') {
        if (teamId !== 'not set') {
            return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Ad-hoc signature cannot have non-"not set" TeamIdentifier' };
        }
        if (authorities.length > 0) {
            return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Ad-hoc signature cannot have authority records' };
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

    const teamSigMatch = signature.match(/^Signature size=([1-9][0-9]*)$/);
    if (!teamSigMatch) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Unrecognized signature format' };
    }

    if (teamId === 'not set') {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Team signature missing TeamIdentifier' };
    }

    if (authorities.length === 0) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Team signature missing Authority chain' };
    }

    const rawReqLines = (reqInfo || '').split('\n').map(l => l.replace(/\r$/, ''));
    if (rawReqLines.length > 0 && rawReqLines[rawReqLines.length - 1] === '') {
        rawReqLines.pop();
    }

    if (rawReqLines.length !== 2) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Requirement output must contain exactly two non-empty records' };
    }

    const execLine = rawReqLines[0];
    if (!execLine.startsWith('Executable=')) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'First requirement record must start with Executable=' };
    }
    const execVal = execLine.slice(11);
    if (execVal === '' || execVal.trim() !== execVal) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Executable= value cannot be empty or have whitespace' };
    }

    const desLine = rawReqLines[1];
    if (!desLine.startsWith('designated => ')) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Second requirement record must start with designated => ' };
    }
    const designatedBody = desLine.slice(14);
    if (designatedBody === '' || designatedBody.trim() !== designatedBody) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'designated => body cannot be empty or have whitespace' };
    }

    if (/\bor\b/i.test(designatedBody) || designatedBody.includes('||')) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Disallowed OR or alternate clauses in designated requirement' };
    }

    const atoms = designatedBody.split(' and ');
    for (const atom of atoms) {
        if (atom === '' || atom.trim() !== atom) {
            return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Requirement atom cannot be empty or have surrounding whitespace' };
        }
    }

    const lexAndMatches = designatedBody.match(/\band\b/g) || [];
    if (lexAndMatches.length !== atoms.length - 1) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Conjunction count mismatch' };
    }

    const expectedPred0 = `identifier "${expectedIdentifier}"`;
    const expectedPred1 = 'anchor apple generic';
    const expectedPred2 = `certificate leaf[subject.OU] = ${teamId}`;

    const allowedOid1 = 'certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */';
    const allowedOid2 = 'certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */';

    let foundId = false;
    let foundAnchor = false;
    let foundTeam = false;
    let foundOid1 = false;
    let foundOid2 = false;

    for (const pred of atoms) {
        if (pred === expectedPred0) {
            if (foundId) return { classification: 'unsigned_or_invalid', details: 'Duplicate identifier predicate' };
            foundId = true;
        } else if (pred === expectedPred1) {
            if (foundAnchor) return { classification: 'unsigned_or_invalid', details: 'Duplicate anchor predicate' };
            foundAnchor = true;
        } else if (pred === expectedPred2) {
            if (foundTeam) return { classification: 'unsigned_or_invalid', details: 'Duplicate team predicate' };
            foundTeam = true;
        } else if (pred === allowedOid1) {
            if (foundOid1) return { classification: 'unsigned_or_invalid', details: 'Duplicate OID1 predicate' };
            foundOid1 = true;
        } else if (pred === allowedOid2) {
            if (foundOid2) return { classification: 'unsigned_or_invalid', details: 'Duplicate OID2 predicate' };
            foundOid2 = true;
        } else {
            return { classification: 'unsigned_or_invalid', identifier, teamId, details: `Unrecognized requirement predicate: ${pred}` };
        }
    }

    if (!foundId || !foundAnchor || !foundTeam) {
        return { classification: 'unsigned_or_invalid', identifier, teamId, details: 'Missing mandatory requirement predicate' };
    }

    return {
        classification: 'stable_team_signed_candidate',
        identifier,
        teamId,
        details: 'Valid team signature candidate'
    };
}

export async function classifyPrincipal(appPath, options = {}) {
    const execRunner = options.execFileAsync || execFileAsync;
    const absPath = path.resolve(appPath);
    const binaryPath = path.join(absPath, 'Contents/MacOS/ComputerUseHost');
    const infoPlistPath = path.join(absPath, 'Contents/Info.plist');

    if (!fs.existsSync(absPath) || !fs.existsSync(binaryPath) || !fs.existsSync(infoPlistPath)) {
        return { classification: 'unsigned_or_invalid', details: 'Missing bundle files' };
    }

    let verificationPassed = true;
    try {
        await execRunner('codesign', ['--verify', '--strict', absPath]);
    } catch {
        verificationPassed = false;
    }

    let codesignInfo = '';
    try {
        const { stdout, stderr } = await execRunner('codesign', ['-dv', '--verbose=4', absPath]);
        codesignInfo = (stdout || '') + (stderr || '');
    } catch (e) {
        codesignInfo = (e && e.stdout || '') + (e && e.stderr || '') || String(e);
    }

    let reqInfo = '';
    try {
        const { stdout, stderr } = await execRunner('codesign', ['-d', '-r-', absPath]);
        const errStr = (stderr || '');
        const outStr = (stdout || '');
        reqInfo = (errStr ? errStr + (errStr.endsWith('\n') ? '' : '\n') : '') + outStr;
    } catch (e) {
        const errStr = (e && e.stderr || '');
        const outStr = (e && e.stdout || '');
        reqInfo = (errStr ? errStr + (errStr.endsWith('\n') ? '' : '\n') : '') + outStr;
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
