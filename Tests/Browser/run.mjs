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
    chrome: { type: 'string' }, wasm: { type: 'string' }, 'image-wasm': { type: 'string' }, 'image-page-wasm': { type: 'string' },
    'wake-wasm': { type: 'string' }, 'diagnostics-wasm': { type: 'string' }, 'spell-wasm': { type: 'string' }, 'sketch-wasm': { type: 'string' }, 'wasi-shim': { type: 'string' },
    angle: { type: 'string' }, 'device-scale': { type: 'string' }, fixture: { type: 'string' },
    webgpu: { type: 'boolean' }, 'www-wasm': { type: 'string' }, 'table-wasm': { type: 'string' },
    'tree-wasm': { type: 'string' }, 'compare-accessibility': { type: 'boolean' }
} });
const fixtures = dirname(fileURLToPath(import.meta.url));
const resources = resolve(fixtures, '../../Sources/Rune/Resources');
const shaderTypes = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
    '.wasm': 'application/wasm', '.ttf': 'font/ttf' };
const largeViews = ['table', 'tree'].filter(name => args[name + '-wasm']);
const reactors = [args.wasm, args['wake-wasm'], args['diagnostics-wasm'], args['www-wasm'], ...largeViews.map(name => args[name + '-wasm']), args['image-page-wasm'], args['image-wasm'], args['sketch-wasm'], args['spell-wasm']].filter(Boolean);
if (Boolean(reactors.length) !== Boolean(args['wasi-shim'])) throw Error('Supply --wasi-shim with a compiled WASI fixture');
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
const pages = files.filter(name => name.endsWith('.html') && (!['hello-wasi.html', 'cpu-damage-wasi.html'].includes(name) || args.wasm)
        && (name !== 'document-wasi.html' || args['www-wasm']) && (name !== 'large-view-wasi.html' || largeViews.length)
        && (name !== 'diagnostics-wasi.html' || args['diagnostics-wasm'])
        && (name !== 'wake-wasi.html' || args['wake-wasm']) && (name !== 'spell-wasi.html' || args['spell-wasm'])
        && (name !== 'image-pages-wasi.html' || args['image-page-wasm']) && (name !== 'image-wasi.html' || args['image-wasm']) && (name !== 'sketch-wasi.html' || args['sketch-wasm']))
    .filter(name => !name.startsWith('webgpu-') || args.webgpu || args.fixture)
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
    if (path === '/__rune/wake.wasm') return args['wake-wasm'];
    if (path === '/__rune/diagnostics.wasm') return args['diagnostics-wasm'];
    if (path === '/__rune/image-pages.wasm') return args['image-page-wasm'];
    if (path === '/__rune/image.wasm') return args['image-wasm'];
    if (path === '/__rune/spell.wasm') return args['spell-wasm'];
    if (path === '/__rune/www.wasm') return args['www-wasm'];
    for (const name of largeViews) if (path === '/__rune/' + name + '.wasm') return args[name + '-wasm'];
    if (path === '/__rune/sketch.wasm') return args['sketch-wasm'];
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
if (args.angle === 'swiftshader') {
    flags.push('--enable-unsafe-swiftshader');
    if (args.webgpu) flags.push('--enable-unsafe-webgpu');
}
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

async function fixture(debug, page, options) {
    const query = new URLSearchParams(options ?? {});
    if (page === 'image-pages.html' && (args.webgpu || args.fixture)) query.set('webgpu', '1');
    const targetURL = site + '/Tests/Browser/' + page + (query.size ? '?' + query : '');
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
        let clicked = false, last, lastMove;
        for (const until = Date.now() + 90_000; Date.now() < until;) {
            last = await read("document.querySelector('#result')?.textContent");
            if (last?.startsWith('PASS') || last?.startsWith('{"passed":true')) {
                if (verify) await verify(command, true);
                console.log(query.size ? page + ' (' + [...query.values()].join(', ') + ')' : page, last);
                return page === 'large-view-wasi.html' ? JSON.parse(last.slice(5)) : null;
            }
            if (/^(FAIL|Error|TypeError|RangeError|ReferenceError)/.test(last)) throw Error(last);
            if (page === 'sketch-wasi.html' && last?.startsWith('Move pointer') && last !== lastMove) {
                lastMove = last;
                const point = await read('window.runeMove');
                await command('Input.dispatchMouseEvent', { ...point, type: 'mouseMoved' });
            }
            if (page === 'window-environment.html' && last !== lastMove) {
                lastMove = last;
                if (last === 'Apply system safe area') {
                    await command('Emulation.setSafeAreaInsetsOverride', {insets:{top:31, right:11, bottom:17, left:7}});
                } else if (last === 'Zoom visual viewport') {
                    await command('Emulation.setPageScaleFactor', {pageScaleFactor:2});
                }
            }
            if (page === 'spell-wasi.html' && last?.startsWith('Open spelling menu for ') && last !== lastMove) {
                lastMove = last;
                const point = await read('window.runeSpellPoint');
                await command('Input.dispatchMouseEvent', { ...point, type: 'mouseMoved' });
                await command('Input.dispatchMouseEvent', { ...point, type: 'mousePressed', button: 'right', buttons: 2, clickCount: 1 });
                await command('Input.dispatchMouseEvent', { ...point, type: 'mouseReleased', button: 'right', clickCount: 1 });
            }
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
        const cases = page === 'large-view-wasi.html' ? largeViews.flatMap(view =>
            args['compare-accessibility'] ? [{ view, accessibility: 'full' }, { view, accessibility: 'incremental' }] : [{ view }])
            : page === 'spell-wasi.html' && args.webgpu ? [{ backend: 'cpu' }, { backend: 'webgpu' }]
            : page === 'wake-wasi.html' ? [{ backend: 'cpu' }, { backend: 'webgl2' }, ...(args.webgpu ? [{ backend: 'webgpu' }] : [])]
            : page === 'image-pages-wasi.html' ? [{ backend: 'webgl2' }, { backend: 'webgl2', legacy: '1' },
                ...(args.webgpu ? [{ backend: 'webgpu' }] : [])]
            : (page === 'hello-wasi.html' || page === 'document-wasi.html') && args.webgpu
                ? [{ backend: 'webgl2' }, { backend: 'webgpu' }] : [undefined];
        const fullSnapshots = new Map();
        for (const options of cases) {
            try {
                const measured = await fixture('http://127.0.0.1:' + port, page, options);
                if (measured?.accessibility === 'full') fullSnapshots.set(measured.view, measured);
                if (measured?.accessibility === 'incremental') {
                    const full = fullSnapshots.get(measured.view);
                    if (full?.accessibilityHash !== measured.accessibilityHash) {
                        throw Error('Final accessible tree differs between full and incremental scrolls');
                    }
                    if (full.initialPixelHash !== measured.initialPixelHash || full.finalPixelHash !== measured.finalPixelHash) {
                        throw Error('Canvas pixels differ between full and incremental scrolls');
                    }
                }
            }
            catch (error) { console.error(page, options ?? '', error.message); process.exitCode = 1; }
        }
    }
} finally {
    const stopped = browser.exitCode !== null || launchError ? Promise.resolve() : once(browser, 'exit');
    browser.kill();
    server.closeAllConnections();
    server.close();
    await stopped;
    await rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
}
