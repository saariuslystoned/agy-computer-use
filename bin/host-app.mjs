#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export async function stageHostApp(projectRoot = process.cwd()) {
    const root = path.resolve(projectRoot);
    const hostPackageDir = path.join(root, 'apps/computer-use-host');
    const stagedAppDir = path.join(hostPackageDir, '.build/staged/ComputerUseHost.app');
    const contentsDir = path.join(stagedAppDir, 'Contents');
    const macOSDir = path.join(contentsDir, 'MacOS');
    const resourcesDir = path.join(contentsDir, 'Resources');
    const infoPlistSource = path.join(hostPackageDir, 'Info.plist');
    const releaseBinarySource = path.join(hostPackageDir, '.build/release/ComputerUseHost');
    const binaryTarget = path.join(macOSDir, 'ComputerUseHost');
    const infoPlistTarget = path.join(contentsDir, 'Info.plist');

    // 1. Build Swift release executable with strict concurrency flags
    await execFileAsync('swift', [
        'build',
        '--package-path', hostPackageDir,
        '--configuration', 'release',
        '--product', 'ComputerUseHost',
        '-Xswiftc', '-strict-concurrency=complete',
        '-Xswiftc', '-warnings-as-errors'
    ], { cwd: root });

    // 2. Prepare bundle directory structure cleanly
    if (fs.existsSync(stagedAppDir)) {
        fs.rmSync(stagedAppDir, { recursive: true, force: true });
    }
    fs.mkdirSync(macOSDir, { recursive: true });
    fs.mkdirSync(resourcesDir, { recursive: true });

    // 3. Copy binary and Info.plist
    fs.copyFileSync(releaseBinarySource, binaryTarget);
    fs.chmodSync(binaryTarget, 0o755);
    fs.copyFileSync(infoPlistSource, infoPlistTarget);

    // 4. Ad-hoc sign bundle using argument arrays (no shell string concatenation)
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

export async function classifyPrincipal(appPath, options = {}) {
    const absPath = path.resolve(appPath);
    const binaryPath = path.join(absPath, 'Contents/MacOS/ComputerUseHost');
    const infoPlistPath = path.join(absPath, 'Contents/Info.plist');

    if (!fs.existsSync(absPath) || !fs.existsSync(binaryPath) || !fs.existsSync(infoPlistPath)) {
        return { classification: 'unsigned_or_invalid', details: 'Missing bundle files' };
    }

    try {
        await execFileAsync('codesign', ['-v', absPath]);
    } catch {
        return { classification: 'unsigned_or_invalid', details: 'Codesign verification failed' };
    }

    let codesignInfo = '';
    try {
        const { stdout, stderr } = await execFileAsync('codesign', ['-dv', '--verbose=4', absPath]);
        codesignInfo = stdout + stderr;
    } catch (e) {
        return { classification: 'unsigned_or_invalid', details: String(e) };
    }

    let reqInfo = '';
    try {
        const { stdout, stderr } = await execFileAsync('codesign', ['--display', '--requirements', '-', absPath]);
        reqInfo = stdout + stderr;
    } catch {
        reqInfo = '';
    }

    const identifierMatch = codesignInfo.match(/^Identifier=(.+)$/m);
    const signatureMatch = codesignInfo.match(/^Signature=(.+)$/m);
    const teamIdMatch = codesignInfo.match(/^TeamIdentifier=(.+)$/m);
    const authorityMatch = codesignInfo.match(/^Authority=(.+)$/m);

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
                teamId,
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
    const hasDesignatedReq = reqInfo.includes('designated') && reqInfo.includes(expectedIdentifier);

    if (hasTeamId && hasDesignatedReq) {
        return {
            classification: 'stable_team_signed_candidate',
            identifier,
            teamId,
            details: 'Valid team signature candidate'
        };
    }

    return {
        classification: 'ad_hoc_ephemeral',
        identifier,
        teamId: null,
        details: 'Missing stable team requirements'
    };
}

async function main() {
    const args = process.argv.slice(2);
    const command = args[0];

    if (command === 'stage') {
        const result = await stageHostApp();
        const classification = await classifyPrincipal(result.appPath);
        console.log(JSON.stringify({ ...result, principal: classification }, null, 2));
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
        console.log(JSON.stringify(result, null, 2));

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
