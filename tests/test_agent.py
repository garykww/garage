import json

from harness.agent import Agent
from harness.tools import ToolRegistry, tool


@tool(
    description="Echo text back",
    parameters={"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
)
def echo(text: str) -> str:
    return f"echo:{text}"


class FakeClient:
    """Returns scripted assistant messages in order; records requests."""

    def __init__(self, replies, usages=None):
        self.replies = list(replies)
        self.usages = list(usages or [])
        self.requests = []
        self.last_usage = None

    def chat(self, messages, tools=None, max_tokens=4096):
        self.requests.append([dict(m) for m in messages])
        if self.usages:
            self.last_usage = self.usages.pop(0)
        return self.replies.pop(0)


def tc(call_id, text):
    return {
        "id": call_id,
        "type": "function",
        "function": {"name": "echo", "arguments": json.dumps({"text": text})},
    }


def make_agent(replies, usages=None, **kwargs):
    return Agent(FakeClient(replies, usages), ToolRegistry([echo]), system_prompt="sys", **kwargs)


def test_immediate_answer():
    agent = make_agent([{"role": "assistant", "content": "done", "reasoning": "hmm"}])
    result = agent.run("hi")
    assert (result.text, result.turns, result.stop_reason) == ("done", 1, "done")
    # reasoning is stripped before the message re-enters the conversation
    assert agent.messages[-1] == {"role": "assistant", "content": "done"}


def test_tool_call_then_answer():
    agent = make_agent(
        [
            {"role": "assistant", "content": None, "tool_calls": [tc("c1", "hi")]},
            {"role": "assistant", "content": "answer"},
        ]
    )
    result = agent.run("task")
    assert result.stop_reason == "done" and result.turns == 2
    # the second request must contain the tool result, matched by id
    second_request = agent.client.requests[1]
    tool_msgs = [m for m in second_request if m["role"] == "tool"]
    assert tool_msgs == [{"role": "tool", "tool_call_id": "c1", "content": "echo:hi"}]


def test_parallel_tool_calls_all_answered_in_order():
    agent = make_agent(
        [
            {"role": "assistant", "content": None, "tool_calls": [tc("c1", "a"), tc("c2", "b")]},
            {"role": "assistant", "content": "answer"},
        ]
    )
    agent.run("task")
    tool_msgs = [m for m in agent.messages if m["role"] == "tool"]
    assert [m["tool_call_id"] for m in tool_msgs] == ["c1", "c2"]
    assert [m["content"] for m in tool_msgs] == ["echo:a", "echo:b"]


def test_max_turns_stops_loop():
    replies = [{"role": "assistant", "content": None, "tool_calls": [tc(f"c{i}", "x")]} for i in range(3)]
    agent = make_agent(replies, max_turns=3)
    result = agent.run("task")
    assert result.stop_reason == "max_turns" and result.turns == 3


def test_compaction_elides_old_tool_results_only():
    long = "x" * 500
    events = []
    agent = make_agent(
        [
            {"role": "assistant", "content": None, "tool_calls": [tc("c1", long)]},
            {"role": "assistant", "content": None, "tool_calls": [tc("c2", long)]},
            {"role": "assistant", "content": "answer"},
        ],
        usages=[{"prompt_tokens": 150}, {"prompt_tokens": 150}, {"prompt_tokens": 150}],
        context_budget=100,
        keep_recent=2,
        on_event=lambda k, d: events.append((k, d)),
    )
    agent.run("task")
    tool_msgs = [m for m in agent.messages if m["role"] == "tool"]
    assert "[elided" in tool_msgs[0]["content"]
    assert tool_msgs[0]["content"].startswith("echo:xxx"), "elided results keep a head"
    assert "[elided" not in tool_msgs[1]["content"], "recent window stays intact"
    assert agent.messages[0]["content"] == "sys" and agent.messages[1]["content"] == "task"
    assert [d for k, d in events if k == "compact"] == [{"elided": 1, "prompt_tokens": 150}]
    # structure preserved: still one tool result per call id
    assert [m["tool_call_id"] for m in tool_msgs] == ["c1", "c2"]


def test_no_compaction_under_budget():
    agent = make_agent(
        [
            {"role": "assistant", "content": None, "tool_calls": [tc("c1", "a")]},
            {"role": "assistant", "content": "answer"},
        ],
        usages=[{"prompt_tokens": 50}, {"prompt_tokens": 50}],
        context_budget=100,
        keep_recent=1,
    )
    agent.run("task")
    tool_msgs = [m for m in agent.messages if m["role"] == "tool"]
    assert tool_msgs[0]["content"] == "echo:a"


def test_events_emitted():
    events = []
    agent = make_agent(
        [
            {"role": "assistant", "content": None, "tool_calls": [tc("c1", "a")]},
            {"role": "assistant", "content": "answer"},
        ],
        on_event=lambda kind, data: events.append(kind),
    )
    agent.run("task")
    assert events == ["assistant", "tool_result", "assistant"]
