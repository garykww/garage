import json

from harness.transcript import Transcript


def test_events_written_as_jsonl(tmp_path):
    t = Transcript(tmp_path / "s.jsonl")
    t.write("system", "prompt")
    t.write("assistant", {"role": "assistant", "content": "hi", "reasoning": "…"})
    t.close()

    lines = [json.loads(l) for l in (tmp_path / "s.jsonl").read_text().splitlines()]
    assert [l["kind"] for l in lines] == ["system", "assistant"]
    assert lines[1]["data"]["reasoning"] == "…"
    assert all("t" in l for l in lines)


def test_create_names_by_timestamp_and_makes_dirs(tmp_path):
    t = Transcript.create(tmp_path / "sessions")
    t.write("user", "task")
    t.close()
    files = list((tmp_path / "sessions").glob("*.jsonl"))
    assert len(files) == 1 and files[0] == t.path


def test_flushed_immediately(tmp_path):
    t = Transcript(tmp_path / "s.jsonl")
    t.write("user", "task")
    # readable before close — a crash must not eat the evidence
    assert "task" in (tmp_path / "s.jsonl").read_text()
    t.close()
