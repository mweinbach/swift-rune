// Exercises a keyed, selected, nested Tx.popupMenu through the real Swift fixture.
export async function verifyAppMenu(canvas, result, reports, until) {
    const check = (condition, message) => { if (!condition) throw Error(message); };
    const key = name => document.activeElement.dispatchEvent(
        new KeyboardEvent('keydown', {key: name, bubbles: true, cancelable: true}));
    const box = canvas.getBoundingClientRect();
    const current = '[data-rune-menu-id="current"]';
    async function open(label) {
        window.runeSpellPoint = {x: box.x + 15, y: box.y + box.height * 60 / 112};
        result.textContent = 'Open spelling menu for ' + label;
        return until(() => document.querySelector(current)?.closest('[role=menu]'), 'App menu did not open');
    }
    const menu = await open('app keyboard selection');
    check(menu.offsetWidth >= 239, 'A keyed menu must cover its 240pt anchor');
    const selected = menu.querySelector(current);
    check(selected.getAttribute('aria-checked') === 'true' && document.activeElement === selected, 'Selected entry');
    check(menu.querySelector('[aria-disabled=true]') && menu.querySelector('[role=separator]'), 'Menu structure');
    const titleY = selected.getBoundingClientRect().top;
    check(Math.abs(titleY - (box.top + box.height * 40 / 112)) < 2, 'Keyed selected item has wrong Y ' + titleY);
    key('ArrowDown'); key('ArrowRight');
    check(document.activeElement.dataset.runeMenuId === 'archive', 'Submenu skipped first item');
    key('e'); key('Enter');
    await until(() => reports.some(report => report.menuAnswer === 'export'), 'Swift callback missed Export');
    await open('app dismissal');
    key('Escape');
    await until(() => reports.some(report => report.menuAnswer === 'dismissed'), 'Swift dismissal missing');
    check(!document.querySelector('[data-rune-menu]'), 'Menu still open after Escape');
    check(reports.filter(report => report.menuAnswer).length === 2, 'Menu callback answered twice');
}
