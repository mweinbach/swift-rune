const width = 137, height = 95;
const viewport = [0, 0, width, height];
const bounds = [29, 14, 49, 43];
const sigmas = [0.25, 2.5, 9.5, 26];
const clear = [0.02, 0.04, 0.06, 1];

function instance(rect, color, params) {
    const lanes = new Float32Array(32);
    lanes.set(rect);
    lanes.set(color, 8);
    lanes.set(params, 16);
    lanes.set(viewport, 24);
    return lanes;
}

function scene(backdrop, sigma) {
    const solid = (rect, color) => instance(rect, color, [0, 0, 0, 0]);
    const orange = [0.75, 0.25, 0.05, 1];
    if (backdrop) {
        const instances = [];
        for (let x = 0; x < width; x += 8) instances.push(solid([x, 0, 4, height], orange));
        instances.push(solid([19, 35, 95, 9], [0.01, 0.55, 1, 1]));
        instances.push(instance(bounds, [0, 0, 0, 1], [sigma, 13, 0, 0]));
        return instances;
    }
    return [
        instance(bounds, [0, 0, 0, 0.83], [0, 8, sigma, 0]),
        solid(bounds, orange),
        solid([42, 39, 18, 12], [0.02, 0.6, 0.8, 1]),
        instance([0, 0, 0, 0], [0, 0, 0, 0], [0, 9, 0, 0])
    ];
}

function nestedScene(angle) {
    const parent = instance([-19, 14, 75, 55], [0, 0, 0, 0.83], [0, 8, 3.2, 0]);
    parent.set([0, angle, 29, 25], 12);
    const items = [parent];
    for (let x = -19; x < 59; x += 8) {
        items.push(instance([x, 14, 3, 50], [0.7, 0.2, 0.1, 1], [0, 0, 0, 0]));
    }
    items.push(instance([18, 26, 25, 35], [0, 0, 0, 0.7], [0, 8, 3.5, 0]),
               instance([9, 22, 42, 28], [0.02, 0.6, 0.8, 1], [0, 0, 0, 0]),
               instance([0, 0, 0, 0], [], [0, 9, 0, 0]),
               instance([5, 28, 25, 25], [0, 0, 0, 0.9], [9.5, 13, 0, 0]),
               instance([0, 0, 0, 0], [], [0, 9, 0, 0]));
    for (const item of items) item.set([-1000, -1000, width, height], 24);
    return items;
}

function draw(driver, instances) {
    const byteCount = 56 + 128 * instances.length + 5;
    const memory = new ArrayBuffer(byteCount);
    new Uint32Array(memory, 0, 14).set([0x32475352, width, height, 7, instances.length, 1, 1, 1, 1]);
    new Float32Array(memory, 36, 4).set(clear);
    const body = new Float32Array(memory, 56, 32 * instances.length);
    instances.forEach((item, index) => body.set(item, 32 * index));
    driver.draw(memory, 0, byteCount);
}

// RGB samples from MetalRenderer.renderOffscreen on the same RenderFrame. The
// probes include a Gaussian halo outside the layer, sharp detail, stripes,
// and a color transition in the backdrop at fractional and reduced scales.
const cases = [
    {
        backdrop: false,
        probes: [[24,23], [29,30], [44,43], [77,26]],
        rgb: [[5,10,15,159,55,13,5,129,172,159,55,13],
              [10,12,15,95,36,14,34,115,142,95,36,14],
              [46,22,15,79,33,17,100,68,54,77,31,15],
              [36,22,18,43,25,19,53,30,22,43,24,18]]
    }, {
        backdrop: true,
        probes: [[28,28], [29,20], [43,36], [71,39]],
        rgb: [[5,10,15,51,23,14,23,123,213,3,140,255],
              [5,10,15,61,26,14,27,118,201,10,133,238],
              [5,10,15,93,42,26,65,72,97,64,74,101],
              [5,10,15,94,46,33,86,51,47,84,52,50]]
    }
];

export { width, height, scene, nestedScene, sigmas, cases, draw };
