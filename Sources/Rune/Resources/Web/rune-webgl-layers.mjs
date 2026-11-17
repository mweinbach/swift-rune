// Layer bounds use Rune's top-left device pixels. A turned group is rasterized
// before its rotation, so its target may lie entirely outside the viewport.
const noClip = [-1e6, -1e6, 1e6, 1e6];
const f = Math.fround;

function intersectsArea(b) {
    return b[2] > b[0] && b[3] > b[1];
}

function intersection(a, b) {
    return [Math.max(a[0], b[0]), Math.max(a[1], b[1]), Math.min(a[2], b[2]), Math.min(a[3], b[3])];
}

function expanded(b, amount) {
    return [f(b[0] - amount), f(b[1] - amount), f(b[2] + amount), f(b[3] + amount)];
}

function snapped(b) {
    return [Math.floor(b[0]), Math.floor(b[1]), Math.ceil(b[2]), Math.ceil(b[3])];
}

function include(edges, left, top, right, bottom) {
    if (right <= left || bottom <= top) return;
    if (intersectsArea(edges)) {
        edges[0] = Math.min(edges[0], left);
        edges[1] = Math.min(edges[1], top);
        edges[2] = Math.max(edges[2], right);
        edges[3] = Math.max(edges[3], bottom);
    } else {
        edges[0] = left;
        edges[1] = top;
        edges[2] = right;
        edges[3] = bottom;
    }
}

function turned(b, angle, pivotX, pivotY) {
    if (!angle || !intersectsArea(b)) return b;
    const c = f(Math.cos(angle)), s = f(Math.sin(angle));
    const out = [Infinity, Infinity, -Infinity, -Infinity];
    for (let i = 0; i < 4; ++i) {
        const dx = f(b[(i & 1) * 2] - pivotX), dy = f(b[(i & 2) + 1] - pivotY);
        const x = f(f(pivotX + f(c * dx)) - f(s * dy));
        const y = f(f(pivotY + f(s * dx)) + f(c * dy));
        out[0] = Math.min(out[0], x);
        out[1] = Math.min(out[1], y);
        out[2] = Math.max(out[2], x);
        out[3] = Math.max(out[3], y);
    }
    return out;
}

function beginScope(p, base, index, parent, viewport) {
    const x = p[base], y = p[base + 1];
    const clip = p.subarray(base + 24, base + 28);
    const sigma = Math.min(64, p[base + 18]);
    const grow = sigma >= 0.05 ? Math.ceil(f(3 * sigma)) : 0;
    const angle = p[base + 13], pivotX = p[base + 14], pivotY = p[base + 15];
    const free = angle !== 0 || !!parent?.free;
    let frame;
    if (free) {
        const outer = parent?.free ? parent.frame : expanded(viewport, parent?.support ?? 0);
        frame = turned(intersection(outer, clip), -angle, pivotX, pivotY);
    }
    const limit = parent && !parent.free ? expanded(intersection(parent.clip, parent.limit), parent.grow) : noClip;
    return {
        index, parent, clip, grow, angle, pivotX, pivotY, free, frame, limit,
        support: (parent?.support ?? 0) + grow,
        cached: p[base + 19] >= 0.5,
        hidden: p[base + 11] <= 0,
        edges: [x, y, f(x + p[base + 2]), f(y + p[base + 3])],
    };
}

function includeInstance(scope, p, base, kind) {
    let x = p[base], y = p[base + 1], w = p[base + 2], h = p[base + 3];
    const soft = p[base + 18];
    let grow = 1;
    if (kind === 2) {
        const angle = p[base + 16];
        if (angle !== 0) {
            const c = Math.abs(f(Math.cos(angle))), s = Math.abs(f(Math.sin(angle)));
            const width = f(f(c * w) + f(s * h)), height = f(f(s * w) + f(c * h));
            x = f(x + f(f(w - width) * 0.5));
            y = f(y + f(f(h - height) * 0.5));
            w = width;
            h = height;
        }
        grow = 0;
    } else if (kind === 1) {
        grow = f(f(3 * soft) + 1);
    } else if (kind === 12) {
        grow = f(soft + 1);
    } else if (kind === 0 || kind === 4 || kind === 10 || kind === 11) {
        grow = f(1 + f(2 * soft));
    }
    include(scope.edges, Math.max(f(x - grow), p[base + 24]), Math.max(f(y - grow), p[base + 25]),
        Math.min(f(f(x + w) + grow), p[base + 26]), Math.min(f(f(y + h) + grow), p[base + 27]));
}

export function primitiveBounds(instances, index) {
    const scope = {edges: [0, 0, 0, 0]};
    includeInstance(scope, instances, index * 32, instances[index * 32 + 17]);
    return scope.edges;
}

function finishScope(scope, viewport) {
    const clip = scope.free ? scope.frame : intersection(scope.clip, scope.limit);
    let visible = expanded(intersection(scope.edges, clip), scope.grow);
    if (!scope.free) visible = intersection(visible, expanded(viewport, scope.support));
    scope.visible = snapped(visible);
    scope.edges = scope.cached ? snapped(scope.edges) : scope.visible;
    if (scope.parent && !scope.parent.cached) {
        include(scope.parent.edges, ...turned(scope.edges, scope.angle, scope.pivotX, scope.pivotY));
    }
}

// The returned rect is [left, top, width, height] in the group's working space.
export function planLayerRects(instances, width, height, surfaces = []) {
    const viewport = [0, 0, width, height];
    const scopes = [], stack = [];
    let surface = 0;
    for (let base = 0, i = 0; base < instances.length; base += 32, ++i) {
        const parent = stack.at(-1);
        while (surface < surfaces.length && surfaces[surface].before <= i) {
            const u = surfaces[surface++].uniforms;
            if (parent && !parent.cached) {
                include(parent.edges, Math.max(u[4], u[16]), Math.max(u[5], u[17]),
                    Math.min(f(u[4] + u[6]), u[18]), Math.min(f(u[5] + u[7]), u[19]));
            }
        }
        const kind = Math.round(instances[base + 17]);
        if (kind === 8) {
            const scope = beginScope(instances, base, i, parent, viewport);
            scopes.push(scope);
            stack.push(scope);
        } else if (kind === 9) {
            if (!parent) throw new Error('Unexpected Rune GL layer end');
            finishScope(stack.pop(), viewport);
        } else if (parent && !parent.cached) {
            includeInstance(parent, instances, base, kind);
        }
    }
    if (stack.length) throw new Error('Unclosed Rune GL layer');

    let cacheBytes = 0;
    const rects = new Map();
    for (const scope of scopes) {
        scope.hidden ||= !!scope.parent?.hidden || !intersectsArea(scope.visible) || !intersectsArea(scope.edges);
        if (scope.hidden) {
            rects.set(scope.index, [0, 0, 0, 0]);
            continue;
        }
        let bounds = scope.edges;
        if (scope.cached) {
            // Metal reserves cache space in 64-pixel buckets of RGBA16F.
            const w = Math.ceil((bounds[2] - bounds[0]) / 64) * 64;
            const h = Math.ceil((bounds[3] - bounds[1]) / 64) * 64;
            const bytes = w * h * 8;
            if (w <= 4096 && h <= 4096 && cacheBytes + bytes <= 64 * 1024 * 1024) {
                cacheBytes += bytes;
            } else {
                bounds = scope.visible;
            }
        }
        rects.set(scope.index, [bounds[0], bounds[1], bounds[2] - bounds[0], bounds[3] - bounds[1]]);
    }
    return rects;
}
