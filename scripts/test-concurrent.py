#!/usr/bin/env python3
"""LiteLLM 并发 + 大 context 测试脚本"""

import asyncio
import time
import json
import aiohttp

BASE_URL = "http://127.0.0.1:4010"
API_KEY = "sk-qWL0XHUW0IM6YKhdpbTmZRdzLG5S7e2l"
HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json",
}


async def send_request(session, idx, model="sonnet", messages=None, max_tokens=50):
    """发送单个请求并记录耗时"""
    if messages is None:
        messages = [{"role": "user", "content": f"Say 'Response {idx}' and nothing else."}]

    payload = {"model": model, "messages": messages, "max_tokens": max_tokens}

    start = time.perf_counter()
    try:
        async with session.post(
            f"{BASE_URL}/v1/chat/completions", headers=HEADERS, json=payload
        ) as resp:
            elapsed = time.perf_counter() - start
            data = await resp.json()
            status = resp.status

            if status == 200:
                content = data["choices"][0]["message"]["content"][:80]
                usage = data.get("usage", {})
                return {
                    "idx": idx,
                    "status": status,
                    "elapsed": elapsed,
                    "content": content,
                    "prompt_tokens": usage.get("prompt_tokens", 0),
                    "completion_tokens": usage.get("completion_tokens", 0),
                    "model": data.get("model", "?"),
                }
            else:
                error = data.get("error", {}).get("message", str(data))[:100]
                return {"idx": idx, "status": status, "elapsed": elapsed, "error": error}
    except Exception as e:
        elapsed = time.perf_counter() - start
        return {"idx": idx, "status": "error", "elapsed": elapsed, "error": str(e)[:100]}


async def test_concurrent(n=5):
    """测试 1: 并发 N 个请求"""
    print(f"\n{'='*60}")
    print(f"  TEST 1: 并发 {n} 个请求到 /v1/chat/completions")
    print(f"{'='*60}\n")

    async with aiohttp.ClientSession() as session:
        start = time.perf_counter()
        tasks = [send_request(session, i) for i in range(n)]
        results = await asyncio.gather(*tasks)
        total = time.perf_counter() - start

    for r in sorted(results, key=lambda x: x["idx"]):
        if r.get("error"):
            print(f"  [{r['idx']}] FAIL  {r['elapsed']:.2f}s  error={r['error']}")
        else:
            print(f"  [{r['idx']}] OK    {r['elapsed']:.2f}s  model={r['model']}  tokens={r['prompt_tokens']}+{r['completion_tokens']}  -> {r['content']}")

    times = [r["elapsed"] for r in results]
    ok_count = sum(1 for r in results if not r.get("error"))
    print(f"\n  总耗时: {total:.2f}s | 成功: {ok_count}/{n}")
    print(f"  最快: {min(times):.2f}s | 最慢: {max(times):.2f}s | 平均: {sum(times)/len(times):.2f}s")
    if total < max(times) * 1.5:
        print(f"  -> 并发有效 (总耗时 ≈ 最慢单请求)")
    return results


async def test_large_context():
    """测试 2: ~50K tokens 大 context"""
    print(f"\n{'='*60}")
    print(f"  TEST 2: 大 Context 测试 (~50K tokens)")
    print(f"{'='*60}\n")

    # 每个 word ~1.3 tokens, 50K tokens ≈ 38K words
    # 用重复文本填充
    padding_unit = "The quick brown fox jumps over the lazy dog. " * 20  # ~200 words
    # 38000 / 200 = 190 repeats
    padding = padding_unit * 190
    word_count = len(padding.split())
    char_count = len(padding)

    messages = [
        {"role": "user", "content": f"I'm sending you a large amount of text to test context handling. Please read it and respond with exactly: 'Received [N] characters' where N is the approximate character count.\n\n{padding}\n\nHow many characters approximately did the padding text contain?"}
    ]

    print(f"  Padding: ~{word_count} words, ~{char_count} chars (est ~{word_count * 4 // 3}K tokens)")

    async with aiohttp.ClientSession() as session:
        result = await send_request(session, 0, model="sonnet", messages=messages, max_tokens=100)

    if result.get("error"):
        print(f"  FAIL: {result['error']}")
    else:
        print(f"  OK    {result['elapsed']:.2f}s")
        print(f"  Model: {result['model']}")
        print(f"  Prompt tokens: {result['prompt_tokens']}")
        print(f"  Completion tokens: {result['completion_tokens']}")
        print(f"  Response: {result['content']}")

    return result


async def main():
    print("LiteLLM 性能测试")
    print(f"Endpoint: {BASE_URL}")

    await test_concurrent(5)
    await test_large_context()

    print(f"\n{'='*60}")
    print("  测试完成")
    print(f"{'='*60}")


if __name__ == "__main__":
    asyncio.run(main())
