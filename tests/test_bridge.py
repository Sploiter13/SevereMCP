"""Round-trip tests for the SevereMCP server, using a fake bridge (no Severe needed)."""

import asyncio
import json
import os
import sys

import websockets

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import server  # noqa: E402

TEST_PORT = 8799


def test_tools_registered():
    names = {t.name for t in server.TOOLS}
    assert len(server.TOOLS) == 22
    # a sampling across the new bundles
    for expected in ("severe_status", "severe_execute", "severe_fire_remote",
                     "severe_read_chain", "severe_input", "severe_game_info",
                     "severe_get", "severe_set", "severe_call", "severe_memory_scan"):
        assert expected in names, expected


def test_docs_loaded():
    # docs file ships with the repo; if present it must be non-empty text
    assert isinstance(server.SEVERE_DOCS, str)
    if os.path.exists(server.DOCS_PATH):
        assert len(server.SEVERE_DOCS) > 0
        toc = server._docs_response(None)
        assert "table of contents" in toc.lower()


def test_roundtrip_correlation_errors_timeout_and_disconnect():
    async def run():
        mgr = server.BridgeManager()

        async def fake_bridge():
            async with websockets.connect(f"ws://127.0.0.1:{TEST_PORT}") as ws:
                await ws.send(json.dumps({"hello": "severe-bridge",
                                          "version": server.SERVER_VERSION}))
                async for raw in ws:
                    msg = json.loads(raw)
                    if "id" not in msg:
                        continue  # welcome / keepalive
                    op = msg["op"]
                    if op == "slow":
                        continue  # deliberately never reply -> timeout
                    if op == "boom":
                        await ws.send(json.dumps({"id": msg["id"], "ok": False,
                                                  "error": "kaboom"}))
                        continue
                    res = {"value": 2} if op == "eval" else {"echo": op}
                    await ws.send(json.dumps({"id": msg["id"], "ok": True, "result": res}))

        srv = await websockets.serve(mgr.handler, "127.0.0.1", TEST_PORT)
        task = asyncio.create_task(fake_bridge())
        await asyncio.sleep(0.4)

        assert mgr.connected
        assert (mgr.hello or {}).get("version") == server.SERVER_VERSION

        assert await mgr.send_command("eval", {}) == {"value": 2}

        try:
            await mgr.send_command("boom", {})
            assert False, "expected error propagation"
        except RuntimeError as e:
            assert "kaboom" in str(e)

        try:
            await mgr.send_command("slow", {}, timeout=0.3)
            assert False, "expected timeout"
        except RuntimeError as e:
            assert "timed out" in str(e)

        task.cancel()
        srv.close()
        await srv.wait_closed()
        await asyncio.sleep(0.1)

        try:
            await mgr.send_command("eval", {})
            assert False, "expected not-connected error"
        except RuntimeError as e:
            assert "not connected" in str(e)

    asyncio.run(run())
