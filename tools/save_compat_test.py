#!/usr/bin/env python3
"""Saves across updates (BVNSaveSlot): a game started over existing saves reads
them and keeps what it does not know, never writes over a newer build's save,
restores a damaged one from its backup, and a player's options, keys and musou
progress survive restarts. Runs headless games on a scratch save directory.

    python3 tools/save_compat_test.py [GAME_EXECUTABLE]
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from net_test import ENGINE, Agent, check  # noqa: E402


def envelope(schema, data):
    return json.dumps({"format_version": 1, "schema_version": schema, "data": data}, ensure_ascii=False)


EXE = sys.argv[1] if len(sys.argv) > 1 else str(ENGINE / "build/sdl3-release/game")


def game(root):
    agent = Agent(EXE, dict(os.environ, POCKET_SAVE_ROOT=str(root)))
    agent.req({"cmd": "step", "frames": 3})
    return agent


def slot(root, name):
    p = root / "bleach_vs_naruto" / (name + ".save.json")
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def run():
    with tempfile.TemporaryDirectory(prefix="bvn-saves-") as tmp:
        root = Path(tmp)
        saves = root / "bleach_vs_naruto"
        saves.mkdir()

        # An existing save with a field this build does not know (a newer build's) and a
        # value it does not offer: both survive this build saving its own change.
        (saves / "config.save.json").write_text(envelope(1, {"gameTime": 90, "soundVolume": 0.3, "gameTime2": 5,
                                                             "aiLevel": 42}), encoding="utf-8")
        g = game(root)
        try:
            r = g.call("options_save", {})
            check(r["values"]["gameTime"] == 90 and r["values"]["soundVolume"] == 0.3, "the existing options are read: %s" % r)
            r = g.call("options_save", {"set": {"bgmVolume": 0.5}, "save": True})
            check(r["saved"], "options save")
        finally:
            g.close()
        cfg = slot(root, "config")["data"]
        check(cfg["bgmVolume"] == 0.5 and cfg["gameTime"] == 90, "the change and the old options are saved: %s" % cfg)
        check(cfg.get("gameTime2") == 5, "a field this build does not know is kept")
        check(cfg.get("aiLevel") == 42, "a value this build does not offer is kept while untouched")

        # Keys and musou progress survive a restart.
        g = game(root)
        try:
            check(g.call("keys_bind", {"side": 1, "row": 5, "key": "n", "save": True})["saved"], "keys save")
            m = g.call("musou_data", {"reset": True, "money": 1234, "fighters": ["naruto"], "save": True})
            check(m is not None, "musou save")
        finally:
            g.close()
        before = {n: (saves / (n + ".save.json")).read_bytes() for n in ("config", "keys", "musou")}
        g = game(root)
        try:
            check(g.call("keys_bind", {})["attack"] == ["n"], "a rebound key is loaded after a restart")
            check(g.call("musou_data", {})["money"] == 1234, "musou money is loaded after a restart")
        finally:
            g.close()
        after = {n: (saves / (n + ".save.json")).read_bytes() for n in before}
        check(before == after, "starting the game does not rewrite saves")

        # A newer build's save (higher schema): read for what this build knows, never written.
        newer = envelope(7, {"gameTime": 30, "fromTheFuture": True})
        (saves / "config.save.json").write_text(newer, encoding="utf-8")
        g = game(root)
        try:
            r = g.call("options_save", {})
            check(r["newer"] and r["values"]["gameTime"] == 30, "a newer save is read: %s" % r)
            r = g.call("options_save", {"set": {"gameTime": 60}, "save": True})
            check(not r["saved"], "a newer save is not written over")
        finally:
            g.close()
        check((saves / "config.save.json").read_text(encoding="utf-8") == newer, "the newer save is unchanged")

        # A damaged save comes back from its backup, which is written back as the save.
        (saves / "config.save.json").write_text(envelope(1, {"gameTime": 90}), encoding="utf-8")
        g = game(root)
        try:
            g.call("options_save", {"set": {"gameTime": 30}, "save": True})  # 90 becomes the backup
        finally:
            g.close()
        (saves / "config.save.json").write_bytes(b'{"format_version":1,"sch')
        g = game(root)
        try:
            check(g.call("options_save", {})["values"]["gameTime"] == 90, "a damaged save loads its previous version")
        finally:
            g.close()
        check(slot(root, "config")["data"]["gameTime"] == 90, "the restored version is written back")
    print("save_compat_test passed")


if __name__ == "__main__":
    run()
