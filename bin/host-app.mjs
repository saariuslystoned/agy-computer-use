#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export async function stageHostApp(options = {}) {
    const projectRoot = options.projectRoot || process.cwd();
    const root = path.resolve(projectRoot);
    const hostPackageDir = path.join(root, 'apps/computer-use-host');
    const stagedAppDir = options.targetDir ? path.resolve(options.targetDir) : path.join(hostPackageDir, '.build/staged/ComputerUseHost.app');

    // Validate target destination path to prevent arbitrary recursive deletion
    const allowedParent1 = path.resolve(hostPackageDir);
    const allowedParent2 = path.resolve(os.tmpdir());
    if (!stagedAppDir.startsWith(allowedParent1) && !stagedAppDir.startsWith(allowedParent2)) {
        throw new Error(`Invalid stage target directory ${stagedAppDir}: must be inside ${allowedParent1} or ${allowedParent2}`);
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

    const identifierMatch = (codesignInfo || '').match(/^Identifier=(.+)$/m);
    const signatureMatch = (codesignInfo || '').match(/^Signature=(.+)$/m);
    const teamIdMatch = (codesignInfo || '').match(/^TeamIdentifier=(.+)$/m);
    const authorityMatch = (codesignInfo || '').match(/^Authority=(.+)$/m);

    const identifier = identifierMatch ? identifierMatch[1].trim() : null;
    const signature = signatureMatch ? signatureMatch[1].trim() : null;
    const teamId = teamIdMatch ? teamIdMatch[1].trim() : null;
    const authority = authorityMatch ? authorityMatch[1].trim() : null;

    const expectedIdentifier = 'com.saariuslystoned.agy-computer-use.host';
    if (identifier !== expectedIdentifier) {
        return {
            classification: 'unsigned_or_invalid',
            identifier,
            teamId,
            details: `Identifier mismatch: expected ${expectedIdentifier}, got ${identifier}`
        };
    }

    const isAdHoc = (signature === 'adhoc') ||
        (authority && authority.includes('adhoc')) ||
        (!teamId || teamId === 'not set');

    if (isAdHoc) {
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

    const hasTeamId = Boolean(teamId && teamId !== 'not set');
    const reqStr = reqInfo || '';
    const hasDesignatedReq = reqStr.includes('designated =>') &&
        reqStr.includes(`identifier "${expectedIdentifier}"`) &&
        reqStr.includes(`certificate leaf[subject.OU] = "${teamId}"`);

    if (hasTeamId && hasDesignatedReq) {
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
