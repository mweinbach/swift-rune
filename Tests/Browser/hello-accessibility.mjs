import { setTimeout as delay } from 'node:timers/promises';

async function readSwitch(command, checked, focused = false) {
    const expectedLabel = checked ? 'Lights on' : 'Lights off';
    const deadline = Date.now() + 3000;
    let observed;
    do {
        const { nodes } = await command('Accessibility.getFullAXTree');
        const visible = nodes.filter(node => !node.ignored);
        const switches = visible.filter(node => node.role?.value === 'switch' && node.name?.value === 'Lights');
        const props = Object.fromEntries((switches[0]?.properties ?? []).map(p => [p.name, p.value.value]));
        const label = visible.some(node => node.role?.value === 'StaticText' && node.name?.value === expectedLabel);
        observed = { count: switches.length, checked: props.checked, focused: props.focused, label };
        if (switches.length === 1 && String(props.checked) === String(checked) && label && (!focused || props.focused)) {
            return switches[0].backendDOMNodeId;
        }
        await delay(40);
    } while (Date.now() < deadline);
    throw Error('Unexpected Lights accessibility state. Expected ' + expectedLabel + ', observed ' + JSON.stringify(observed));
}

export async function verifyHelloAccessibility(command, checked) {
    await command('Accessibility.enable');
    const id = await readSwitch(command, checked);
    await command('DOM.focus', { backendNodeId: id });
    await readSwitch(command, checked, true);
    if (!checked) return;
    // After the presentation fixture checks pointer activation and resize, use real keyboard
    // input to turn the same mounted switch off and back on through the accessible DOM.
    for (const next of [false, true]) {
        for (const type of ['keyDown', 'keyUp']) {
            await command('Input.dispatchKeyEvent', { type, key: ' ', code: 'Space', windowsVirtualKeyCode: 32 });
        }
        if (await readSwitch(command, next, true) !== id) throw Error('The accessible switch lost its identity on repaint');
    }
}
