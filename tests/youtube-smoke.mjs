import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
const project = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const workspace = path.resolve(project, '../..');
const require = createRequire(path.join(workspace, 'work/browser-tests/package.json'));
const { chromium } = require('playwright');
const id = (await fs.readFile(path.join(project, 'extension-id.txt'), 'utf8')).trim();
const root = path.join(workspace, 'work/tests/youtube-' + Date.now());
const extension = path.join(root, 'extension');
const profile = path.join(root, 'profile');
const data = path.join(root, 'data');
await fs.mkdir(path.join(profile, 'NativeMessagingHosts'), { recursive: true });
await fs.mkdir(data, { recursive: true });
await fs.cp(path.join(project, 'extension'), extension, { recursive: true });
await fs.writeFile(path.join(profile, 'NativeMessagingHosts/com.quiettube.companion.json'), JSON.stringify({
    name: 'com.quiettube.companion', description: 'QuietTube isolated smoke test',
    path: path.join(workspace, 'work/publish/host-mac/QuietTube.Host'), type: 'stdio',
    allowed_origins: [`chrome-extension://${id}/`]
}));
const context = await chromium.launchPersistentContext(profile, {
    channel: 'chromium', headless: process.env.QUIETTUBE_SMOKE_HEADED !== '1', env: { ...process.env, QUIETTUBE_DATA_DIR: data },
    args: [`--disable-extensions-except=${extension}`, `--load-extension=${extension}`]
});
const report = { testedAtUtc: new Date().toISOString(), platform: 'macOS Chromium, signed out', playbackObserved: false,
    limitation: 'One signed-out Mac playback smoke test cannot establish Windows Edge compatibility or comprehensive video-ad removal.' };
try {
    if (!context.serviceWorkers().length) await context.waitForEvent('serviceworker');
    const popup = await context.newPage();
    await popup.goto(`chrome-extension://${id}/quiettube/popup.html`);
    await popup.getByRole('button', { name: 'Turn protection off', exact: true }).waitFor({ timeout: 15000 });
    const page = await context.newPage();
    const videoUrl = process.env.QUIETTUBE_TEST_VIDEO_URL || 'https://www.youtube.com/watch?v=t6MAZW-joCo';
    report.testVideoUrl = videoUrl;
    await page.goto(videoUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    const consent = page.getByRole('button', { name: /^Reject all$/i });
    if (await consent.isVisible()) await consent.click();
    await page.locator('video').first().waitFor({ state: 'attached', timeout: 15000 });
    await page.evaluate(async () => { const video = document.querySelector('video'); video.muted = true; try { await video.play(); } catch {} });
    await page.waitForFunction(() => {
        const video = document.querySelector('video');
        return video && video.currentTime > 5 && video.readyState >= 2 && !video.paused;
    }, null, { timeout: 20000 });
    report.playbackObserved = true;
    report.video = await page.evaluate(() => {
        const video = document.querySelector('video');
        return { currentTime: video.currentTime, readyState: video.readyState, paused: video.paused,
            playerShowingAd: Boolean(document.querySelector('#movie_player.ad-showing')), dimensions: [video.videoWidth, video.videoHeight] };
    });
    report.engine = await popup.evaluate(() => chrome.runtime.sendMessage({ what: 'quiettube:status' }));
} catch (error) {
    report.error = error.message;
    const page = context.pages().at(-1);
    if (page) {
        report.playerMessage = await page.locator('.ytp-error-content-wrap').innerText({ timeout: 1000 }).catch(() => '');
        report.pageMessage = (await page.locator('body').innerText().catch(() => '')).slice(0, 800);
        await page.screenshot({ path: path.join(root, 'youtube-result.png') }).catch(() => {});
    }
} finally {
    await context.close();
    await fs.writeFile(path.join(project, 'youtube-smoke-results.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
}
