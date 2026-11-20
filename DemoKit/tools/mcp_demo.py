"""TitleCut demo run over MCP, doubling as an integration test.

Drives the running app through every MCP tool on a new project made from
media/speech.mp4 and media/music.m4a, checks each result, and writes the
export, subtitles and frame grabs to DemoKit/out/. Prints PASS or FAIL per
step and exits non-zero if any step failed.

Needs TitleCut running with its MCP server on (the MCP button green).

    uv run python -I DemoKit/tools/mcp_demo.py [--url http://127.0.0.1:7340/mcp]

Set TC_KEY when TitleCut requires a key. The project is left open and
unsaved; close it without saving, or keep it.
"""

import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent
MEDIA = KIT / "media"
OUT = KIT / "out"


class Client:
    """Minimal MCP Streamable HTTP client."""

    def __init__(self, url: str, key: str):
        self.url = url
        self.key = key
        self.session = None
        self.counter = 0

    def _post(self, message: dict):
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream",
                   "MCP-Protocol-Version": "2025-03-26"}
        if self.session:
            headers["MCP-Session-Id"] = self.session
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        request = urllib.request.Request(self.url, data=json.dumps(message).encode(),
                                         headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=300) as response:
            self.session = response.headers.get("MCP-Session-Id") or self.session
            body = response.read().decode()
        for line in body.splitlines():
            if line.startswith("data:") and line[5:].strip():
                reply = json.loads(line[5:].strip())
                if reply.get("id") == message.get("id"):
                    return reply
        return json.loads(body) if body.strip() else None

    def request(self, method: str, params: dict):
        self.counter += 1
        return self._post({"jsonrpc": "2.0", "id": self.counter, "method": method,
                           "params": params})

    def initialize(self) -> dict:
        reply = self.request("initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "titlecut-demo-kit", "version": "1"}})
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return reply["result"]

    def call(self, tool: str, **arguments) -> tuple[bool, str, list[bytes]]:
        """(is_error, text, png images)."""
        reply = self.request("tools/call", {"name": tool, "arguments": arguments})
        result = reply.get("result", {})
        texts, images = [], []
        for item in result.get("content", []):
            if item["type"] == "text":
                texts.append(item["text"])
            elif item["type"] == "image":
                images.append(base64.b64decode(item["data"]))
        return bool(result.get("isError")), "\n".join(texts), images


class Run:
    def __init__(self, client: Client):
        self.client = client
        self.project = None
        self.results: list[tuple[str, bool, str]] = []

    def call(self, tool: str, **arguments):
        if self.project:
            arguments.setdefault("project", self.project)
        return self.client.call(tool, **arguments)

    def ok(self, tool: str, **arguments) -> str:
        """Calls a tool that must succeed; returns its text."""
        error, text, _ = self.call(tool, **arguments)
        if error:
            raise AssertionError(f"{tool} failed: {text}")
        return text

    def json(self, tool: str, **arguments):
        return json.loads(self.ok(tool, **arguments))

    def snapshot(self) -> dict:
        return self.json("get_project")

    def wait_for_job(self, kind: str, limit: float = 900) -> dict:
        deadline = time.time() + limit
        while time.time() < deadline:
            status = self.json("job_status")
            if status["kind"] == kind and status["state"] != "running":
                return status
            time.sleep(2)
        raise AssertionError(f"{kind} did not finish in {limit:.0f} s")

    def step(self, name: str, body) -> None:
        try:
            note = body() or ""
            self.results.append((name, True, note))
            print(f"PASS  {name}" + (f" — {note}" if note else ""))
        except Exception as error:  # noqa: BLE001 — reported, run continues
            self.results.append((name, False, str(error)))
            print(f"FAIL  {name} — {error}")

    def grab(self, seconds: float, name: str) -> str:
        error, text, images = self.call("render_frame", seconds=seconds, max_width=960)
        if error or not images:
            raise AssertionError(f"render_frame at {seconds} s failed: {text}")
        path = OUT / f"{name}.png"
        path.write_bytes(images[0])
        return f"{path.name} ({text})"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:7340/mcp")
    url = parser.parse_args().url
    OUT.mkdir(exist_ok=True)
    run = Run(Client(url, os.environ.get("TC_KEY", "")))
    state: dict = {}

    # 1. Connection and the get_instructions gate.
    def connect():
        result = run.client.initialize()
        check(bool(result.get("instructions")), "no instructions in the handshake")
        error, text, _ = run.client.call("list_projects")
        check(error and "get_instructions" in text, "a tool ran before get_instructions")
        manual = run.ok("get_instructions")
        check("Tool reference" in manual, "the manual has no tool reference")
        return f"{result['serverInfo']['name']} {result['serverInfo']['version']}, gate holds"
    run.step("Connect, gate, manual", connect)

    # 2. A new project, addressed by its ID.
    def new_project():
        before = {p["id"] for p in run.json("list_projects")}
        run.ok("new_project")
        for _ in range(20):
            projects = run.json("list_projects")
            new = [p for p in projects if p["id"] not in before]
            if new:
                break
            time.sleep(0.5)
        check(len(new) == 1, "no new project appeared")
        run.project = new[0]["id"]
        state["others"] = len(projects) - 1
        if state["others"]:
            error, text, _ = run.client.call("get_project")
            check(error and "project" in text, "an unnamed call ran with several projects open")
        return f"{new[0]['name']} ({run.project})"
    run.step("New project", new_project)

    # 3. The source video.
    def open_video():
        run.ok("open_video", path=str(MEDIA / "speech.mp4"))
        # has_audio is null while the audio is read in the background.
        for _ in range(120):
            snap = run.snapshot()
            if snap["source"]["has_audio"] is not None:
                break
            time.sleep(0.5)
        check(abs(snap["source"]["duration"] - 223.47) < 0.5, "unexpected source length")
        check(snap["source"]["has_audio"] is True, "the audio was not read in 60 s")
        state["full"] = snap["output"]["duration"]
        return f"{snap['source']['width']}x{snap['source']['height']}, {state['full']} s"
    run.step("Open video", open_video)

    # 4. Remove Silences: dry run, cut, undo, redo.
    def silences():
        found = run.json("find_silences", longer_than_seconds=0.3, quieter_than_db=15)
        check(run.snapshot()["output"]["duration"] == state["full"], "the dry run changed the edit")
        run.ok("remove_silences", longer_than_seconds=0.3, quieter_than_db=15)
        cut = run.snapshot()
        # This video's pauses are short and soft; these settings find dozens.
        check(found["cuts"] > 20, f"only {found['cuts']} pauses found")
        check(len(cut["segments"]) > 20, "the cuts did not split the clip")
        check(cut["output"]["duration"] < state["full"], "cuts did not shorten the video")
        run.ok("undo")
        check(run.snapshot()["output"]["duration"] == state["full"], "undo did not restore")
        run.ok("redo")
        check(run.snapshot()["output"]["duration"] == cut["output"]["duration"], "redo")
        return (f"{found['cuts']} pauses, {found['seconds_removed']} s; "
                f"now {cut['output']['duration']} s")
    run.step("Find and remove silences, undo, redo", silences)

    # 5. Auto-captions, checked against NASA's own subtitles.
    def captions():
        run.ok("auto_captions", language="en-US")
        status = run.wait_for_job("auto_captions")
        check(status["state"] == "done", f"auto_captions {status['state']}: {status['message']}")
        snap = run.snapshot()
        captions = [t for t in snap["titles"] if t["caption"]]
        check(len(captions) > 20, f"only {len(captions)} captions")
        transcript = run.ok("get_transcript")
        heard = set(words(transcript))
        reference = words((MEDIA / "speech-nasa.srt").read_text(encoding="utf-8-sig"))
        reference = [w for w in reference if not w.isdigit()]
        match = sum(w in heard for w in reference) / len(reference)
        check(match > 0.7, f"only {match:.0%} of NASA's words were heard")
        srt = OUT / "captions.srt"
        run.ok("export_subtitles", path=str(srt))
        check(srt.exists() and "-->" in srt.read_text(), "no SRT written")
        state["captions"] = [t["id"] for t in captions]
        return f"{len(captions)} captions, {match:.0%} of NASA's words heard, {srt.name}"
    run.step("Auto-captions and subtitles", captions)

    # 6. A hook title with its own look.
    def hook():
        text = run.ok("add_title", seconds=0, text="Ham radio\nfrom orbit", duration=2.5,
                      style="Meme")
        title = re.search(r"[0-9A-F-]{36}", text).group(0)
        run.ok("update_title", id=title, position="top", size_percent=140,
               color="#FFD60A", outline_color="#000000", outline_width=0.06,
               transition_in="scale", transition_in_seconds=0.4)
        found = next(t for t in run.snapshot()["titles"] if t["id"] == title)
        check(found["own_look"], "the title has no own look")
        check(found["transition_in"]["kind"] == "scale", "transition not set")
        state["hook"] = title
        return run.grab(1.0, "01-hook")
    run.step("Hook title", hook)

    # 7. Title library styles: duplicate, restyle, delete.
    def title_tools():
        styles = [s["name"] for s in run.json("list_styles")]
        check("Neon" in styles, "Neon style missing")
        before = len(run.snapshot()["titles"])
        run.ok("duplicate_titles", ids=[state["hook"]])
        titles = run.snapshot()["titles"]
        check(len(titles) == before + 1, "duplicate_titles added nothing")
        copy = next(t for t in titles
                    if t["text"] == "Ham radio\nfrom orbit" and t["id"] != state["hook"])
        run.ok("set_titles_style", ids=[copy["id"]], style="Neon")
        restyled = next(t for t in run.snapshot()["titles"] if t["id"] == copy["id"])
        check(restyled["style"] == "Neon" and not restyled["own_look"], "restyle failed")
        run.ok("delete_titles", ids=[copy["id"]])
        check(len(run.snapshot()["titles"]) == before, "delete_titles left the copy")
        if state.get("captions"):
            run.ok("update_title", id=state["captions"][0], highlight_color="#FF3B30")
        return f"{len(styles)} styles; duplicate, restyle, delete"
    run.step("Title styles", title_tools)

    # 8. Cutting: split, delete, move, trim.
    def cutting():
        start = run.snapshot()["output"]["duration"]
        run.ok("split_at", seconds=40)
        run.ok("split_at", seconds=50)
        snap = run.snapshot()
        middle = next(s for s in snap["segments"]
                      if s["kind"] == "video" and abs(s["start"] - 40) < 0.05)
        run.ok("delete_segment", id=middle["id"])
        after = run.snapshot()["output"]["duration"]
        check(abs((start - after) - middle["duration"]) < 0.05, "delete did not close up")
        clips = [s for s in run.snapshot()["segments"] if s["kind"] == "video"]
        longest = max(clips, key=lambda s: s["duration"])
        cut = min(2.0, longest["duration"] / 2)
        run.ok("trim_segment", id=longest["id"], source_start=longest["source_start"],
               source_end=longest["source_end"] - cut)
        trimmed = next(s for s in run.snapshot()["segments"] if s["id"] == longest["id"])
        check(abs(trimmed["duration"] - (longest["duration"] - cut)) < 0.05,
              "trim did not shorten the clip")
        run.ok("undo")
        clip = run.snapshot()["segments"][-1]
        run.ok("move_segment", id=clip["id"], to_seconds=clip["start"] + 2)
        moved = run.snapshot()["segments"]
        check(any(s["kind"] == "gap" for s in moved), "moving right left no gap")
        run.ok("undo")
        return f"{start} s → {run.snapshot()['output']['duration']} s"
    run.step("Split, delete, trim, move", cutting)

    # 9. Vertical: 9:16 and per-clip framing.
    def vertical():
        run.ok("set_shape", shape="9:16")
        snap = run.snapshot()
        check(snap["output"]["shape"] == "9:16", "shape not 9:16")
        first = snap["segments"][0]
        run.ok("set_framing", id=first["id"], framing=0.35)
        check(run.snapshot()["segments"][0]["framing"] == 0.35, "framing not set")
        return run.grab(3.0, "02-vertical")
    run.step("9:16 and framing", vertical)

    # 10. Freeze frame with a camera move.
    def freeze():
        text = run.ok("freeze_frame", seconds=12, duration=3)
        freeze_id = re.search(r"[0-9A-F-]{36}", text).group(0)
        run.ok("set_camera", id=freeze_id, center_x=0.5, center_y=0.4, scale=2.2,
               pace="slow_down")
        run.ok("set_freeze_length", id=freeze_id, seconds=4)
        found = next(s for s in run.snapshot()["segments"] if s["id"] == freeze_id)
        check(found["duration"] == 4 and found["camera"], "freeze not 4 s with a camera")
        grab = run.grab(15.5, "03-freeze-zoom")
        run.ok("reset_camera", id=freeze_id)
        check(next(s for s in run.snapshot()["segments"] if s["id"] == freeze_id)["camera"]
              is None, "reset_camera left a camera")
        run.ok("undo")
        return grab
    run.step("Freeze frame and camera", freeze)

    # 11. Background music.
    def music():
        piece = run.json("add_music", path=str(MEDIA / "music.m4a"), seconds=0)
        run.ok("update_music", id=piece["id"], volume=0.25, fade_in=1, fade_out=2)
        run.ok("duplicate_music", id=piece["id"])
        pieces = run.snapshot()["music"]
        check(len(pieces) == 2 and pieces[1]["start"] >= pieces[0]["end"] - 0.01,
              "duplicate did not follow")
        run.ok("update_music", id=pieces[1]["id"], duration=30)
        check(abs(run.snapshot()["music"][1]["end"] - pieces[1]["start"] - 30) < 0.05,
              "trim failed")
        run.ok("add_music", path=str(MEDIA / "music.m4a"), seconds=200)
        extra = run.snapshot()["music"][-1]
        run.ok("delete_music", id=extra["id"])
        check(len(run.snapshot()["music"]) == 2, "delete_music left the piece")
        return f"2 pieces, volume 0.25, {pieces[1]['end'] + 0:.0f} s of music"
    run.step("Music", music)

    # 12. Transport.
    def transport():
        run.ok("seek", seconds=20)
        check(abs(run.snapshot()["playhead"] - 20) < 0.1, "seek missed")
        run.ok("play")
        time.sleep(1.5)
        playing = run.snapshot()
        run.ok("pause")
        check(playing["playing"] and playing["playhead"] > 20, "playback did not run")
        return f"played to {playing['playhead']} s"
    run.step("Seek, play, pause", transport)

    # 13. Export with subtitles.
    def export():
        mp4 = OUT / "demo.mp4"
        for path in (mp4, mp4.with_suffix(".srt")):
            path.unlink(missing_ok=True)
        run.ok("export", path=str(mp4), codec="h264", subtitles=True)
        status = run.wait_for_job("export", limit=1800)
        check(status["state"] == "done", f"export {status['state']}: {status['message']}")
        check(mp4.exists() and mp4.stat().st_size > 1_000_000, "no MP4 written")
        check(mp4.with_suffix(".srt").exists(), "no SRT beside the MP4")
        return f"{mp4.name}, {mp4.stat().st_size / 1e6:.1f} MB, with .srt"
    run.step("Export MP4", export)

    failed = [name for name, passed, _ in run.results if not passed]
    print(f"\n{len(run.results) - len(failed)} of {len(run.results)} steps passed."
          + (f" Failed: {', '.join(failed)}." if failed else ""))
    print(f"Output: {OUT}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
