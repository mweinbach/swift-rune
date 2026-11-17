import test from 'node:test';
import assert from 'node:assert/strict';
import { mountRuneClipboard } from '../../Sources/Rune/Resources/Web/rune-clipboard.mjs';

function fixture({ active = true, board = {}, field = null, route = () => false } = {}) {
    const errors = [], sent = [], native = new Map(), requests = [];
    const target = {};
    const doc = {
        addEventListener(type, handler) { native.set(type, handler); },
        hasFocus() { return true; },
        defaultView: {
            navigator: { clipboard: board, userActivation: { isActive: active } },
            DOMException,
            CustomEvent: class { constructor(type, init) { Object.assign(this, { type }, init); } }
        }
    };
    const canvas = {ownerDocument: doc, dispatchEvent(event) { errors.push(event.detail); }};
    const fields = {clipboardTarget(node) { return node === target ? field : null; }};
    const {signal} = new AbortController();
    function send(event) {
        sent.push(event);
        const result = route(event, requests);
        bridge.drain();
        return result;
    }
    const bridge = mountRuneClipboard(canvas, fields, send, () => requests.splice(0), signal);
    function fire(type, data, trusted = true) {
        const event = {
            type, target: field ? target : canvas, isTrusted: trusted, clipboardData: data,
            preventDefault() { this.defaultPrevented = true; }
        };
        native.get(type)(event);
        return event;
    }
    return {bridge, errors, sent, requests, fire};
}

test('denied or inactive reads answer once and expose the refusal without clipboard contents', async () => {
    for (const active of [true, false]) {
        let reads = 0;
        const f = fixture({active, board: { async readText() {
            reads++;
            throw new DOMException('Access denied', 'NotAllowedError');
        } }});
        f.requests.push({operation: 'read', id: '1', forms: 'text'});
        f.bridge.drain();
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(reads, active ? 1 : 0);
        assert.deepEqual(f.sent, [{kind: 'clipboardReply', key: '1', clipboard: undefined}]);
        assert.equal(f.errors[0].name, 'NotAllowedError');
    }
});

test('a rejected native cut preserves the selection and secure copy never exports it', () => {
    const f = fixture({field: 'plain', route(event, queue) {
        if (event.kind !== 'clipboardCut') return true;
        queue.push({operation:'selection', content:{text:'selected'}});
        return true;
    }});
    const rejected = f.fire('cut', {setData() { throw new Error('read-only'); }});
    assert.equal(rejected.defaultPrevented, true);
    assert.deepEqual(f.sent.map(e => e.kind), ['clipboardCut', 'clipboardCancelCut']);
    assert.equal(f.errors.length, 1);
    const writes = [];
    const copied = f.fire('cut', {setData(type, value) { writes.push([type, value]); }});
    assert.equal(copied.defaultPrevented, true);
    assert.deepEqual(writes, [['text/plain','selected']]);
    assert.equal(f.sent.at(-1).kind, 'clipboardCommitCut');
    const secure = fixture({field:'password'});
    assert.equal(secure.fire('copy', {}).defaultPrevented, true);
    assert.equal(secure.fire('cut', {}).defaultPrevented, true);
    assert.deepEqual(secure.sent, []);
});

test('only a trusted paste supplies data and password editors request plain text', () => {
    const f = fixture({field: 'password', route() { return true; }});
    const types = [];
    const data = {getData(mime) { types.push(mime); return 'input'; }, files: []};
    f.fire('paste', data, false);
    assert.deepEqual(types, []);
    const event = f.fire('paste', data);
    assert.deepEqual(types, ['text/plain']);
    assert.equal(event.defaultPrevented, true);
    assert.equal(f.sent[0].clipboard.text, 'input');
});

test('a read requested after a write observes the completed system write', async () => {
    let complete, contents = 'previous';
    const f = fixture({board: {
        async writeText(text) {
            await new Promise(resolve => { complete = resolve; });
            contents = text;
        },
        async readText() { return contents; }
    }});
    f.requests.push({operation:'write', content:{text:'new'}}, {operation:'read', id:'2', forms:'text'});
    f.bridge.drain();
    assert.deepEqual(f.sent, []);
    complete();
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(f.sent, [{kind:'clipboardReply', key:'2', clipboard:{text:'new'}}]);
});
