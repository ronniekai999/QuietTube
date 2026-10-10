/* QuietTube companion integration, GPL-3.0-or-later. Uses uBO Lite's engine. */
import { getFilteringMode, setFilteringModeDetails } from '../mode-manager.js';
import { registerContentScripts } from '../scripting-manager.js';
import { registerUserScripts } from '../compiled-filters.js';
import { ENGINE } from './engine.js';
import { PLATFORM } from './platform.js';

const HOST = 'com.quiettube.companion';
const SITE = 'https://www.youtube.com/*';
let ready;
let port;
let state = { enabled: true, effectiveEnabled: true, pausedUntilUtc: null, revision: 0 };
let connected = false;
let appRunning = false;
let engineError = null;
let connectionError = null;
let clientId;
let queue = Promise.resolve();
const requests = new Map();
class Superseded extends Error {}
const errorText = error => String(error.message || error);

function serial(task) {
    const result = queue.then(task);
    queue = result.catch(error => { if (!(error instanceof Superseded)) engineError = errorText(error); });
    return result;
}

function normalizeState(value) {
    if (!value || typeof value.enabled !== 'boolean' || typeof value.effectiveEnabled !== 'boolean' ||
        !Number.isSafeInteger(value.revision) || value.revision < 0 ||
        !(value.pausedUntilUtc === null || (typeof value.pausedUntilUtc === 'string' && Number.isFinite(Date.parse(value.pausedUntilUtc))))) {
        throw new Error(`The ${PLATFORM.companionName} returned invalid settings.`);
    }
    return { enabled: value.enabled, effectiveEnabled: value.effectiveEnabled,
        pausedUntilUtc: value.pausedUntilUtc, revision: value.revision };
}

// Count scripts which actually cover the protected page, including exclusions.
function coversYoutube(pattern) {
    if (pattern === '<all_urls>') return true;
    const match = /^(\*|https):\/\/([^/]+)\/(.*)$/.exec(pattern);
    if (!match) return false;
    const host = match[2];
    return (host === '*' || host === 'www.youtube.com' || host === '*.youtube.com') && match[3] === '*';
}
async function engineInfo() {
    const [siteAccess, youtubeMode, rulesets, scripts] = await Promise.all([
        chrome.permissions.contains({ origins: [SITE] }), getFilteringMode('www.youtube.com'),
        chrome.declarativeNetRequest.getEnabledRulesets(), chrome.scripting.getRegisteredContentScripts()
    ]);
    return { siteAccess, youtubeMode, enabledRulesets: rulesets.length,
        registeredScripts: scripts.filter(script => script.matches?.some(coversYoutube) &&
            !script.excludeMatches?.some(coversYoutube)).length };
}
function readiness(info) {
    let error = engineError;
    if (!error && state.effectiveEnabled) {
        if (!info.siteAccess) error = 'Allow QuietTube access to YouTube in the browser’s Extensions page, then reload YouTube.';
        else if (info.youtubeMode !== 2 || info.enabledRulesets === 0 || info.registeredScripts === 0) {
            error = 'YouTube filtering rules or scripts are missing. Reload QuietTube in the browser’s Extensions page.';
        }
    } else if (!error && (info.youtubeMode !== 0 || info.registeredScripts !== 0)) {
        error = 'YouTube filtering has not switched off. Reload QuietTube in the browser’s Extensions page.';
    }
    return { engineError: error, filteringReady: state.effectiveEnabled && !error, settingsApplied: !error };
}
async function updateBadge(info) {
    const { engineError: error, filteringReady } = readiness(info);
    await chrome.action.setTitle({ title: error ? 'QuietTube — filtering needs attention' : filteringReady ? 'QuietTube — protection on' : 'QuietTube — protection paused or off' });
    await chrome.action.setBadgeText({ text: error ? '!' : filteringReady ? '' : 'OFF' });
}
async function reportStatus(info = undefined) {
    const candidate = port;
    if (!candidate || !connected || !clientId) return;
    info ||= await engineInfo();
    if (port !== candidate || !connected) return;
    candidate.postMessage({ type: 'status', appliedEnabled: state.effectiveEnabled, appliedRevision: state.revision,
        youtubeMode: info.youtubeMode, enabledRulesets: info.enabledRulesets,
        registeredScripts: info.registeredScripts, error: readiness(info).engineError });
}

async function apply(value, isCurrent = () => true) {
    const next = normalizeState(value);
    const previous = state;
    const check = () => { if (!isCurrent()) throw new Superseded('Companion connection changed.'); };
    check();
    engineError = null;
    try {
        const siteAccess = await chrome.permissions.contains({ origins: [SITE] });
        check();
        await setFilteringModeDetails({ none: ['all-urls'], basic: [],
            optimal: next.effectiveEnabled && siteAccess ? ['youtube.com'] : [], complete: [] });
        check();
        await Promise.all([registerContentScripts(), registerUserScripts()]);
        check();
    } catch (error) {
        if (error instanceof Superseded) throw error;
        engineError = errorText(error);
    }
    check();
    // Commit only settings from the still-live connection. The serial queue keeps
    // a later offline command behind this write and its possible restoration.
    await chrome.storage.local.set({ quiettubeState: next });
    if (!isCurrent()) {
        await chrome.storage.local.set({ quiettubeState: previous });
        throw new Superseded('Companion connection changed.');
    }
    state = next;
    if (state.pausedUntilUtc && Date.parse(state.pausedUntilUtc) > Date.now()) {
        await chrome.alarms.create('quiettube-pause', { when: Date.parse(state.pausedUntilUtc) });
    } else {
        await chrome.alarms.clear('quiettube-pause');
    }
    check();
    const info = await engineInfo();
    check();
    await updateBadge(info);
    await reportStatus(info);
}

async function snapshot() {
    await ready;
    return serial(async () => {
        const info = await engineInfo();
        await updateBadge(info);
        await reportStatus(info);
        return { ...state, ...info, ...readiness(info), connected, appRunning, connectionError,
            browser: PLATFORM.browser,
            extensionVersion: chrome.runtime.getManifest().version, engine: ENGINE };
    });
}
function settle(id, error) {
    const request = requests.get(id);
    if (!request) return;
    clearTimeout(request.timer);
    requests.delete(id);
    if (error) request.reject(new Error(error)); else request.resolve();
}
function nativeRequest(message) {
    const candidate = port;
    if (!candidate || !connected) return Promise.reject(new Error(`${PLATFORM.companionName} is unavailable.`));
    const requestId = crypto.randomUUID();
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => settle(requestId, `${PLATFORM.companionName} did not respond.`), 8000);
        requests.set(requestId, { resolve, reject, timer });
        try { candidate.postMessage({ ...message, requestId }); }
        catch (error) { disconnect(candidate, errorText(error)); }
    });
}
function disconnect(candidate, reason) {
    if (port !== candidate) return;
    port = undefined;
    connected = false;
    appRunning = false;
    connectionError = reason;
    for (const id of requests.keys()) settle(id, reason);
    // Undo any physical engine change from a now-invalid in-flight message.
    serial(() => {
        const expired = state.pausedUntilUtc && Date.parse(state.pausedUntilUtc) <= Date.now();
        return apply(expired ? { ...state, pausedUntilUtc: null, effectiveEnabled: state.enabled } : state);
    });
}
function connect(force = false) {
    if (port && !force) return;
    if (port) {
        const old = port;
        disconnect(old, `Reconnecting ${PLATFORM.companionName}.`);
        old.disconnect();
    }
    connectionError = null;
    try {
        const candidate = PLATFORM.connectNative(HOST);
        port = candidate;
        const isCurrent = () => port === candidate;
        let nativeRevision = -1;
        let replay;
        candidate.onMessage.addListener(message => {
            if (!isCurrent()) return;
            if (message.type === 'ping') { serial(() => isCurrent() && reportStatus()); return; }
            if (message.type === 'error') {
                connectionError = message.message;
                if (replay?.requestId === message.requestId) replay = undefined;
                settle(message.requestId, message.message);
                return;
            }
            if (message.type !== 'state') return;
            serial(async () => {
                if (!isCurrent()) return;
                try {
                    normalizeState(message);
                    const saved = await chrome.storage.local.get('quiettubePending');
                    if (!isCurrent()) return;
                    let pending = saved.quiettubePending;
                    if (pending && !pending.id) {
                        pending = { ...pending, id: crypto.randomUUID() };
                        await chrome.storage.local.set({ quiettubePending: pending });
                        if (!isCurrent()) return;
                    }
                    if (pending && !(replay?.id === pending.id && replay.requestId === message.requestId)) {
                        // An offline change must be acknowledged before accepting desktop state.
                        // Match its token so an old acknowledgment cannot erase a newer change.
                        if (replay?.id !== pending.id || Date.now() - replay.sentAt > 8000) {
                            replay = { id: pending.id, requestId: 'pending-' + crypto.randomUUID(), sentAt: Date.now() };
                            candidate.postMessage({ type: 'setProtection', requestId: replay.requestId, enabled: pending.enabled,
                                pauseMinutes: pending.pausedUntilUtc ? Math.max(0, Math.min(1440, Math.ceil((Date.parse(pending.pausedUntilUtc) - Date.now()) / 60000))) : 0 });
                        }
                        return;
                    }
                    if (message.revision < nativeRevision) { settle(message.requestId); return; }
                    await apply(message, isCurrent);
                    if (!isCurrent()) return;
                    if (pending) await chrome.storage.local.remove('quiettubePending');
                    if (!isCurrent()) return;
                    replay = undefined;
                    nativeRevision = message.revision;
                    connected = true;
                    appRunning = message.appRunning === true;
                    connectionError = null;
                    settle(message.requestId);
                    await reportStatus();
                } catch (error) {
                    if (!isCurrent() || error instanceof Superseded) return;
                    engineError = errorText(error);
                    settle(message.requestId, engineError);
                    await reportStatus().catch(() => {});
                }
            });
        });
        candidate.onDisconnect.addListener(() => disconnect(candidate,
            chrome.runtime.lastError?.message || `${PLATFORM.companionName} disconnected.`));
        candidate.postMessage({ type: 'hello', requestId: 'hello-' + crypto.randomUUID(), clientId,
            browser: PLATFORM.browser,
            extensionVersion: chrome.runtime.getManifest().version, engineVersion: ENGINE.version });
    } catch (error) {
        if (port) disconnect(port, errorText(error));
        else connectionError = errorText(error);
    }
}
async function saveOffline(enabled, pauseMinutes) {
    return serial(async () => {
        const pausedUntilUtc = enabled && pauseMinutes > 0 ? new Date(Date.now() + pauseMinutes * 60000).toISOString() : null;
        const next = { enabled, effectiveEnabled: enabled && pauseMinutes === 0, pausedUntilUtc, revision: state.revision + 1 };
        await chrome.storage.local.set({ quiettubePending: { id: crypto.randomUUID(), enabled, pausedUntilUtc } });
        await apply(next);
    });
}
async function setProtection(enabled, pauseMinutes = 0) {
    await ready;
    if (typeof enabled !== 'boolean' || !Number.isInteger(pauseMinutes) || pauseMinutes < 0 || pauseMinutes > 1440) {
        throw new Error('Invalid protection setting.');
    }
    if (connected) {
        try { await nativeRequest({ type: 'setProtection', enabled, pauseMinutes }); }
        catch (error) { if (connected) throw error; await saveOffline(enabled, pauseMinutes); }
    } else {
        await saveOffline(enabled, pauseMinutes);
    }
    return snapshot();
}
async function expirePause() {
    await ready;
    const request = await serial(async () => {
        const deadline = Date.parse(state.pausedUntilUtc);
        if (!Number.isFinite(deadline) || deadline > Date.now()) return false;
        if (connected) return true; // The native host computes expiration from its current settings.
        await apply({ ...state, pausedUntilUtc: null, effectiveEnabled: state.enabled });
        return false;
    });
    // State responses also use the queue: never wait for one inside a queued task.
    if (request) await nativeRequest({ type: 'getState' });
}

export function initializeCompanion(engineReady) {
    ready = engineReady.then(async () => {
        const saved = await chrome.storage.local.get(['quiettubeState', 'quiettubeClientId']);
        clientId = saved.quiettubeClientId || crypto.randomUUID();
        await chrome.storage.local.set({ quiettubeClientId: clientId });
        let initial = saved.quiettubeState || state;
        if (initial.pausedUntilUtc && Date.parse(initial.pausedUntilUtc) <= Date.now()) initial = { ...initial, pausedUntilUtc: null, effectiveEnabled: initial.enabled };
        await apply(initial);
        connect();
        await chrome.alarms.create('quiettube-reconnect', { periodInMinutes: 1 });
    }).catch(error => { engineError = errorText(error); });

    // Register listeners synchronously so MV3 wakeups cannot drop events.
    chrome.runtime.onMessage.addListener((message, sender, reply) => {
        if (typeof message.what !== 'string' || !message.what.startsWith('quiettube:')) return;
        if (sender.id !== chrome.runtime.id || !sender.url?.startsWith(chrome.runtime.getURL('quiettube/'))) {
            reply({ error: 'This command is only available to QuietTube extension pages.' });
            return;
        }
        (async () => {
            await ready;
            switch (message.what) {
                case 'quiettube:status': return snapshot();
                case 'quiettube:setProtection': return setProtection(message.enabled, message.pauseMinutes ?? 0);
                case 'quiettube:reconnect': connect(true); return snapshot();
                case 'quiettube:reloadYoutube': {
                    const tabs = await chrome.tabs.query({ url: ['https://*.youtube.com/*'] });
                    await Promise.all(tabs.map(tab => chrome.tabs.reload(tab.id)));
                    return { reloaded: tabs.length };
                }
                default: throw new Error('Unknown QuietTube command.');
            }
        })().then(reply, error => reply({ error: errorText(error) }));
        return true;
    });
    chrome.alarms.onAlarm.addListener(alarm => {
        if (alarm.name === 'quiettube-reconnect') ready.then(() => connect()).catch(() => {});
        if (alarm.name === 'quiettube-pause') expirePause().catch(error => { connectionError = errorText(error); });
    });
    const permissionsChanged = () => ready.then(() => serial(() => apply(state))).catch(() => {});
    chrome.permissions.onRemoved.addListener(permissionsChanged);
    chrome.permissions.onAdded.addListener(permissionsChanged);
}
