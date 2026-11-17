#!/usr/bin/env python3
"""Run on Linux: python3 verify.py /path/to/InstanceProbe [--rust-peer /path/to/peer]."""

import argparse
from contextlib import ExitStack
import os
from pathlib import Path
import queue
import signal
import socket
import stat
import struct
import subprocess
import tempfile
import threading


class Peer:
    def __init__(self, stack, program, env, *arguments):
        self.p = subprocess.Popen([program, *arguments], env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, encoding="utf-8")
        stack.callback(self.close)
        self.events = queue.Queue()

        def read():
            for line in self.p.stdout:
                self.events.put(line.rstrip("\n"))
            self.events.put(None)

        threading.Thread(target=read, daemon=True).start()
        self.expect("claiming")

    def next_event(self, timeout=5):
        try:
            return self.events.get(timeout=timeout)
        except queue.Empty as error:
            raise AssertionError(f"timed out waiting for PID {self.p.pid}") from error

    def expect(self, event, timeout=5):
        got = self.next_event(timeout)
        assert got == event, (self.p.pid, event, got)

    def quiet(self, timeout=.15):
        try:
            got = self.events.get(timeout=timeout)
        except queue.Empty:
            return
        raise AssertionError(f"PID {self.p.pid} unexpectedly reported {got!r}")

    def command(self, command, *expected):
        self.p.stdin.write(command + "\n")
        self.p.stdin.flush()
        for event in expected:
            self.expect(event)

    def close(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.wait(timeout=5)
        self.p.stdin.close()
        self.p.stdout.close()


def owner(stack, program, env, listen=True):
    peer = Peer(stack, program, env)
    peer.expect("owner")
    if listen:
        peer.command("listen", "listening")
    return peer


def send(stack, program, env, *arguments):
    peer = Peer(stack, program, env, *arguments)
    peer.expect("delivered")
    assert peer.p.wait(timeout=5) == 0


def socket_path(env):
    identifier = env["RUNE_INSTANCE_TEST_ID"]
    name = "".join(c if c.isascii() and (c.isalnum() or c in "._-") else "-" for c in identifier)
    directory = Path(env.get("XDG_RUNTIME_DIR") or Path(env["TMPDIR"]) / f"rune-{os.getuid()}")
    return directory / f"rune-instance-{name}.sock"


def frame(body, size=None):
    return b"rune-instance 2\0" + struct.pack("<I", len(body) if size is None else size) + body


def exchange(path, packet):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(str(path))
        client.sendall(packet)
        client.shutdown(socket.SHUT_WR)
        return client.recv(1)


def launches(stack, program, env):
    current = owner(stack, program, env, listen=False)
    links = ["rune://project/a b", "https://example.test/café?label=✓"]
    send(stack, program, env, "--flag", links[0], "z://skip", links[1], "42://skip")
    current.quiet()
    current.command("listen", *("url " + link for link in links), "listening")
    send(stack, program, env)
    current.expect("reopen")

    path = socket_path(env)
    assert exchange(path, frame(b"ru://valid")) == b"A"
    current.expect("url ru://valid")
    for packet in (frame(b"\xff"), frame(b"", (1 << 20) + 1), frame(b"short", 100), b"bad"):
        assert exchange(path, packet) == b""
    current.quiet()
    # A peer holding a half-written frame must eventually release the listener.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stalled:
        stalled.settimeout(3)
        stalled.connect(str(path))
        stalled.sendall(b"r")
        assert stalled.recv(1) == b""
    send(stack, program, env, "rune://after-idle-peer")
    current.expect("url rune://after-idle-peer")


def quitting(stack, program, env, claimant=None):
    current = owner(stack, program, env)
    current.command("quit", "quitting")
    assert exchange(socket_path(env), frame(b"rune://declined")) == b"Q"
    current.quiet()
    next_owner = Peer(stack, claimant or program, env, "rune://next")
    next_owner.quiet()
    current.command("release", "released")
    next_owner.expect("owner")
    assert current.p.poll() is None
    next_owner.command("listen", "listening")
    send(stack, program, env)
    next_owner.expect("reopen")


def waiting(stack, program, env, claimant=None):
    current = owner(stack, program, env)
    next_owner = Peer(stack, claimant or program, {**env, "RUNE_INSTANCE_HANDED": str(current.p.pid)})
    next_owner.quiet()
    current.command("release", "released")
    next_owner.expect("owner")
    assert current.p.poll() is None
    next_owner.command("release", "released")
    after = Peer(stack, claimant or program, {**env, "RUNE_RELAUNCH_AFTER": str(current.p.pid)})
    after.quiet()
    current.command("exit")
    assert current.p.wait(timeout=5) == 0
    after.expect("owner")


def handed_to_existing(stack, program, env):
    current = owner(stack, program, env)
    previous = owner(stack, program, {**env, "RUNE_INSTANCE_TEST_ID": "previous.process"})
    handed_env = {**env, "RUNE_INSTANCE_HANDED": str(previous.p.pid)}
    waiting = Peer(stack, program, handed_env, "rune://after-other-pid")
    waiting.quiet()
    previous.command("exit")
    assert previous.p.wait(timeout=5) == 0
    waiting.expect("delivered")
    current.expect("url rune://after-other-pid")

    waiting = Peer(stack, program, {**env, "RUNE_INSTANCE_HANDED": str(current.p.pid)},
                   "rune://after-handoff-deadline")
    waiting.quiet()
    waiting.expect("delivered", timeout=13)
    current.expect("url rune://after-handoff-deadline")


def crashed(stack, program, env):
    current = owner(stack, program, env)
    path = socket_path(env)
    current.p.kill()
    assert current.p.wait(timeout=5) == -signal.SIGKILL
    assert path.is_socket()
    successor = owner(stack, program, env)
    send(stack, program, env, "rune://recovered")
    successor.expect("url rune://recovered")


def concurrent_claims(stack, program, env):
    current = owner(stack, program, env)
    current.p.kill()
    assert current.p.wait(timeout=5) == -signal.SIGKILL
    gated = {**env, "RUNE_INSTANCE_TEST_GATE": "1"}
    contenders = [Peer(stack, program, gated, f"rune://claim/{i}") for i in range(8)]
    for contender in contenders:
        contender.command("begin")
    outcomes = [peer.next_event() for peer in contenders]
    assert outcomes.count("owner") == 1 and outcomes.count("delivered") == 7, outcomes
    index = outcomes.index("owner")
    winner = contenders[index]
    winner.command("listen")
    received = sorted(winner.next_event() for _ in contenders)
    expected = ["listening"] + [f"url rune://claim/{i}" for i in range(8) if i != index]
    assert received == sorted(expected), received


def unresponsive(stack, program, env):
    current = owner(stack, program, env)
    path = socket_path(env)
    old_inode = path.stat().st_ino
    os.kill(current.p.pid, signal.SIGSTOP)
    assert os.WIFSTOPPED(os.waitpid(current.p.pid, os.WUNTRACED)[1])
    successor = owner(stack, program, env)
    successor_inode = path.stat().st_ino
    assert successor_inode != old_inode
    os.kill(current.p.pid, signal.SIGCONT)
    # The timed-out sender already owns the new socket. The old owner must
    # discard that message and release only its original socket.
    current.quiet()
    current.command("release", "released")
    assert path.stat().st_ino == successor_inode
    send(stack, program, env, "rune://replacement")
    successor.expect("url rune://replacement")


def fallback(stack, program, env):
    del env["XDG_RUNTIME_DIR"]
    path = socket_path(env)
    current = owner(stack, program, env)
    assert path.is_socket()
    info = path.parent.lstat()
    assert info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
    send(stack, program, env)
    current.expect("reopen")
    current.command("release", "released")
    assert not path.exists()
    for insecure_mode in (0o755, 0o777):
        path.parent.chmod(insecure_mode)
        unclaimed = owner(stack, program, env)
        assert not path.exists()
        unclaimed.command("exit")
        assert unclaimed.p.wait(timeout=5) == 0
    destination = path.parent.with_name("destination")
    path.parent.rename(destination)
    destination.chmod(0o700)
    path.parent.symlink_to(destination, target_is_directory=True)
    owner(stack, program, env)
    assert not path.exists()


def cross(stack, receiver, sender, env):
    current = owner(stack, receiver, env)
    send(stack, sender, env, "--flag", "rune://native/é", "x://ignored", "https://native/2")
    current.expect("url rune://native/é")
    current.expect("url https://native/2")
    send(stack, sender, env)
    current.expect("reopen")
    current.command("release", "released")
    assert not socket_path(env).exists()


def run(name, test):
    with tempfile.TemporaryDirectory(prefix="rsi-", dir="/tmp") as folder, ExitStack() as stack:
        env = {**os.environ, "XDG_RUNTIME_DIR": folder, "TMPDIR": folder,
               "RUNE_INSTANCE_TEST_ID": "org.rune.🪟/qa"}
        env.pop("RUNE_INSTANCE_HANDED", None)
        env.pop("RUNE_RELAUNCH_AFTER", None)
        test(stack, env)
        print("PASS", name, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("swift", type=Path)
    parser.add_argument("--rust-peer", type=Path)
    args = parser.parse_args()
    swift = args.swift.resolve()
    for test in (launches, quitting, waiting, crashed, unresponsive, fallback, handed_to_existing,
                 concurrent_claims):
        run(test.__name__, lambda stack, env: test(stack, swift, env))
    if args.rust_peer:
        rust = args.rust_peer.resolve()
        run("Swift → Rust", lambda stack, env: cross(stack, rust, swift, env))
        run("Rust → Swift", lambda stack, env: cross(stack, swift, rust, env))
        run("Rust owns, Swift waits for release", lambda stack, env: quitting(stack, rust, env, swift))
        run("Swift owns, Rust waits for release", lambda stack, env: quitting(stack, swift, env, rust))
        run("Rust hands off to Swift", lambda stack, env: waiting(stack, rust, env, swift))
        run("Swift hands off to Rust", lambda stack, env: waiting(stack, swift, env, rust))
