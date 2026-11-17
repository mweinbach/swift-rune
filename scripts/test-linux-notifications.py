#!/usr/bin/env python3
"""Exercise RuneNotify through a private freedesktop notification service.

Requires dbus-run-session and python3-gi. Extra arguments replace the Swift test
command, for example to select an existing build with swift test --skip-build.
"""
import os
import subprocess
import sys
from pathlib import Path

if __name__ == "__main__" and sys.argv[1:2] != ["--inside"]:
    os.execvp("dbus-run-session", ["dbus-run-session", "--", sys.executable,
              str(Path(__file__).resolve()), "--inside", *sys.argv[1:]])

from gi.repository import Gio, GLib

SERVICE = "org.freedesktop.Notifications"
OBJECT = "/org/freedesktop/Notifications"
XML = f"""<node><interface name="{SERVICE}">
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="Notify">{''.join('<arg direction="in" type="'+sig+'"/>' for sig in ('s','u','s','s','s','as','a{sv}','i'))}
<arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method></interface></node>"""


class NotificationServer:
    def __init__(self, bus):
        self.bus = bus
        self.posts = 0
        self.closed = []
        self.errors = []

    def emit(self, name, signature, values):
        self.bus.emit_signal(None, OBJECT, SERVICE, name, GLib.Variant(signature, values))
        return False

    def handle(self, connection, sender, path, interface, name, params, invocation):
        try:
            if name == "GetCapabilities":
                invocation.return_value(GLib.Variant("(as)", (["actions", "body-markup", "inline-reply"],)))
                return
            if name == "CloseNotification":
                (number,) = params.unpack()
                self.closed.append(number)
                self.emit("NotificationClosed", "(uu)", (number, 3))
                invocation.return_value(None)
                return
            app, replace, _, title, body, actions, hints, timeout = params.unpack()
            self.posts += 1
            number = 4201 if self.posts < 3 else 4202
            assert replace == (4201 if self.posts == 2 else 0), (self.posts, replace)
            assert title == ("Two" if self.posts == 2 else "One") and body == "A &lt; B"
            assert app == "Rune Fixture" and hints["desktop-entry"] == "dev.rune.notify.test"
            assert hints["suppress-sound"] and hints["urgency"] == 1 and timeout == -1
            assert hints["x-kde-reply-placeholder-text"] == "Say something"
            assert actions == ["default", "", "rune-0", "Open", "inline-reply", "Send"], actions
            invocation.return_value(GLib.Variant("(u)", (number,)))
            if self.posts == 1:
                self.emit("ActivationToken", "(us)", (number, "notification-action-token"))
            if self.posts == 2:
                GLib.idle_add(self.emit, "NotificationReplied", "(us)", (number, "你好 🦦"))
            else:
                GLib.idle_add(self.emit, "ActionInvoked", "(us)",
                              (number, "rune-0" if self.posts == 1 else "default"))
        except Exception as error:
            self.errors.append(repr(error))
            invocation.return_dbus_error("org.freedesktop.DBus.Error.Failed", repr(error))


def main():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                  "RequestName", GLib.Variant("(su)", (SERVICE, 4)), GLib.VariantType("(u)"),
                  Gio.DBusCallFlags.NONE, 1000)
    server = NotificationServer(bus)
    bus.register_object(OBJECT, Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], server.handle)
    command = sys.argv[2:] or ["swift", "test", "--filter", "LinuxNotificationIntegrationTests"]
    child = subprocess.Popen(command, env={**os.environ, "RUNE_TEST_NOTIFICATION_BUS": "1"})
    loop = GLib.MainLoop()

    def tick():
        if child.poll() is None:
            return True
        loop.quit()
        return False

    GLib.timeout_add(50, tick)
    try:
        loop.run()
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait()
    if child.returncode:
        return child.returncode
    if server.posts != 3 or server.closed != [4201, 4202] or server.errors:
        raise RuntimeError(f"unexpected notifications: {server.posts}, {server.closed}, {server.errors}")
    print("Private notification service observed all three posts and both removals.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
