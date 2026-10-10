import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const project = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const workspace = path.resolve(project, '../..');
const require = createRequire(path.join(workspace, 'work/browser-tests/package.json'));
const { chromium } = require('playwright');
const exec = promisify(execFile);
const extensionId = (await fs.readFile(path.join(project, 'extension-id.txt'), 'utf8')).trim();
const nativeHost = path.resolve(process.env.QUIETTUBE_TEST_HOST || path.join(workspace, 'work/publish/host-mac/QuietTube.Host'));
const root = path.join(workspace, 'work/tests/browser-' + Date.now());
const extension = path.join(root, 'extension');
const data = path.join(root, 'data');
const results = [];
const errors = [];
const contexts = [];
await fs.mkdir(data, { recursive: true });
await fs.cp(process.env.QUIETTUBE_TEST_EXTENSION || path.join(project, 'extension'), extension, { recursive: true });

async function start(name, native = true) {
    const profile = path.join(root, name);
    await fs.mkdir(path.join(profile, 'NativeMessagingHosts'), { recursive: true });
    if (native) {
        await fs.writeFile(path.join(profile, 'NativeMessagingHosts/com.quiettube.companion.json'), JSON.stringify({
            name: 'com.quiettube.companion', description: 'QuietTube isolated integration test', path: nativeHost,
            type: 'stdio', allowed_origins: [`chrome-extension://${extensionId}/`],
            ...(process.env.QUIETTUBE_TEST_HOST ? { quiettubeOwner: 'com.quiettube.mac' } : {})
        }));
    }
    const context = await chromium.launchPersistentContext(profile, {
        channel: 'chromium', headless: true,
        env: { ...process.env, QUIETTUBE_DATA_DIR: data },
        args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`],
        viewport: { width: 1000, height: 760 }
    });
    contexts.push(context);
    const worker = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker', { timeout: 20000 });
    assert.ok(worker.url().includes(extensionId), 'Expected the QuietTube service worker.');
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`chrome-extension://${extensionId}/quiettube/popup.html`);
    await page.getByRole('button', { name: 'Turn protection off', exact: true }).waitFor({ timeout: 20000 });
    return { context, page, profile };
}

async function status(page) { return page.evaluate(() => chrome.runtime.sendMessage({ what: 'quiettube:status' })); }
async function command(page, enabled, pauseMinutes = 0) {
    const result = await page.evaluate(({ enabled, pauseMinutes }) => chrome.runtime.sendMessage({ what: 'quiettube:setProtection', enabled, pauseMinutes }), { enabled, pauseMinutes });
    assert.equal(result.error, undefined, result.error);
    return result;
}
async function until(task, predicate, label, timeout = Number(process.env.QUIETTUBE_TEST_TIMEOUT || 15000)) {
    const limit = Date.now() + timeout;
    let last;
    while (Date.now() < limit) {
        const result = await task();
        last = result;
        if (predicate(result)) return result;
        await new Promise(resolve => setTimeout(resolve, 150));
    }
    throw new Error('Timed out: ' + label + (last?.connectionError ? ' — ' + last.connectionError : ''));
}

try {
    const first = await start('first');
    let state = await until(() => status(first.page), value => value.connected, 'real native messaging handshake');
    assert.equal(state.engineError, null);
    assert.equal(state.youtubeMode, 2);
    assert.equal(state.filteringReady, true);
    assert.ok(state.enabledRulesets > 0 && state.registeredScripts > 0);
    results.push('Real browser → native host handshake and filtering-engine readiness');

    const second = await start('second');
    await until(() => status(second.page), value => value.connected, 'second profile native handshake');
    await first.page.getByRole('button', { name: 'Turn protection off', exact: true }).click();
    await until(() => status(second.page), value => value.effectiveEnabled === false && value.youtubeMode === 0, 'cross-profile off synchronization');
    results.push('Popup off command synchronizes to another real browser profile');

    await exec(nativeHost, ['--set-enabled', 'true'], { env: { ...process.env, QUIETTUBE_DATA_DIR: data } });
    await until(() => status(first.page), value => value.effectiveEnabled && value.youtubeMode === 2, 'external desktop-equivalent control');
    await until(() => status(second.page), value => value.effectiveEnabled && value.youtubeMode === 2, 'second profile resume');
    results.push('External controller change pushes back into both browser profiles');

    await command(first.page, true, 15);
    state = await until(() => status(second.page), value => value.effectiveEnabled === false && value.pausedUntilUtc, 'timed pause synchronization');
    assert.ok(Date.parse(state.pausedUntilUtc) > Date.now());
    await command(first.page, true);
    results.push('Timed pause and resume synchronize through native messaging');

    // Shorten a pause only in this isolated fixture to exercise real native
    // expiration and browser alarms without waiting fifteen minutes.
    await command(first.page, true, 15);
    const settingsFile = path.join(data, 'settings.json');
    const settings = JSON.parse(await fs.readFile(settingsFile, 'utf8'));
    settings.pausedUntilUtc = new Date(Date.now() + 3000).toISOString();
    settings.revision++;
    await fs.writeFile(settingsFile + '.test', JSON.stringify(settings));
    await fs.rename(settingsFile + '.test', settingsFile);
    await until(() => status(second.page), value => value.revision === settings.revision && !value.effectiveEnabled, 'short test deadline synchronization');
    await until(() => status(first.page), value => value.filteringReady && value.revision === settings.revision, 'automatic pause expiry in first profile');
    await until(() => status(second.page), value => value.filteringReady && value.revision === settings.revision, 'automatic pause expiry in second profile');
    await command(first.page, true);
    results.push('Real native pause expiry automatically restores filtering in both profiles (short isolated deadline)');

    const fixture = await first.context.newPage();
    let adRequests = 0;
    const failed = [];
    await first.context.route('https://googleads.g.doubleclick.net/**', route => {
        adRequests++;
        return route.fulfill({ status: 200, contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>' });
    });
    const fixtureHtml = '<!doctype html><html><head><meta charset="utf-8"></head><body><h1>QuietTube network fixture</h1><img src="https://googleads.g.doubleclick.net/pagead/ads?quiettube-fixture=1" onload="window.fixtureDone=true" onerror="window.fixtureDone=true"></body></html>';
    await first.context.route('https://www.youtube.com/quiettube-fixture/**', route => route.fulfill({ status: 200, contentType: 'text/html', body: fixtureHtml }));
    await first.context.route('https://example.com/quiettube-fixture/**', route => route.fulfill({ status: 200, contentType: 'text/html', body: fixtureHtml }));
    fixture.on('requestfailed', request => failed.push({ url: request.url(), error: request.failure()?.errorText }));
    await command(first.page, true);
    await fixture.goto('https://www.youtube.com/quiettube-fixture/on');
    await fixture.waitForFunction(() => window.fixtureDone === true);
    assert.equal(adRequests, 0, 'Known ad request should be blocked on YouTube.');
    assert.ok(failed.some(request => request.error?.includes('ERR_BLOCKED_BY_CLIENT')), 'Expected a real DNR network block.');
    results.push('Actual network request to known ad endpoint is blocked in a YouTube page');

    await fixture.goto('https://example.com/quiettube-fixture/outside');
    await fixture.waitForFunction(() => window.fixtureDone === true);
    assert.equal(adRequests, 1, 'Outside-YouTube browsing must not be filtered.');
    results.push('Same network request is allowed outside YouTube');
    await command(first.page, false);
    await fixture.goto('https://www.youtube.com/quiettube-fixture/off');
    await fixture.waitForFunction(() => window.fixtureDone === true);
    assert.equal(adRequests, 2, 'Turning off must allow the previously blocked request.');
    results.push('Off control removes the real network block');

    await command(first.page, true);
    const details = await first.context.newPage();
    await details.goto(`chrome://extensions/?id=${extensionId}`);
    await details.getByText('Site access', { exact: true }).waitFor();
    await details.locator('#allHostsToggle').click();
    state = await until(() => status(first.page), value => !value.siteAccess && !value.filteringReady && value.youtubeMode === 0 && value.registeredScripts === 0, 'revoked YouTube permission');
    assert.match(state.engineError, /Allow QuietTube access/);
    await first.page.getByText('Filtering needs attention', { exact: true }).waitFor();
    assert.equal(await first.page.evaluate(() => chrome.action.getBadgeText({})), '!');
    await until(async () => {
        const files = await fs.readdir(path.join(data, 'clients'));
        return Promise.all(files.filter(f => f.endsWith('.json')).map(async f => JSON.parse(await fs.readFile(path.join(data, 'clients', f), 'utf8'))));
    }, value => value.some(client => client.error?.includes('Allow QuietTube access') && client.youtubeMode === 0), 'native readiness acknowledgment after permission loss');
    results.push('Revoking YouTube access updates the real popup, badge and native acknowledgment to needs attention');
    await details.locator('#allHostsToggle').click();
    await until(() => status(first.page), value => value.siteAccess && value.filteringReady && !value.engineError, 'restored YouTube permission');
    await first.page.getByText('Protection is on', { exact: true }).waitFor();
    assert.equal(await first.page.evaluate(() => chrome.action.getBadgeText({})), '');
    await details.close();
    results.push('Restoring YouTube access restores real filtering readiness and popup status');
    await first.page.getByRole('button', { name: 'Turn protection off', exact: true }).waitFor();
    await first.page.locator('body').screenshot({ path: process.env.QUIETTUBE_TEST_SCREENSHOT || path.join(project, 'extension-preview.png') });
    await command(first.page, false);
    await first.context.close();
    contexts.splice(contexts.indexOf(first.context), 1);
    // Reopen the same saved browser profile; off must survive a browser restart.
    const reopened = await chromium.launchPersistentContext(first.profile, {
        channel: 'chromium', headless: true, env: { ...process.env, QUIETTUBE_DATA_DIR: data },
        args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`]
    });
    contexts.push(reopened);
    if (!reopened.serviceWorkers().length) await reopened.waitForEvent('serviceworker', { timeout: 20000 });
    const reopenedPage = await reopened.newPage();
    await reopenedPage.goto(`chrome-extension://${extensionId}/quiettube/popup.html`);
    await until(() => status(reopenedPage), value => value.effectiveEnabled === false && value.youtubeMode === 0, 'saved off after browser restart');
    results.push('Saved off setting survives a full browser restart');

    // Invalid commands come from the real extension page and reach the real host.
    const rejected = await reopenedPage.evaluate(async () => {
        const p = chrome.runtime.connectNative('com.quiettube.companion');
        return new Promise(resolve => {
            p.onMessage.addListener(message => { resolve(message); p.disconnect(); });
            p.postMessage({ type: 'setProtection', enabled: true, requestId: 'without-hello' });
        });
    });
    assert.equal(rejected.type, 'error');
    assert.match(rejected.message, /hello/);
    results.push('Native host rejects commands before a valid handshake');

    const savedClients = await fs.readdir(path.join(data, 'clients'));
    const clients = await Promise.all(savedClients.filter(file => file.endsWith('.json')).map(async file => JSON.parse(await fs.readFile(path.join(data, 'clients', file), 'utf8'))));
    assert.ok(clients.length >= 2);
    assert.ok(clients.every(client => !('url' in client) && !('history' in client) && !('cookies' in client)));
    results.push('Native diagnostics contain filtering acknowledgments without page URLs or cookies');
    assert.deepEqual(errors, []);
} catch (error) {
    errors.push(error.stack || error.message);
    process.exitCode = 1;
} finally {
    for (const context of contexts) await context.close();
    const report = { testedAtUtc: new Date().toISOString(), platform: 'macOS arm64', browser: 'isolated Playwright Chromium', results, errors,
        limitation: process.env.QUIETTUBE_TEST_HOST ? 'Isolated Chromium with the native Swift Mac host. Safari, menu bar UI, and actual YouTube pre-roll/mid-roll playback require separate acceptance checks.' : 'Windows 11 Edge, Windows installer/tray runtime, and actual YouTube pre-roll/mid-roll playback remain device acceptance checks.' };
    await fs.writeFile(process.env.QUIETTUBE_TEST_REPORT || path.join(project, 'browser-test-results.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
}
