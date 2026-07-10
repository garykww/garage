from harness.llm import accumulate_stream, iter_sse


def test_iter_sse_parses_data_lines_and_stops_at_done():
    lines = [
        ": keep-alive comment",
        "",
        'data: {"a": 1}',
        'data:{"a": 2}',
        "data: [DONE]",
        'data: {"a": 3}',  # after DONE — must not be yielded
    ]
    assert list(iter_sse(lines)) == [{"a": 1}, {"a": 2}]


def chunk(delta=None, usage=None):
    c = {"choices": [{"delta": delta or {}}]}
    if usage:
        c = {"choices": [], "usage": usage}
    return c


def test_content_deltas_accumulate_and_stream():
    seen = []
    message, usage = accumulate_stream(
        [
            chunk({"role": "assistant"}),
            chunk({"content": "Hel"}),
            chunk({"content": "lo"}),
            chunk(usage={"prompt_tokens": 5, "completion_tokens": 2}),
        ],
        on_text=seen.append,
    )
    assert message == {"role": "assistant", "content": "Hello"}
    assert seen == ["Hel", "lo"]
    assert usage == {"prompt_tokens": 5, "completion_tokens": 2}


def test_tool_call_arguments_assemble_across_chunks():
    message, _ = accumulate_stream(
        [
            chunk({"tool_calls": [{"index": 0, "id": "c1", "function": {"name": "bash"}}]}),
            chunk({"tool_calls": [{"index": 0, "function": {"arguments": '{"comm'}}]}),
            chunk({"tool_calls": [{"index": 0, "function": {"arguments": 'and": "ls"}'}}]}),
        ]
    )
    assert message["content"] is None
    assert message["tool_calls"] == [
        {"id": "c1", "type": "function", "function": {"name": "bash", "arguments": '{"command": "ls"}'}}
    ]


def test_parallel_tool_calls_keyed_by_index():
    message, _ = accumulate_stream(
        [
            chunk({"tool_calls": [{"index": 1, "id": "c2", "function": {"name": "b", "arguments": "{}"}}]}),
            chunk({"tool_calls": [{"index": 0, "id": "c1", "function": {"name": "a", "arguments": "{}"}}]}),
        ]
    )
    assert [tc["id"] for tc in message["tool_calls"]] == ["c1", "c2"]
