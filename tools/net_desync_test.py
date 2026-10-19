#!/usr/bin/env python3
"""NET PLAY desync recovery: two headless games join over the LAN (through the
lossy proxy: default 150 ms each way, 2% loss) and fight; then one machine's
battle is changed behind the other's back (net_perturb). The checksums show
the desync, the host sends its state, the guest loads it and simulates again,
and afterwards both must hold the same battle state with the desync gone.
Each machine is changed in turn, then in rollback and lockstep.

Usage: tools/net_desync_test.py [game] [--lag MS] [--loss F] [--lockstep]
"""
import os
import sys
import tempfile
import time

from net_test import ENGINE, Agent, LossyProxy, align, check, free_port, step


def opt(name, default):
    return float(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default


def run_until(a, b, cond, ticks, fa=None, fb=None):
    for i in range(ticks):
        step(a, b, 1, fa(i) if fa else None, fb(i) if fb else None)
        time.sleep(0.004)
        if cond():
            return True
    return False


def main():
    given = len(sys.argv) > 1 and not sys.argv[1].startswith("--")
    exe = sys.argv[1] if given else str(ENGINE / "build/sdl3-release/game")
    lag, loss = opt("--lag", 150), opt("--loss", 0.02)
    netcode = "lockstep" if "--lockstep" in sys.argv else "rollback"
    saves = tempfile.TemporaryDirectory(prefix="bvn-desync-saves-")
    a = Agent(exe, dict(os.environ, POCKET_SAVE_ROOT=saves.name + "/a"))
    b = Agent(exe, dict(os.environ, POCKET_SAVE_ROOT=saves.name + "/b"))
    proxy = None
    try:
        step(a, b, 5)
        hport = free_port()
        a.call("net_host", {"lan": True, "port": hport, "netcode": netcode})
        proxy = LossyProxy(("127.0.0.1", hport), lag, loss)
        b.call("net_join", {"address": "127.0.0.1:%d" % proxy.port})
        started = lambda: a.call("net_state")["started"] and b.call("net_state")["started"]
        check(run_until(a, b, started, 2000), "session starts (%s, %d ms each way, %d%% loss)" % (netcode, lag, loss * 100))
        for i in range(200):
            fa = {"p1_attack": i % 6 == 0, "p1_move": 1 if i < 3 else 0}
            fb = {"p1_attack": i % 6 == 3 and i >= 21, "p1_move": -1 if i < 5 else 0}
            step(a, b, 4, fa, fb)
            time.sleep(0.02)
            if a.call("net_state")["phase"] == "battle":
                break
        in_battle = lambda: a.call("net_state")["phase"] == "battle" and b.call("net_state")["phase"] == "battle"
        check(run_until(a, b, in_battle, 1200), "both reach the battle")
        fight_a = lambda i: {"p1_attack": i % 9 == 0, "p1_move": 1 if i % 40 < 10 else 0}
        fight_b = lambda i: {"p1_skill": i % 23 == 0, "p1_attack": i % 7 == 0}
        run_until(a, b, lambda: False, 120, fight_a, fight_b)
        for round_, (who, name) in enumerate(((b, "guest"), (a, "host"), (b, "guest again"))):
            before = who.call("net_state")["status"]["resyncs"]
            who.call("net_perturb", {"side": 1 + round_ % 2, "hp": 40 + round_, "x": 17})
            def desynced():
                sa, sb = a.call("net_state"), b.call("net_state")
                if os.environ.get("DESYNC_DEBUG") and sa["status"]["frame"] % 30 == 0:
                    print(sa["status"]["frame"], sb["status"]["frame"], sa["hash"], sb["hash"], sa["phase"], sb["phase"], sa["status"]["resyncs"])
                return sa["status"]["desync"] or sb["status"]["desync"] or sb["status"]["resyncs"] > before
            check(run_until(a, b, desynced, 900, fight_a, fight_b), name + " changed: the desync is detected")
            t0 = time.time()
            recovered = lambda: (b.call("net_state")["status"]["resyncs"] > before and
                                 a.call("net_state")["status"]["resyncs"] > before and
                                 not a.call("net_state")["status"]["desync"] and not b.call("net_state")["status"]["desync"])
            check(run_until(a, b, recovered, 1500, fight_a, fight_b), name + " changed: resynced")
            st = b.call("net_state")["status"]
            took = time.time() - t0
            # Neutral input until the predictions come true, then the same tick on both.
            run_until(a, b, lambda: False, 150, fight_a, fight_b)
            for _ in range(40):
                step(a, b, 3)
                time.sleep(0.03)
            frame = align(a, b)
            sa, sb = a.call("net_state"), b.call("net_state")
            print("%s: resync of tick %d, %d bytes, %.1f s wall; frame %d hashes %s / %s" % (
                name, st["resync_frame"], st["resync_bytes"], took, frame, sa["hash"], sb["hash"]))
            check(sa["hash"] == sb["hash"], name + " changed: same battle state afterwards")
            check(not sa["status"]["desync"] and not sb["status"]["desync"], name + " changed: no desync afterwards")
            check(not sa["status"]["resync_error"] and not sb["status"]["resync_error"], "no resync error")
            check(sa["status"]["resyncs"] == before + 1 and sb["status"]["resyncs"] == before + 1,
                  name + " changed: one resync (%d / %d)" % (sa["status"]["resyncs"], sb["status"]["resyncs"]))
        print("net_desync_test passed")
    finally:
        a.close()
        b.close()
        if proxy:
            proxy.close()
        saves.cleanup()


if __name__ == "__main__":
    main()
