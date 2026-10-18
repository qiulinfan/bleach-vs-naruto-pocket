#!/usr/bin/env python3
"""NET PLAY end to end: a local room server and two headless games. The host
opens a room, the guest joins with the code, both go through the fighter
select and fight with their own player 1 keys; the two machines must stay in
the same state (positions, HP, the battle hash, the seed) and the guest returns
to the NET PLAY screen when the host leaves.

Usage: tools/net_test.py [path/to/pocket2d/build/sdl3-release/game] [--relay]
       tools/net_test.py [game] --lan [--lag MS] [--loss FRACTION]
--lan joins by address through a local UDP proxy that delays each packet by
MS milliseconds (each way) and drops FRACTION of them.
"""
import json
import os
import queue
import random
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT.parent.parent / "pocket2d"


class Agent:
    def __init__(self, exe, env):
        self.p = subprocess.Popen([exe, "--headless", "--agent", "--project", str(ROOT)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1, env=env)
        self.q = queue.Queue()
        self.err = []
        threading.Thread(target=lambda: [self.q.put(l) for l in self.p.stdout] + [self.q.put(None)], daemon=True).start()
        threading.Thread(target=lambda: [self.err.append(l) for l in self.p.stderr], daemon=True).start()

    def req(self, c):
        self.p.stdin.write(json.dumps(c) + "\n")
        self.p.stdin.flush()
        line = self.q.get(timeout=60)
        if line is None:
            raise AssertionError("game exited: " + "".join(self.err[-20:]))
        r = json.loads(line)
        if not r.get("ok"):
            raise AssertionError(str(r)[:800])
        return r

    def call(self, name, args=None):
        r = self.req({"cmd": "call", "name": name, "args": args or {}})
        for res in r["call"]["results"]:
            if res.get("value") is not None:
                return res["value"]
        return None

    def close(self):
        try:
            self.p.stdin.write('{"cmd":"quit"}\n')
            self.p.stdin.flush()
            self.p.wait(timeout=20)
        except Exception:
            self.p.kill()


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)
    print("ok:", msg)


def both(a, b, ca, cb):
    out = [None, None]
    def go(i, ag, c):
        out[i] = ag.req(c)
    ts = [threading.Thread(target=go, args=(0, a, ca)), threading.Thread(target=go, args=(1, b, cb))]
    for t in ts: t.start()
    for t in ts: t.join()
    return out


def step(a, b, frames=1, aa=None, ab=None):
    both(a, b, {"cmd": "step", "frames": frames, "actions": aa or {}}, {"cmd": "step", "frames": frames, "actions": ab or {}})


def align(a, b):
    # Lockstep lets one side run up to `delay` ticks ahead: compare at the same tick.
    for _ in range(30):
        fa, fb = a.call("net_state")["status"]["frame"], b.call("net_state")["status"]["frame"]
        if fa == fb:
            return fa
        (a if fa < fb else b).req({"cmd": "step", "actions": {}})
    raise AssertionError("frames never aligned")


class LossyProxy:
    """Forwards UDP between the guest and the host with a delay and random loss."""

    def __init__(self, target, lag_ms, loss):
        self.target, self.lag, self.loss = target, lag_ms / 1000.0, loss
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.002)
        self.port = self.sock.getsockname()[1]
        self.client = None
        self.pending = []
        self.running = True
        self.rng = random.Random(7)
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        while self.running:
            try:
                data, addr = self.sock.recvfrom(4096)
                if addr != self.target:
                    self.client = addr
                to = self.client if addr == self.target else self.target
                if to and self.rng.random() >= self.loss:
                    self.pending.append((time.monotonic() + self.lag, data, to))
            except socket.timeout:
                pass
            now = time.monotonic()
            due = [p for p in self.pending if p[0] <= now]
            self.pending = [p for p in self.pending if p[0] > now]
            for _, data, to in due:
                self.sock.sendto(data, to)

    def close(self):
        self.running = False


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    given = len(sys.argv) > 1 and not sys.argv[1].startswith("--")
    exe = sys.argv[1] if given else str(ENGINE / "build/sdl3-release/game")
    relay = "--relay" in sys.argv
    lan = "--lan" in sys.argv
    def opt(name, default):
        return float(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default
    lag, loss = opt("--lag", 0), opt("--loss", 0)
    proxy = None
    port = free_port()
    server = subprocess.Popen([sys.executable, str(ENGINE / "tools/room_server/room_server.py"), "--port", str(port),
                               "--bind", "127.0.0.1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    saves = tempfile.TemporaryDirectory(prefix="bvn-net-saves-")
    env = dict(os.environ, POCKET_NET_SERVER="127.0.0.1:%d" % port)
    agents = []
    try:
        ea = dict(env, POCKET_SAVE_ROOT=saves.name + "/a")
        eb = dict(env, POCKET_SAVE_ROOT=saves.name + "/b")
        a, b = Agent(exe, ea), Agent(exe, eb)
        agents = [a, b]
        step(a, b, 5)
        if lan:
            hport = free_port()
            r = a.call("net_host", {"lan": True, "port": hport})
            check(r["view"] == "wait" and r["status"]["lan"], "LAN host listens at %s" % r["status"]["lan"])
            proxy = LossyProxy(("127.0.0.1", hport), lag, loss)
            r = b.call("net_join", {"address": "127.0.0.1:%d" % proxy.port})
            check(r["view"] == "wait", "guest joins over the LAN (lag %d ms, loss %d%%)" % (lag, loss * 100))
        else:
            r = a.call("net_host", {"team": False, "relay": relay})
            check(r["view"] == "wait", "host opens a room: %s" % r)
            room = ""
            for _ in range(100):
                a.req({"cmd": "step"})
                room = a.call("net_state")["status"]["room"]
                if room:
                    break
                time.sleep(0.02)
            check(len(room) == 4, "room code " + room)
            r = b.call("net_join", {"room": room, "relay": relay})
            check(r["view"] == "wait", "guest joins: %s" % r)
        for _ in range(400):
            step(a, b)
            sa, sb = a.call("net_state"), b.call("net_state")
            if sa["started"] and sb["started"]:
                break
            time.sleep(0.005)
        check(sa["started"] and sb["started"], "session starts on both")
        check(sa["seed"] == sb["seed"] and sa["mode"] == "pvp" == sb["mode"], "same seed and VS PEOPLE")
        # Fighter select: each player moves its own cursor with its own keys and picks with attack.
        for i in range(60):
            fa = {"p1_attack": i % 6 == 0, "p1_move": 1 if i < 3 else 0}
            fb = {"p1_attack": i % 6 == 3, "p1_move": -1 if i < 5 else 0}
            step(a, b, 4, fa, fb)
            if a.call("net_state")["phase"] == "battle":
                break
        for _ in range(240):
            step(a, b, 4)
            if a.call("net_state")["phase"] == "battle" and b.call("net_state")["phase"] == "battle":
                break
        align(a, b)
        sa, sb = a.call("net_state"), b.call("net_state")
        check(sa["phase"] == "battle" and sb["phase"] == "battle", "both reach the battle: %s / %s" % (sa["phase"], sb["phase"]))
        # Fight: the host walks right and attacks, the guest (its own p1 keys = p2) jumps and attacks.
        moves = [({"p1_move": 1}, {"p1_move": -1}), ({"p1_attack": True}, {"p1_jump": True}), ({}, {"p1_attack": True}),
                 ({"p1_skill": True}, {}), ({"p1_dash": True}, {"p1_move": 1})]
        for i in range(150):
            fa, fb = moves[i % len(moves)]
            step(a, b, 4, fa, fb)
        step(a, b, 10)
        frame = align(a, b)
        oa, ob = a.req({"cmd": "observe"}), b.req({"cmd": "observe"})
        fight = [c["properties"] for o in (oa, ob) for x in o["actors"] for c in x["components"]
                 if "p1_hp" in c.get("properties", {})]
        check(len(fight) == 2, "the game component on both")
        check(fight[0]["p1_hp"] == fight[1]["p1_hp"] and fight[0]["p2_hp"] == fight[1]["p2_hp"],
              "same HP: %s %s" % (fight[0]["p1_hp"], fight[0]["p2_hp"]))
        sa, sb = a.call("net_state"), b.call("net_state")
        check(sa["hash"] == sb["hash"], "same battle state at frame %d: %s / %s" % (frame, sa["hash"], sb["hash"]))
        check(sa["seed"] == sb["seed"], "same RNG state")
        check(not sa["desync"] and not sb["desync"] and not sa["status"]["desync"] and not sb["status"]["desync"],
              "no desync reported")
        check(sa["status"]["relay"] == relay == sb["status"]["relay"], "transport: %s" % ("relay" if sa["status"]["relay"] else "direct"))
        check(sa["status"]["delay"] == sb["status"]["delay"] and (sa["status"]["delay"] >= 4 if lag >= 50 else True),
              "input delay %d for %d ms lag" % (sa["status"]["delay"], lag))
        print("ping", sa["status"]["ping"], "stalls", sa["status"]["stalls"], sb["status"]["stalls"])
        # The host quits: the guest is back on the NET PLAY screen with a message.
        a.close()
        agents = [b]
        for _ in range(600):
            b.req({"cmd": "step", "frames": 2})
            sb = b.call("net_state")
            if sb["phase"] == "netplay":
                break
        check(sb["phase"] == "netplay" and not sb["started"], "guest returns to NET PLAY: %s" % sb.get("message"))
        print("net_test passed")
    finally:
        for ag in agents:
            ag.close()
        if proxy:
            proxy.close()
        server.terminate()
        server.wait(timeout=10)
        saves.cleanup()


if __name__ == "__main__":
    main()
