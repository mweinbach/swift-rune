// Node 22+ and Chrome/Chromium. Compiled Swift fixtures use @bjorn3/browser_wasi_shim.
import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { access, mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { tmpdir } from 'node:os';
import { basename, dirname, extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';

const { values: args } = parseArgs({ options: {
    chrome: { type: 'string' }, wasm: { type: 'string' }, 'image-wasm': { type: 'string' }, 'wasi-shim': { type: 'string' },
    angle: { type: 'string' }, 'device-scale': { type: 'string' }, fixture: { type: 'string' }
} });
const fixtures = dirname(fileURLToPath(import.meta.url));
const resources = resolve(fixtures, '../../Sources/Rune/Resources');
const shaderTypes = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
    '.wasm': 'application/wasm', '.ttf': 'font/ttf' };
const reactors = [args.wasm, args['image-wasm']].filter(Boolean);
if (Boolean(reactors.length) !== Boolean(args['wasi-shim'])) throw Error('Supply --wasi-shim with --wasm or --image-wasm');
if (reactors.length) await Promise.all([...reactors, join(args['wasi-shim'], 'index.js')].map(path => access(path)));
const files = await readdir(fixtures);
if (!args.fixture) {
    const tests = files.filter(name => name.endsWith('.test.mjs')).map(name => join(fixtures, name));
    if (tests.length) {
        const child = spawn(process.execPath, ['--test', ...tests], { stdio: 'inherit' });
        const [code] = await once(child, 'exit');
        if (code !== 0) process.exitCode = 1;
    }
}
const pages = files.filter(name => name.endsWith('.html') && (name !== 'hello-wasi.html' || args.wasm)
        && (name !== 'image-wasi.html' || args['image-wasm']))
    .filter(name => !args.fixture || basename(name, '.html') === args.fixture).sort();
if (!pages.length) throw Error('No matching fixtures');

async function chromium() {
    if (args.chrome || process.env.CHROME_BIN) return args.chrome || process.env.CHROME_BIN;
    const defaults = {
        darwin: ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
            '/Applications/Chromium.app/Contents/MacOS/Chromium'],
        win32: [join(process.env.ProgramFiles || '', 'Google/Chrome/Application/chrome.exe'),
            join(process.env['ProgramFiles(x86)'] || '', 'Microsoft/Edge/Application/msedge.exe')],
        linux: ['/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser']
    };
    for (const path of defaults[process.platform] ?? []) { try { await access(path); return path; } catch {} }
    throw Error('Set CHROME_BIN or --chrome to an installed browser executable');
}

function asset(path) {
    if (path === '/__rune/app.wasm') return args.wasm;
    if (path === '/__rune/image.wasm') return args['image-wasm'];
    for (const [prefix, dir] of [['/Tests/Browser/', fixtures], ['/Sources/Rune/Resources/', resources],
        ['/__rune/shim/', args['wasi-shim']]]) {
        if (!dir || !path.startsWith(prefix)) continue;
        const base = resolve(dir);
        const result = resolve(base, normalize(path.slice(prefix.length)));
        if (result.startsWith(base + sep)) return result;
    }
}

const exe = await chromium();
const profile = await mkdtemp(join(tmpdir(), 'rune-browser-'));
const server = createServer(async (req, res) => {
    try {
        const file = asset(decodeURIComponent(new URL(req.url, 'http://localhost').pathname));
        if (!file || !(await stat(file)).isFile()) throw Error();
        res.writeHead(200, { 'Content-Type': shaderTypes[extname(file)] ?? 'application/octet-stream' });
        createReadStream(file).on('error', () => res.destroy()).pipe(res);
    } catch { res.writeHead(404).end(); }
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const site = 'http://127.0.0.1:' + server.address().port;
const flags = ['--headless', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--window-size=1000,1000', '--remote-debugging-port=0', '--user-data-dir=' + profile];
if (args.angle) flags.push('--use-gl=angle', '--use-angle=' + args.angle);
if (args.angle === 'swiftshader') flags.push('--enable-unsafe-swiftshader');
if (args['device-scale']) flags.push('--force-device-scale-factor=' + args['device-scale']);
const browser = spawn(exe, [...flags, 'about:blank'], { stdio: 'ignore' });
let launchError;
browser.once('error', e => { launchError = e; });

function debugClient(ws) {
    let seq = 0;
    const pending = new Map();
    ws.addEventListener('message', event => {
        const m = JSON.parse(event.data);
        const call = pending.get(m.id);
        if (!call) return;
        pending.delete(m.id);
        clearTimeout(call.timeout);
        if (m.error) call.reject(Error(m.error.message)); else call.resolve(m.result);
    });
    ws.addEventListener('close', () => {
        for (const call of pending.values()) { clearTimeout(call.timeout); call.reject(Error('Browser tab closed')); }
        pending.clear();
    });
    return (method, params = {}) => new Promise((resolve, reject) => {
        const id = ++seq;
        const timeout = setTimeout(() => { pending.delete(id); reject(Error('Timed out in ' + method)); }, 30_000);
        pending.set(id, { resolve, reject, timeout });
        ws.send(JSON.stringify({ id, method, params }));
    });
}

async function fixture(debug, page) {
    const targetURL = site + '/Tests/Browser/' + page;
    const target = await (await fetch(debug + '/json/new?' + encodeURIComponent(targetURL), { method: 'PUT' })).json();
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    try {
        await once(ws, 'open');
        const command = debugClient(ws);
        const verify = page === 'hello-wasi.html' ? (await import('./hello-accessibility.mjs')).verifyHelloAccessibility : null;
        const read = async expression => {
            const response = await command('Runtime.evaluate', { expression, returnByValue: true });
            if (response.exceptionDetails) throw Error(response.exceptionDetails.text);
            return response.result.value;
        };
        let clicked = false, last;
        for (const until = Date.now() + 90_000; Date.now() < until;) {
            last = await read("document.querySelector('#result')?.textContent");
            if (last?.startsWith('PASS') || last?.startsWith('{"passed":true')) {
                if (verify) await verify(command, true);
                console.log(page, last);
                return;
            }
            if (/^(FAIL|Error|TypeError|RangeError|ReferenceError)/.test(last)) throw Error(last);
            if (page === 'hello-wasi.html' && last === 'Click the Lights switch' && !clicked) {
                await verify(command, false);
                const point = await read('window.runeClick');
                await command('Input.dispatchMouseEvent', { ...point, type: 'mouseMoved' });
                await command('Input.dispatchMouseEvent', { ...point, type: 'mousePressed', button: 'left', buttons: 1, clickCount: 1 });
                await command('Input.dispatchMouseEvent', { ...point, type: 'mouseReleased', button: 'left', clickCount: 1 });
                clicked = true;
            }
            await delay(80);
        }
        throw Error('Timed out: ' + (last || 'module did not start'));
    } finally {
        ws.close();
        await fetch(debug + '/json/close/' + target.id).catch(() => {});
    }
}

try {
    let port;
    for (const until = Date.now() + 15_000; !port && Date.now() < until;) {
        if (launchError) throw launchError;
        if (browser.exitCode !== null) throw Error('Chrome exited with ' + browser.exitCode);
        try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; } catch { await delay(80); }
    }
    if (!port) throw Error('Chrome debugging port did not open');
    for (const page of pages) {
        try { await fixture('http://127.0.0.1:' + port, page); }
        catch (error) { console.error(page, error.message); process.exitCode = 1; }
    }
} finally {
    const stopped = browser.exitCode !== null || launchError ? Promise.resolve() : once(browser, 'exit');
    browser.kill();
    server.closeAllConnections();
    server.close();
    await stopped;
    await rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
}
