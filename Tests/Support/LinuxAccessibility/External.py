#!/usr/bin/env python3
"""From this directory, build the public fixture and drive it on an isolated desktop.

    swift build
    dbus-run-session -- xvfb-run -a /usr/bin/python3 External.py .build/debug/rune-sparse-atk-probe
"""
import importlib
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
probe = importlib.import_module("test-linux-accessibility")
Atspi = probe.Atspi


def check(binary):
    with probe.launched(binary) as root:
        def named(name):
            return next((node for node in probe.descendants(root) if node.get_name() == name), None)

        def children(node):
            node.clear_cache()
            return [node.get_child_at_index(i) for i in range(node.get_child_count())]

        def press(name):
            button = probe.wait_for(lambda: named(name))
            actions = [button.get_localized_name(i) for i in range(button.get_n_actions())]
            assert button.do_action(actions.index("press")), name

        def box(node):
            r = node.get_extents(Atspi.CoordType.WINDOW)
            return (r.x, r.y, r.width, r.height)

        def defunct(node):
            return node.get_state_set().contains(Atspi.StateType.DEFUNCT)

        items = probe.wait_for(lambda: named("Items"))
        c, a, b = children(items)
        assert [node.get_name() for node in (c, a, b)] == ["C", "A", "B"]
        held = probe.wait_for(lambda: named("Scroll item"))
        edge = probe.wait_for(lambda: named("Edge item"))
        assert edge.get_state_set().contains(Atspi.StateType.SHOWING)
        role_box = probe.wait_for(lambda: named("Role box"))
        leaf = probe.wait_for(lambda: named("Retained child"))
        assert role_box.get_role() == Atspi.Role.GROUPING and leaf.get_parent() == role_box
        old_box = box(held)
        events = []

        def record(event, _):
            events.append((event.type, event.source, event.detail1, event.any_data))

        listener = Atspi.EventListener.new(record, None)
        types = ("object:property-change:accessible-name", "object:children-changed", "object:bounds-changed",
                 "object:state-changed:defunct", "object:state-changed:showing")
        for typ in types:
            assert listener.register(typ)

        def observed(kind, source, child=None):
            return any(typ.startswith(kind) and obj == source and (child is None or payload == child)
                       for typ, obj, _, payload in events)

        try:
            press("Rename")
            probe.wait_for(lambda: a.get_name() == "A edited")
            probe.wait_for(lambda: observed(types[0], a))
            assert children(items) == [c, a, b]
            print("Rename changed the held A object's name in place and emitted accessible-name.", flush=True)

            events.clear()
            press("Reorder")
            probe.wait_for(lambda: children(items) == [b, c, a])
            probe.wait_for(lambda: observed("object:children-changed:remove", items, b)
                           and observed("object:children-changed:add", items, b))
            assert b.get_index_in_parent() == 0 and a.get_index_in_parent() == 2
            print("Reorder moved the same three objects to B,C,A edited and emitted child removal/addition.", flush=True)

            events.clear()
            press("Remove")
            probe.wait_for(lambda: children(items) == [c, a])
            probe.wait_for(lambda: observed("object:children-changed:remove", items, b))
            probe.wait_for(lambda: defunct(b))
            print("The removed B handle became defunct. C and A edited retained their identities.", flush=True)

            events.clear()
            press("Scroll")
            expected = (old_box[0], old_box[1] - 30, old_box[2], old_box[3])
            probe.wait_for(lambda: box(held) == expected)
            probe.wait_for(lambda: observed("object:bounds-changed", held))
            assert named("Scroll item") == held and held.get_state_set().contains(Atspi.StateType.SHOWING)
            probe.wait_for(lambda: any(typ.startswith("object:state-changed:showing") and obj == edge and detail == 0
                                       for typ, obj, detail, _ in events))
            assert not edge.get_state_set().contains(Atspi.StateType.SHOWING) and not defunct(edge)
            print(f"Scroll moved the same showing object from {old_box} to {expected} and emitted bounds-changed.", flush=True)
            print("The clipped edge object lost SHOWING, emitted its state change and remained live.", flush=True)

            events.clear()
            press("Retype")
            new_box = probe.wait_for(lambda: next((n for n in probe.descendants(root)
                if n.get_name() == "Role box" and n.get_role() == Atspi.Role.HEADING), None))
            assert new_box != role_box
            probe.wait_for(lambda: defunct(role_box))
            probe.wait_for(lambda: children(new_box) == [leaf] and leaf.get_parent() == new_box)
            probe.wait_for(lambda: observed("object:children-changed:add", new_box, leaf))
            print("Role change retired the old group and reparented the held child to the new heading.", flush=True)
        finally:
            for typ in types:
                listener.deregister(typ)


if __name__ == "__main__":
    check(sys.argv[1])
