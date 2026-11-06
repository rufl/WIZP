const fs = require('fs');
const https = require('https');

const MIN_AGE_DAYS = 7;
const MIN_AGE_MS = MIN_AGE_DAYS * 24 * 60 * 60 * 1000;

function fetchPackageMetadata(pkgName) {
    return new Promise((resolve, reject) => {
        const url = `https://registry.npmjs.org/${pkgName}`;
        https.get(url, { headers: { 'User-Agent': 'Wizp-Age-Verifier' } }, (res) => {
            if (res.statusCode !== 200) {
                return reject(new Error(`Failed to fetch metadata for ${pkgName}: HTTP ${res.statusCode}`));
            }
            let data = '';
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                try {
                    resolve(JSON.parse(data));
                } catch (err) {
                    reject(err);
                }
            });
        }).on('error', reject);
    });
}

async function verifyPackages(packageJsonPath) {
    console.log(`Checking packages in ${packageJsonPath}...`);
    const content = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
    const lockPath = require('path').join(require('path').dirname(packageJsonPath), 'package-lock.json');
    const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
    const dependencies = {
        ...(content.dependencies || {}),
        ...(content.devDependencies || {})
    };

    const pkgs = Object.keys(dependencies);
    let violations = 0;
    const errors = [];
    const checks = [];

    for (const pkg of pkgs) {
        const requestedVersion = dependencies[pkg];
        // Skip local or git paths
        if (requestedVersion.includes(':') || requestedVersion.includes('/') || requestedVersion.includes('#')) {
            console.log(`- Skipping non-npm package: ${pkg} (${requestedVersion})`);
            checks.push({ package: pkg, requested: requestedVersion, status: 'skipped-non-npm' });
            continue;
        }

        try {
            const cleanVersion = lock.packages?.[`node_modules/${pkg}`]?.version;
            if (!cleanVersion) {
                console.warn(`- No resolved lockfile version found for ${pkg}`);
                errors.push(`${pkg}: lockfile has no resolved version`);
                continue;
            }
            const metadata = await fetchPackageMetadata(pkg);
            const timeInfo = metadata.time;
            if (!timeInfo) {
                console.warn(`- No time info found for ${pkg}`);
                errors.push(`${pkg}: registry metadata has no publish times`);
                continue;
            }

            const publishTimeStr = timeInfo[cleanVersion];
            if (!publishTimeStr) {
                console.warn(`- No publish time found for ${pkg}@${cleanVersion}`);
                errors.push(`${pkg}@${cleanVersion}: registry metadata has no matching publish time`);
                continue;
            }

            const publishTime = new Date(publishTimeStr).getTime();
            const ageMs = Date.now() - publishTime;

            if (ageMs < MIN_AGE_MS) {
                const ageDays = (ageMs / (24 * 60 * 60 * 1000)).toFixed(1);
                console.error(`\x1b[31m[VIOLATION]\x1b[0m Package "${pkg}@${cleanVersion}" was published ${ageDays} days ago (minimum required: ${MIN_AGE_DAYS} days).`);
                violations++;
                checks.push({ package: pkg, requested: requestedVersion, version: cleanVersion, ageDays: Number(ageDays), status: 'too-new' });
            } else {
                console.log(`- Verified: ${pkg}@${cleanVersion} is older than ${MIN_AGE_DAYS} days.`);
                checks.push({ package: pkg, requested: requestedVersion, version: cleanVersion, ageDays: Number((ageMs / (24 * 60 * 60 * 1000)).toFixed(1)), status: 'verified' });
            }
        } catch (err) {
            console.error(`- Failed to verify ${pkg}: ${err.message}`);
            errors.push(`${pkg}: ${err.message}`);
        }
    }

    return { manifest: packageJsonPath, violations, errors, checks };
}

async function main() {
    try {
        const reports = [
            await verifyPackages('package.json'),
            await verifyPackages('frontend/package.json')
        ];
        const totalViolations = reports.reduce((total, report) => total + report.violations, 0);
        const totalErrors = reports.reduce((total, report) => total + report.errors.length, 0);
        const reportPath = process.argv[2] || 'build/parity-package/dependency-age-report.json';
        fs.mkdirSync(require('path').dirname(reportPath), { recursive: true });
        fs.writeFileSync(reportPath, JSON.stringify({
            generatedAt: new Date().toISOString(),
            minimumAgeDays: MIN_AGE_DAYS,
            status: totalViolations || totalErrors ? 'failed' : 'passed',
            reports
        }, null, 2) + '\n');
        console.log(`Wrote dependency age report to ${reportPath}`);

        if (totalViolations > 0 || totalErrors > 0) {
            console.error(`\n\x1b[31m[ERROR] Dependency age check failed with ${totalViolations} violations and ${totalErrors} metadata errors.\x1b[0m`);
            process.exit(1);
        } else {
            console.log('\n\x1b[32m[SUCCESS] All package versions meet the minimum age requirement.\x1b[0m');
        }
    } catch (err) {
        console.error('Check failed:', err);
        process.exit(1);
    }
}

main();
