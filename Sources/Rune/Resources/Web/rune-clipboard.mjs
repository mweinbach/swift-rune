// Native clipboard events grant synchronous access for that action. A Rune button's
// Tx clipboard request uses the Async Clipboard API during the originating user gesture.
const textForms = [['text/plain', 'text'], ['text/html', 'html'], ['text/rtf', 'rtf']];

function base64(bytes) {
    const chunks = [];
    for (let i = 0; i < bytes.length; i += 16384)
        chunks.push(String.fromCharCode(...bytes.subarray(i, i + 16384)));
    return btoa(chunks.join(''));
}

async function readClipboard(board, forms) {
    if (forms === 'text' || !board.read) return { text: await board.readText() };
    const items = await board.read();
    const content = { text: '' };
    for (const item of items) {
        for (const [mime, key] of textForms) {
            if ((!content[key]) && item.types.includes(mime)) content[key] = await (await item.getType(mime)).text();
        }
        if (forms === 'all' && !content.png && item.types.includes('image/png')) {
            const png = await item.getType('image/png');
            if (png.size <= 32 * 1024 * 1024) content.png = base64(new Uint8Array(await png.arrayBuffer()));
        }
    }
    return content;
}

function writeClipboard(win, board, content) {
    if (!content.html && !content.rtf && !content.png) return board.writeText(content.text);
    if (!board.write || !win.ClipboardItem) throw new Error('This browser cannot write rich clipboard data');
    const formats = {};
    for (const [mime, key] of textForms) {
        if (content[key] && (!win.ClipboardItem.supports || win.ClipboardItem.supports(mime)))
            formats[mime] = new Blob([content[key]], { type: mime });
    }
    if (content.png) {
        const bytes = Uint8Array.from(atob(content.png), c => c.charCodeAt(0));
        formats['image/png'] = new Blob([bytes], { type: 'image/png' });
    }
    if (!Object.keys(formats).length) throw new Error('This browser cannot write the requested clipboard format');
    return board.write([new win.ClipboardItem(formats)]);
}

export function mountRuneClipboard(canvas, fields, send, take, signal) {
    const doc = canvas.ownerDocument;
    const win = doc.defaultView;
    let writingEvent = null;
    let readingEvent = null;
    let pending = null;

    function report(operation, error) {
        if (!signal.aborted) canvas.dispatchEvent(new win.CustomEvent('runeclipboarderror', {
            bubbles: true, detail: { operation, name: error.name, message: error.message }
        }));
    }

    async function perform(request) {
        const { operation, content, id } = request;
        let reply;
        try {
            if (signal.aborted) return;
            if (operation === 'concealed') throw new Error('Browsers cannot own and expire a concealed clipboard item');
            if (operation === 'unsupported') throw new Error('No supported browser clipboard representation was supplied');
            if (operation === 'selection') {
                if (!writingEvent) return;
                for (const [mime, key] of textForms)
                    if (content[key] != null) writingEvent.data.setData(mime, content[key]);
                writingEvent.written = true;
                return;
            }
            if (operation === 'eventRead') {
                const event = readingEvent;
                if (!event) return;
                reply = event.content;
                const bytes = await event.png.arrayBuffer();
                reply.png = base64(new Uint8Array(bytes));
                return;
            }
            // Check activation before even requesting permission. A timer cannot prompt for a read.
            if (!win.navigator.userActivation?.isActive || !doc.hasFocus())
                throw new win.DOMException('This clipboard request requires a user gesture', 'NotAllowedError');
            const board = win.navigator.clipboard;
            if (!board) throw new Error('The browser clipboard requires a secure context');
            if (operation === 'read') reply = await readClipboard(board, request.forms);
            else if (operation === 'write') await writeClipboard(win, board, content);
        } catch (error) {
            report(operation, error);
        } finally {
            if ((operation === 'read' || operation === 'eventRead') && !signal.aborted)
                send({ kind: 'clipboardReply', key: id, clipboard: reply });
        }
    }

    function drain() {
        const requests = take();
        if (!requests) return;
        for (const request of requests) {
            // Event DataTransfer access expires when its listener returns. Navigator writes
            // and reads instead run in transaction order so a read can see the preceding write.
            if (request.operation !== 'read' && request.operation !== 'write') {
                void perform(request);
                continue;
            }
            const result = pending ? pending.then(() => perform(request)) : perform(request);
            pending = result;
            void result.finally(() => { if (pending === result) pending = null; });
        }
    }

    function native(event) {
        if (!event.isTrusted || event.defaultPrevented) return;
        const field = fields.clipboardTarget(event.target);
        if (event.target !== canvas && !field) return;
        if (field === 'password' && event.type !== 'paste') {
            event.preventDefault();
            return;
        }
        const data = event.clipboardData;
        if (!data) return;
        if (event.type === 'paste') {
            const content = {
                text: data.getData('text/plain'),
                html: field !== 'password' && data.getData('text/html') || undefined,
                rtf: field !== 'password' && data.getData('text/rtf') || undefined
            };
            const png = field !== 'password' && [...data.files].find(f => f.type === 'image/png' && f.size <= 32 * 1024 * 1024);
            if (png) {
                readingEvent = { png, content };
                try {
                    if (send({ kind: 'clipboardPrepareImagePaste' })) {
                        event.preventDefault();
                        return;
                    }
                } finally { readingEvent = null; }
            }
            if (send({ kind: 'clipboardPaste', clipboard: content })) event.preventDefault();
            return;
        }
        const cut = event.type === 'cut';
        const write = { data, written: false };
        writingEvent = write;
        try {
            if (!send({ kind: cut ? 'clipboardCut' : 'clipboardCopy' })) return;
            // Keep the native editor from deleting the selection if the clipboard write failed.
            event.preventDefault();
            if (cut) send({ kind: write.written ? 'clipboardCommitCut' : 'clipboardCancelCut' });
        } finally {
            writingEvent = null;
        }
    }
    for (const type of ['copy', 'cut', 'paste']) doc.addEventListener(type, native, { signal });
    return { drain };
}
