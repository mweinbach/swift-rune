// Each reactor assigns an ID while a cursor image remains in its 32-entry LRU.
export function mountRuneCursor(canvas) {
    const previous = canvas.style.cursor;
    const entries = new Map();
    let applied;
    function release(entry) {
        if (entry?.url) URL.revokeObjectURL(entry.url);
    }
    return {
        update({ css, id, evict, png, error }) {
            if (evict !== undefined) {
                release(entries.get(evict));
                entries.delete(evict);
            }
            if (id !== undefined) {
                if (!entries.has(id)) {
                    let url;
                    if (png) {
                        const data = Uint8Array.from(atob(png), c => c.charCodeAt(0));
                        url = URL.createObjectURL(new Blob([data], {type: 'image/png'}));
                        css = css.replace('{url}', url);
                    }
                    if (error) console.warn(error);
                    entries.set(id, {css, url});
                }
                css = entries.get(id).css;
            }
            canvas.style.cursor = css;
            applied = canvas.style.cursor;
        },
        dispose() {
            if (canvas.style.cursor === applied) canvas.style.cursor = previous;
            for (const entry of entries.values()) release(entry);
            entries.clear();
        }
    };
}
