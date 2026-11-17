#!/usr/bin/python3
"""Run the public Swift tray against an independent StatusNotifierWatcher on private D-Bus sessions.

Requires GIO Python bindings, dbus-run-session, Xvfb and Weston. Pass --app to reuse a
compiled Probe.swift. Without --app a temporary SwiftPM client depends on this checkout.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time

from gi.repository import Gio, GLib


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
DBUS = "org.freedesktop.DBus"
WATCHER = "org.kde.StatusNotifierWatcher"
ITEM = "org.kde.StatusNotifierItem"
MENU = "com.canonical.dbusmenu"
WATCHER_PATH = "/StatusNotifierWatcher"
ITEM_PATH = "/StatusNotifierItem"
MENU_PATH = "/MenuBar"
PROPERTIES = "org.freedesktop.DBus.Properties"
WATCHER_INFO = Gio.DBusNodeInfo.new_for_xml(f"""<node><interface name="{WATCHER}">
    <method name="RegisterStatusNotifierItem"><arg name="service" type="s" direction="in"/></method>
    </interface></node>""")


def call(bus, dest, path, interface, method, sig=None, args=(), out=None):
    result = bus.call_sync(dest, path, interface, method, GLib.Variant(sig, args) if sig else None,
                           GLib.VariantType.new(out) if out else None, Gio.DBusCallFlags.NONE, 3000, None)
    return result.unpack()


def connect():
    flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
    return Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SESSION_BUS_ADDRESS"], flags, None, None)


class Watcher:
    def __init__(self):
        self.bus = connect()
        self.registrations = queue.Queue()
        self.object = self.bus.register_object(WATCHER_PATH, WATCHER_INFO.interfaces[0], self.method, None, None)
        assert call(self.bus, DBUS, "/org/freedesktop/DBus", DBUS,
                    "RequestName", "(su)", (WATCHER, 4), "(u)") == (1,)

    def method(self, _bus, sender, _path, _interface, method, args, invocation):
        service, = args.unpack()
        self.registrations.put((sender, service))
        invocation.return_value(GLib.Variant("()", ()))

    def registered(self, previous=None):
        end = time.monotonic() + 8
        while True:
            sender, service = self.registrations.get(timeout=max(0.01, end - time.monotonic()))
            assert sender == service and sender.startswith(":"), (sender, service)
            if service != previous:
                return service

    def close(self):
        self.bus.unregister_object(self.object)
        self.bus.close_sync(None)


class App:
    def __init__(self, executable):
        self.process = subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.lines = queue.Queue()

        def read():
            for line in self.process.stdout:
                self.lines.put(line.rstrip("\n"))
            self.lines.put("<EOF>")

        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def expect(self, text):
        value = self.lines.get(timeout=8)
        assert value == text, (value, text)

    def command(self, line, reply):
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()
        self.expect(reply)

    def close(self):
        self.process.stdin.close()
        try:
            assert self.process.wait(timeout=5) == 0
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.reader.join()


def until(test, what):
    end = time.monotonic() + 5
    while not test():
        if time.monotonic() > end:
            raise TimeoutError(what)
        time.sleep(0.01)


def check_item(bus, dest):
    values, = call(bus, dest, ITEM_PATH, PROPERTIES, "GetAll", "(s)", (ITEM,), "(a{sv})")
    assert values["Id"] == "org.rune.TrayProbe" and values["Title"] == "Rune tray probe"
    assert values["Category"] == "ApplicationStatus" and values["Status"] == "Active"
    assert values["ItemIsMenu"] is False and values["WindowId"] == 0 and values["Menu"] == MENU_PATH
    assert values["IconName"] == "rune-test-symbolic"
    (width, height, pixels), = values["IconPixmap"]
    assert (width, height, bytes(pixels)) == (2, 1, bytes([4, 1, 2, 3, 255, 16, 32, 48]))
    assert values["ToolTip"] == ("", [], "First tooltip", "")
    props, = call(bus, dest, MENU_PATH, PROPERTIES, "GetAll", "(s)", (MENU,), "(a{sv})")
    assert props == {"Version": 3, "TextDirection": "ltr", "Status": "normal", "IconThemePath": []}


def exercise(executable, late):
    loop = GLib.MainLoop()
    dispatcher = threading.Thread(target=loop.run)
    dispatcher.start()
    client = connect()
    watcher = app = None
    subscriptions = []
    try:
        if not late:
            watcher = Watcher()
        app = App(executable)
        app.expect("VISIBLE")
        if late:
            watcher = Watcher()
        dest = watcher.registered()
        check_item(client, dest)
        watcher.close()
        watcher = Watcher()
        assert watcher.registered() == dest

        def menu(method, sig=None, args=(), out=None):
            return call(client, dest, MENU_PATH, MENU, method, sig, args, out)

        def item(method, sig=None, args=()):
            return call(client, dest, ITEM_PATH, ITEM, method, sig, args, "()")

        def alive():
            return call(client, DBUS, "/org/freedesktop/DBus", DBUS,
                        "NameHasOwner", "(s)", (dest,), "(b)") == (True,)

        revision, root = menu("GetLayout", "(iias)", (0, -1, []), "(u(ia{sv}av))")
        children = [(1, {"label": "Open"}, []), (2, {"type": "separator"}, []),
                    (3, {"label": "Disabled", "enabled": False}, [])]
        assert revision == 1 and root == (0, {"children-display": "submenu"}, children), (revision, root)
        assert menu("GetLayout", "(iias)", (3, 0, [])) == (revision, children[2])
        assert menu("GetGroupProperties", "(aias)", ([], [])) == ([(key, props) for key, props, _ in children],)
        assert menu("GetProperty", "(is)", (1, "label")) == ("Open",)
        try:
            menu("GetProperty", "(is)", (1, "absent"))
            raise AssertionError("unknown property succeeded")
        except GLib.Error as error:
            assert Gio.DBusError.get_remote_error(error) == "org.freedesktop.DBus.Error.InvalidArgs", error
        assert menu("AboutToShow", "(i)", (0,)) == (False,)
        assert menu("AboutToShowGroup", "(ai)", ([0, 3],)) == ([], [])
        zero = GLib.Variant("i", 0)
        for index, event in [(1, "hovered"), (0, "clicked"), (2, "clicked"), (3, "clicked"), (100, "clicked")]:
            menu("Event", "(isvu)", (index, event, zero, 0))
        assert menu("EventGroup", "(a(isvu))", ([(1, "clicked", zero, 1), (3, "clicked", zero, 2)],)) == ([],)
        app.expect("MENU open")
        item("SecondaryActivate", "(ii)", (0, 0))
        item("ContextMenu", "(ii)", (0, 0))
        item("Scroll", "(is)", (2, "vertical"))
        item("ProvideXdgActivationToken", "(s)", ("once-token",))
        item("Activate", "(ii)", (2, 3))
        app.expect("ACTIVATE once-token")
        item("Activate", "(ii)", (2, 3))
        app.expect("ACTIVATE <nil>")

        signals = queue.Queue()

        def receive(_bus, _sender, _path, _iface, signal, params):
            signals.put((signal, params.unpack()))

        for iface, name, path in [(ITEM, "NewToolTip", ITEM_PATH), (MENU, "LayoutUpdated", MENU_PATH),
                                  (ITEM, "NewIcon", ITEM_PATH)]:
            subscriptions.append(client.signal_subscribe(dest, iface, name, path, None,
                                                          Gio.DBusSignalFlags.NONE, receive))
        # A round trip orders GIO's asynchronous AddMatch requests before signals from the app.
        call(client, DBUS, "/org/freedesktop/DBus", DBUS, "GetId", out="(s)")

        def read_item(property_name):
            value, = call(client, dest, ITEM_PATH, PROPERTIES, "Get", "(ss)", (ITEM, property_name), "(v)")
            return value

        original_pixels = read_item("IconPixmap")
        app.command("tooltip", "TOOLTIP UPDATED")
        assert signals.get(timeout=5) == ("NewToolTip", ())
        assert read_item("ToolTip") == ("", [], "Updated tooltip", "")
        assert read_item("IconPixmap") == original_pixels
        assert menu("GetLayout", "(iias)", (0, -1, [])) == (revision, root)

        app.command("menu", "MENU UPDATED")
        assert signals.get(timeout=5) == ("LayoutUpdated", (revision + 1, 0))
        updated_layout = (revision + 1, (0, {"children-display": "submenu"},
                          [(1, {"label": "Hide from callback"}, []), (2, {"label": "Next"}, []),
                           (3, {"label": "Order"}, [])]))
        assert menu("GetLayout", "(iias)", (0, -1, [])) == updated_layout
        assert read_item("IconPixmap") == original_pixels

        app.command("replace-icon", "ICON UPDATED")
        assert signals.get(timeout=5) == ("NewIcon", ())
        assert read_item("IconPixmap") == [(1, 1, [100, 6, 10, 80])]
        app.command("clear-icon", "ICON UPDATED")
        assert signals.get(timeout=5) == ("NewIcon", ())
        assert read_item("IconPixmap") == [] and read_item("IconName") == "rune-test-symbolic"
        assert menu("GetLayout", "(iias)", (0, -1, [])) == updated_layout

        # Hold the tray worker in a callback while a separate app thread submits an update.
        # When the callback submits its own, the application's last write must win on D-Bus.
        with ThreadPoolExecutor(max_workers=1) as executor:
            event = executor.submit(menu, "Event", "(isvu)", (3, "clicked", zero, 3))
            app.expect("MENU order")
            app.command("queue-tooltip", "QUEUED")
            app.expect("CALLBACK UPDATED")
            event.result(timeout=5)
        assert signals.get(timeout=5) == ("NewToolTip", ())
        assert signals.get(timeout=5) == ("NewToolTip", ())
        assert read_item("ToolTip") == ("", [], "Callback last", "")
        menu("Event", "(isvu)", (2, "clicked", zero, 3))
        app.expect("MENU next")
        # The handler can close the connection before the method reply reaches this peer.
        try:
            menu("Event", "(isvu)", (1, "clicked", zero, 4))
        except GLib.Error as error:
            assert Gio.DBusError.get_remote_error(error) == "org.freedesktop.DBus.Error.NoReply", error
        app.expect("MENU hide")
        app.expect("HIDDEN FROM CALLBACK")
        until(lambda: not alive(), "callback did not release the SNI connection")
        app.command("ping", "PONG")
        app.command("show", "VISIBLE")
        dest = watcher.registered(previous=dest)
        app.command("remove", "REMOVED")
        until(lambda: not alive(), "removeNative did not release the SNI connection")
        app.command("show", "VISIBLE")
        dest = watcher.registered(previous=dest)
        app.command("drop", "DROPPED")
        until(lambda: not alive(), "releasing a visible SystemTray did not release its connection")
        app.command("ping", "PONG")
        print(f"{os.environ['XDG_SESSION_TYPE']}: passed SNI registration, watcher replacement, "
              "retained, replaced and cleared ARGB pixmaps, isolated menu/tooltip signals, FIFO callback updates, "
              "dbusmenu actions, one-shot activation token and teardown", flush=True)
    finally:
        if watcher:
            watcher.close()
        for sub in subscriptions:
            client.signal_unsubscribe(sub)
        client.close_sync(None)
        loop.quit()
        dispatcher.join()
        if app:
            app.close()


def build(directory, scratch):
    import json
    import shutil
    package = directory / "client"
    sources = package / "Sources" / "TrayProbe"
    sources.mkdir(parents=True)
    shutil.copyfile(HERE / "Probe.swift", sources / "main.swift")
    (package / "Package.swift").write_text(f"""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TrayProbe", dependencies: [.package(name: "RunePackage", path: {json.dumps(str(ROOT))})],
    targets: [.executableTarget(name: "TrayProbe", dependencies: [.product(name: "Rune", package: "RunePackage")])])
""")
    cmd = ["swift", "build", "--package-path", str(package)]
    if scratch:
        cmd += ["--scratch-path", str(scratch.resolve())]
    subprocess.run(cmd + ["--product", "TrayProbe", "-j", "2"], check=True)
    binary_path = subprocess.check_output(cmd + ["--show-bin-path"], text=True).strip()
    return Path(binary_path) / "TrayProbe"


def run(app, scratch):
    with tempfile.TemporaryDirectory(prefix="rune-tray-") as tmp:
        directory = Path(tmp)
        executable = str(app.resolve() if app else build(directory, scratch))
        # A socket which never authenticates must time out without leaving a worker or marking the tray visible.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stalled:
            address = str(directory / "stalled")
            stalled.bind(address)
            stalled.listen()
            started = time.monotonic()
            output = subprocess.check_output([executable, "--expect-open-failure"], text=True, timeout=12,
                                             env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS="unix:path=" + address))
            assert output.strip() == "OPEN FAILED"
            print(f"Stalled D-Bus authentication timed out after {time.monotonic() - started:.2f}s", flush=True)
        config = directory / "session.conf"
        config.write_text(f"""<busconfig><type>session</type><listen>unix:tmpdir={tmp}</listen>
            <policy context="default"><allow own="*"/><allow send_destination="*"/>
            <allow receive_sender="*"/></policy></busconfig>""")
        bus = ["dbus-run-session", "--config-file", str(config), "--", sys.executable,
               str(HERE / "test.py"), "--app", executable, "--private-session"]
        env = dict(os.environ, XDG_RUNTIME_DIR=tmp)
        env.pop("WAYLAND_DISPLAY", None)
        subprocess.run(["xvfb-run", "-a", *bus], env=dict(env, XDG_SESSION_TYPE="x11"), check=True, timeout=45)
        env.pop("DISPLAY", None)
        socket_name = "rune-private-tray"
        weston = subprocess.Popen(["weston", "--backend=headless", "--renderer=pixman", "--no-config",
                                   "--socket=" + socket_name, "--idle-time=0", "--log=" + str(directory / "weston.log")],
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        try:
            until(lambda: (directory / socket_name).is_socket(), "private Weston socket")
            subprocess.run(bus, env=dict(env, WAYLAND_DISPLAY=socket_name, XDG_SESSION_TYPE="wayland"),
                           check=True, timeout=45)
        finally:
            weston.terminate()
            try:
                weston.wait(timeout=5)
            except subprocess.TimeoutExpired:
                weston.kill()
                weston.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--scratch-path", type=Path, help="optional warm SwiftPM client build directory")
    parser.add_argument("--private-session", action="store_true", help=argparse.SUPPRESS)
    opts = parser.parse_args()
    if opts.private_session:
        exercise(opts.app, late=os.environ["XDG_SESSION_TYPE"] == "wayland")
    else:
        run(opts.app, opts.scratch_path)
