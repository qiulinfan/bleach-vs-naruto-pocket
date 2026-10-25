#!/usr/bin/env python3
"""NET PLAY in real time over a slow link: two headless games join through a
local UDP proxy that delays every packet (default 150 ms each way) and drops a
share of them, pick fighters, then each machine runs its own 60 Hz clock in
its own thread with its own scripted input, as two players would. Afterwards
both must hold the same battle state, and the sounds each heard must agree:
every sound played once, the corrections' late and cancelled sounds counted.

Usage: tools/net_pace_test.py [game] [--lag MS] [--loss F] [--seconds S] [--delay N]
"""
import os
import random
import sys
import tempfile
import threading
import time

from net_test import Agent, LossyProxy, align, check, default_game, free_port, step

SOUNDS = ["audio.play", "audio.cancel"]


def opt(name, default):
    return float(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default


def realtime(agent, seconds, seed, out):
    """Steps one tick per 1/60 s of wall clock with random held input, keeping the sounds."""
    rng = random.Random(seed)
    tick = 1.0 / 60.0
    start = time.monotonic()
    n = 0
    held = {}
    late_steps = 0
    while n < seconds * 60:
        if n % 12 == 0:
            held = {}
            r = rng.random()
            if r < 0.3:
                held["p1_move"] = rng.choice([-1, 1])
            elif r < 0.55:
                held["p1_attack"] = True
            elif r < 0.65:
                held["p1_skill"] = True
                if rng.random() < 0.5:
                    held["p1_down"] = True
            elif r < 0.72:
                held["p1_jump"] = True
            elif r < 0.78:
                held["p1_dash"] = True
            elif r < 0.82:
                held["p1_super"] = True
        r = agent.req({"cmd": "step", "frames": 1, "actions": held, "events": SOUNDS})
        out["sounds"] += [(e["type"], e["payload"]) for e in r.get("events", [])]
        n += 1
        due = start + n * tick
        now = time.monotonic()
        if now < due:
            time.sleep(due - now)
        else:
            late_steps += 1
    out["late_steps"] = late_steps
    out["wall"] = time.monotonic() - start


def heard(sounds):
    plays, cancels, dup = {}, set(), 0
    for kind, p in sounds:
        if "tick" not in p:
            continue
        key = (p["tick"], p["clip"], p["nth"])
        if kind == "audio.play":
            if key in plays and key not in cancels:
                dup += 1
            cancels.discard(key)
            plays[key] = p
        else:
            cancels.add(key)
    late = [p["late"] for p in plays.values() if p["late"] > 0]
    return plays, cancels, dup, late


def main():
    given = len(sys.argv) > 1 and not sys.argv[1].startswith("--")
    exe = sys.argv[1] if given else default_game()
    lag, loss, seconds = opt("--lag", 150), opt("--loss", 0.02), opt("--seconds", 20)
    saves = tempfile.TemporaryDirectory(prefix="bvn-pace-saves-")
    a = Agent(exe, dict(os.environ, POCKET_SAVE_ROOT=saves.name + "/a"))
    b = Agent(exe, dict(os.environ, POCKET_SAVE_ROOT=saves.name + "/b"))
    proxy = None
    try:
        step(a, b, 5)
        hport = free_port()
        r = a.call("net_host", {"lan": True, "port": hport, "netcode": "rollback", "delay": int(opt("--delay", 0))})
        check(r["view"] == "wait", "LAN host listens")
        proxy = LossyProxy(("127.0.0.1", hport), lag, loss)
        b.call("net_join", {"address": "127.0.0.1:%d" % proxy.port})
        for _ in range(600):
            step(a, b)
            sa, sb = a.call("net_state"), b.call("net_state")
            if sa["started"] and sb["started"]:
                break
            time.sleep(0.01)
        check(sa["started"] and sb["started"], "session starts over %d ms each way, %d%% loss" % (lag, loss * 100))
        st = sa["status"]
        print("preview: ping %s ms, loss %s, delay %s, path %s" % (st["ping"], st.get("loss"), st["delay"],
                                                                 "relay" if st["relay"] else "direct"))
        for i in range(200):
            fa = {"p1_attack": i % 6 == 0, "p1_move": 1 if i < 3 else 0}
            fb = {"p1_attack": i % 6 == 3 and i >= 21, "p1_move": -1 if i < 5 else 0}
            step(a, b, 4, fa, fb)
            time.sleep(0.02)
            if a.call("net_state")["phase"] == "battle":
                break
        for _ in range(300):
            step(a, b, 4)
            time.sleep(0.02)
            if a.call("net_state")["phase"] == "battle" and b.call("net_state")["phase"] == "battle":
                break
        check(a.call("net_state")["phase"] == "battle", "both reach the battle")
        outs = [{"sounds": []}, {"sounds": []}]
        ts = [threading.Thread(target=realtime, args=(g, seconds, seed, o)) for g, seed, o in ((a, 1, outs[0]), (b, 2, outs[1]))]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        # Neutral input: the predictions come true and both catch up.
        for _ in range(40):
            step(a, b, 3)
            time.sleep(0.05)
        frame = align(a, b)
        step(a, b, 2)
        frame = align(a, b)
        sa, sb = a.call("net_state"), b.call("net_state")
        for name, s, o in (("host", sa, outs[0]), ("guest", sb, outs[1])):
            st = s["status"]
            plays, cancels, dup, late = heard(o["sounds"])
            print("%s: %d ticks in %.1f s (%d behind the clock), ping %s ms, loss %s, delay %s, rollbacks %d, "
                  "deepest %d, slowest %.2f ms, stalls %d; sounds %d played, %d late (max %d ticks), %d cancelled, %d doubled"
                  % (name, seconds * 60, o["wall"], o["late_steps"], st["ping"], st.get("loss"), st["delay"], st["rollbacks"], st["max_rollback_seen"], st["slowest_rollback_ms"],
                     st["stalls"], len(plays), len(late), max(late or [0]), len(cancels), dup))
            check(dup == 0, name + ": no sound played twice")
        check(sa["hash"] == sb["hash"], "same battle state at frame %d: %s / %s" % (frame, sa["hash"], sb["hash"]))
        check(not sa["status"]["desync"] and not sb["status"]["desync"], "no desync reported")
        pa, ca, _, _ = heard(outs[0]["sounds"])
        pb, cb, _, _ = heard(outs[1]["sounds"])
        final_a = {k for k in pa if k not in ca and k[0] < frame - 30}
        final_b = {k for k in pb if k not in cb and k[0] < frame - 30}
        diff = final_a ^ final_b
        print("sounds kept: host %d, guest %d, differing %d" % (len(final_a), len(final_b), len(diff)))
        check(len(diff) <= max(2, len(final_a) // 50), "both machines kept the same sounds (%d differ)" % len(diff))
        print("net_pace_test passed")
    finally:
        a.close()
        b.close()
        if proxy:
            proxy.close()
        saves.cleanup()


if __name__ == "__main__":
    main()
