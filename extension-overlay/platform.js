/* QuietTube browser transports, GPL-3.0-or-later. */
// Safari sends request/reply messages to its bundled app extension. Its native
// port receives containing-app notifications; it is not Chrome's stdio port.
export function createPlatform(api, userAgent, timers = globalThis) {
    const safari = api.runtime.getURL('').startsWith('safari-web-extension:');
    const mac = safari || /Macintosh|Mac OS X/.test(userAgent);
    const browser = safari ? 'Safari' : userAgent.includes('Edg/') ? 'Edge' : 'Chrome';
    function event() {
        const listeners = new Set();
        return { addListener: listener => listeners.add(listener),
            emit: value => { for (const listener of listeners) listener(value); } };
    }
    function connectNative(host) {
        if (!safari) return api.runtime.connectNative(host);
        const onMessage = event();
        const onDisconnect = event();
        let closed = false;
        let identity;
        let signature;
        let polling = false;
        let timer;
        let wakePort;
        const now = timers.now || (() => Date.now());
        let lastPing = now();
        const port = { onMessage, onDisconnect, postMessage, disconnect };
        function disconnect() {
            if (closed) return;
            closed = true;
            timers.clearInterval(timer);
            wakePort?.disconnect();
            onDisconnect.emit();
        }
        async function send(message) {
            if (closed) return;
            const response = await api.runtime.sendNativeMessage(host, { ...identity, ...message });
            if (closed) return;
            if (!response || typeof response.type !== 'string') throw new Error('The Mac companion returned an invalid response.');
            if (response.type === 'state') {
                const next = JSON.stringify([response.enabled, response.effectiveEnabled, response.pausedUntilUtc,
                    response.revision, response.appRunning]);
                if (!response.requestId && next === signature) return;
                signature = next;
            }
            if (response.type !== 'ack') onMessage.emit(response);
        }
        function postMessage(message) {
            if (closed) throw new Error('Mac companion disconnected.');
            if (message.type === 'hello') identity = { clientId: message.clientId, browser,
                extensionVersion: message.extensionVersion, engineVersion: message.engineVersion };
            if (!identity) throw new Error('Send hello before commands.');
            send(message).catch(() => disconnect());
        }
        async function poll() {
            if (closed || !identity || polling) return;
            polling = true;
            try {
                await send({ type: 'getState' });
                // Refresh acknowledgments even when settings are unchanged;
                // otherwise the app would mark a working Safari client stale.
                if (!closed && now() - lastPing >= 20000) {
                    lastPing = now(); onMessage.emit({ type: 'ping' });
                }
            }
            catch { disconnect(); }
            finally { polling = false; }
        }
        // The polling fallback also handles app relaunch and a missed native
        // notification. Safari may suspend the background page; initialization
        // performs a new hello when it wakes, and alarms cover timed pauses.
        timer = timers.setInterval(poll, 2000);
        try {
            wakePort = api.runtime.connectNative(host);
            wakePort.onMessage.addListener(() => poll());
        } catch { /* Request/reply messaging remains available without a port. */ }
        return port;
    }
    return { browser, mac, safari, appName: mac ? 'Mac app' : 'Windows app',
        companionName: mac ? 'Mac companion' : 'Windows companion', connectNative };
}

export const PLATFORM = createPlatform(globalThis.browser || globalThis.chrome, navigator.userAgent);
