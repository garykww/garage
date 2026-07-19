"""Milestone 7 gate: a live session survives compaction of its history.

Triggering compaction with genuinely large output proved unreliable — the
model piped `seq` through `tail -1` and kept the session tiny (see git
history). So the trigger is made deterministic instead: context_budget=1
compacts after every tool turn, and keep_recent=2 keeps only the newest
exchange intact. What the test then proves is the part that needs a real
server: the model still completes a multi-step task when most of its tool
history has been elided, because the secret it must report was read last
and sits inside the protected window.
"""

import uuid

from harness.tools.bash import bash


def test_compaction_mid_session_still_completes(agent_factory, tmp_path):
    secret = uuid.uuid4().hex[:12]
    (tmp_path / "secret.txt").write_text(secret + "\n")
    events = []
    agent = agent_factory(
        [bash],
        context_budget=1,
        keep_recent=2,
        on_event=lambda k, d: events.append(k),
    )
    result = agent.run(
        "Do these steps in order, one tool call at a time: "
        "1) run `seq 100000 102000` and note the last number printed; "
        "2) run `seq 200000 202000` and note the last number printed; "
        f"3) read {tmp_path}/secret.txt and tell me its exact contents."
    )
    assert result.stop_reason == "done", result
    assert secret in result.text, result.text
    assert "compact" in events, "budget of 1 token must force compaction"
    assert any("[elided" in (m.get("content") or "") for m in agent.messages)
