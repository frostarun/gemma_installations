"""
Anthropic /v1/messages → OpenAI /v1/chat/completions proxy.
Full tool use support: tool definitions, tool_use responses, tool_result messages.

Anthropic format                      OpenAI format
─────────────────────────────────────────────────────
tools[].input_schema              →   tools[].function.parameters
assistant content tool_use block  →   choices[].message.tool_calls
user content tool_result block    →   messages with role=tool
"""
import os, json, uuid, httpx, uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

LLAMA_BASE = os.environ.get("LLAMA_BASE", "http://localhost:8080/v1")
PORT = int(os.environ.get("PROXY_PORT", "8081"))
app = FastAPI()

# ── Convert tools: Anthropic → OpenAI ─────────────────────────────────────────

def convert_tools(ant_tools: list) -> list:
    oai_tools = []
    for t in ant_tools:
        oai_tools.append({
            "type": "function",
            "function": {
                "name": t.get("name", ""),
                "description": t.get("description", ""),
                "parameters": t.get("input_schema", {"type": "object", "properties": {}}),
            }
        })
    return oai_tools

# ── Convert messages: Anthropic → OpenAI ──────────────────────────────────────

def extract_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""

def convert_messages(ant_messages: list) -> list:
    oai_messages = []
    for m in ant_messages:
        role = m.get("role", "user")
        content = m.get("content", "")

        # Simple string content
        if isinstance(content, str):
            oai_messages.append({"role": role, "content": content})
            continue

        # Content is a list of blocks — handle mixed types
        text_parts = []
        tool_calls = []       # for assistant messages with tool_use blocks
        tool_results = []     # for user messages with tool_result blocks

        for block in content:
            btype = block.get("type", "")

            if btype == "text":
                text_parts.append(block.get("text", ""))

            elif btype == "tool_use":
                # Assistant is calling a tool
                tool_calls.append({
                    "id": block.get("id", f"call_{uuid.uuid4().hex[:8]}"),
                    "type": "function",
                    "function": {
                        "name": block.get("name", ""),
                        "arguments": json.dumps(block.get("input", {})),
                    }
                })

            elif btype == "tool_result":
                # User is returning tool results
                result_content = block.get("content", "")
                if isinstance(result_content, list):
                    result_content = " ".join(
                        b.get("text", "") for b in result_content
                        if isinstance(b, dict) and b.get("type") == "text"
                    )
                tool_results.append({
                    "role": "tool",
                    "tool_call_id": block.get("tool_use_id", ""),
                    "content": str(result_content),
                })

            elif btype == "thinking":
                # Skip thinking blocks — not supported in OpenAI format
                pass

        # Emit assistant message with text and/or tool_calls
        if role == "assistant":
            msg = {"role": "assistant", "content": " ".join(text_parts) or None}
            if tool_calls:
                msg["tool_calls"] = tool_calls
            oai_messages.append(msg)

        # Emit user message — regular text first, then tool results
        elif role == "user":
            if text_parts:
                oai_messages.append({"role": "user", "content": " ".join(text_parts)})
            for tr in tool_results:
                oai_messages.append(tr)
            # If no text and no results, emit empty user message
            if not text_parts and not tool_results:
                oai_messages.append({"role": "user", "content": ""})

    return oai_messages

# ── Convert full request: Anthropic → OpenAI ──────────────────────────────────

def to_openai(body: dict) -> dict:
    messages = []

    # System prompt
    sys = body.get("system", "")
    if sys:
        text = sys if isinstance(sys, str) else extract_text(sys)
        if text.strip():
            messages.append({"role": "system", "content": text})

    messages.extend(convert_messages(body.get("messages", [])))

    # Gemma 4 is a thinking model — thinking tokens count against max_tokens.
    # Multiply by 3 (capped at 32768) so thinking has room to complete.
    requested = body.get("max_tokens", 4096)
    max_tokens = min(requested * 3, 32768)

    oai: dict = {
        "model": body.get("model", "gemma-4-e4b"),
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": body.get("temperature", 1.0),
        "stream": body.get("stream", False),
    }

    # Tools
    if body.get("tools"):
        oai["tools"] = convert_tools(body["tools"])
        oai["tool_choice"] = "auto"

    return oai

# ── Convert response: OpenAI → Anthropic ──────────────────────────────────────

def to_anthropic(data: dict, model: str) -> dict:
    choice = data.get("choices", [{}])[0]
    msg = choice.get("message", {})
    usage = data.get("usage", {})
    finish = choice.get("finish_reason", "stop")

    content_blocks = []

    # Text content — Gemma 4 is a thinking model: actual response is in "content",
    # thinking is in "reasoning_content". Fall back to reasoning_content only if
    # content is empty (shouldn't happen with sufficient max_tokens/context).
    text = msg.get("content") or ""
    if not text:
        text = msg.get("reasoning_content") or ""
    if text:
        content_blocks.append({"type": "text", "text": text})

    # Tool calls → tool_use blocks
    for tc in msg.get("tool_calls", []):
        fn = tc.get("function", {})
        try:
            inp = json.loads(fn.get("arguments", "{}"))
        except Exception:
            inp = {}
        content_blocks.append({
            "type": "tool_use",
            "id": tc.get("id", f"toolu_{uuid.uuid4().hex[:8]}"),
            "name": fn.get("name", ""),
            "input": inp,
        })

    # Map finish reason
    stop_reason = "end_turn"
    if finish == "tool_calls":
        stop_reason = "tool_use"
    elif finish == "length":
        stop_reason = "max_tokens"

    return {
        "id": data.get("id", f"msg_{uuid.uuid4().hex[:8]}"),
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content_blocks,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }

# ── Streaming SSE conversion ───────────────────────────────────────────────────

def chunk_to_sse(line: str, state: dict) -> list[str]:
    """Convert one OpenAI SSE chunk to one or more Anthropic SSE events."""
    if not line.startswith("data: "):
        return []
    raw = line[6:].strip()
    if raw == "[DONE]":
        events = []
        # Close any open tool_use block
        if state.get("in_tool"):
            events.append(f"event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{state['block_index']}}}\n\n")
            state["in_tool"] = False
            state["block_index"] += 1
        # Close text block
        events.append(f"event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n")
        events.append("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        return events

    try:
        data = json.loads(raw)
        choice = data.get("choices", [{}])[0]
        delta = choice.get("delta", {})
        events = []

        # Text delta
        text = delta.get("content", "")
        if text:
            payload = json.dumps({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":text}})
            events.append(f"event: content_block_delta\ndata: {payload}\n\n")

        # Tool call deltas
        for tc in delta.get("tool_calls", []):
            idx = tc.get("index", 0)
            block_idx = idx + 1  # 0 is reserved for text block

            # Start new tool_use block
            if not state.get(f"tool_{idx}_started"):
                state[f"tool_{idx}_started"] = True
                state["in_tool"] = True
                state["block_index"] = block_idx
                fn = tc.get("function", {})
                start_payload = json.dumps({
                    "type": "content_block_start",
                    "index": block_idx,
                    "content_block": {
                        "type": "tool_use",
                        "id": tc.get("id", f"toolu_{uuid.uuid4().hex[:8]}"),
                        "name": fn.get("name", ""),
                        "input": {}
                    }
                })
                events.append(f"event: content_block_start\ndata: {start_payload}\n\n")

            # Stream input JSON
            args = tc.get("function", {}).get("arguments", "")
            if args:
                delta_payload = json.dumps({
                    "type": "content_block_delta",
                    "index": block_idx,
                    "delta": {"type": "input_json_delta", "partial_json": args}
                })
                events.append(f"event: content_block_delta\ndata: {delta_payload}\n\n")

        return events
    except Exception:
        return []

# ── Routes ────────────────────────────────────────────────────────────────────

@app.post("/v1/messages")
async def messages(request: Request):
    body = await request.json()
    oai = to_openai(body)
    model = body.get("model", "gemma-4-e4b")
    print(f"[REQ] stream={oai['stream']} msgs={len(oai['messages'])} tools={len(oai.get('tools',[]))}", flush=True)
    # Log last user/tool message content for debugging
    for m in reversed(oai["messages"]):
        if m["role"] in ("user", "tool"):
            preview = str(m.get("content",""))[:200]
            print(f"[LAST-{m['role'].upper()}] {preview}", flush=True)
            break

    if oai["stream"]:
        async def stream():
            state: dict = {"in_tool": False, "block_index": 0}
            start = json.dumps({
                "type": "message_start",
                "message": {
                    "id": f"msg_{uuid.uuid4().hex[:8]}",
                    "type": "message", "role": "assistant",
                    "content": [], "model": model,
                    "usage": {"input_tokens": 0, "output_tokens": 0}
                }
            })
            yield f"event: message_start\ndata: {start}\n\n"
            yield "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"

            full_text = []
            async with httpx.AsyncClient(timeout=300) as client:
                async with client.stream("POST", f"{LLAMA_BASE}/chat/completions", json=oai) as r:
                    async for line in r.aiter_lines():
                        if line.startswith("data: ") and line[6:].strip() not in ("[DONE]", ""):
                            try:
                                chunk = json.loads(line[6:])
                                delta = chunk.get("choices",[{}])[0].get("delta",{})
                                if delta.get("content"):
                                    full_text.append(delta["content"])
                                for tc in delta.get("tool_calls",[]):
                                    fn = tc.get("function",{})
                                    full_text.append(f"[TOOL:{fn.get('name','')}({fn.get('arguments','')[:80]})]")
                            except Exception:
                                pass
                        for event in chunk_to_sse(line, state):
                            yield event
            print(f"[RESP] {(''.join(full_text))[:300]}", flush=True)

        return StreamingResponse(stream(), media_type="text/event-stream")
    else:
        async with httpx.AsyncClient(timeout=300) as client:
            r = await client.post(f"{LLAMA_BASE}/chat/completions", json=oai)
            return Response(
                content=json.dumps(to_anthropic(r.json(), model)),
                media_type="application/json"
            )

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.get("/")
async def root():
    return {"status": "ok"}

if __name__ == "__main__":
    print(f"Anthropic→OpenAI proxy on http://0.0.0.0:{PORT}", flush=True)
    print(f"Forwarding to: {LLAMA_BASE}", flush=True)
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="warning")
