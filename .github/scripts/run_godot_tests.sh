#!/usr/bin/env bash
# 透過 godot-ai MCP server（streamable-http，godot_ai 外掛開機時自動拉起）
# 呼叫 test_run，取代 MCP client：純 curl + jq 打標準 JSON-RPC 2.0。
#
# 為什麼不能直接 `godot --headless`：McpTestRunner 綁在
# Engine.is_editor_hint()，godot_ai 外掛偵測到 --headless 會直接自我停用
# （log 印 "MCP | plugin disabled in headless mode"），所以一定要讓編輯器
# 用非 headless 模式開機（配合 Xvfb 假的顯示伺服器）外掛才會啟動。
set -euo pipefail

GODOT_BIN="${GODOT_BIN:?請設定 GODOT_BIN 指向 Godot 執行檔}"
PROJECT_PATH="${PROJECT_PATH:?請設定 PROJECT_PATH 指向 Godot 專案目錄}"
MCP_HTTP_PORT="${MCP_HTTP_PORT:-8000}"
BOOT_TIMEOUT_SEC="${BOOT_TIMEOUT_SEC:-120}"
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-300}"

MCP_URL="http://127.0.0.1:${MCP_HTTP_PORT}/mcp"

echo "== 啟動編輯器（Xvfb 虛擬顯示，非 headless）=="
"$GODOT_BIN" --editor --path "$PROJECT_PATH" > /tmp/godot_editor.log 2>&1 &
EDITOR_PID=$!

cleanup() {
	echo "== 收尾：關閉編輯器 =="
	kill "$EDITOR_PID" 2>/dev/null || true
	wait "$EDITOR_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "== 等待 MCP server 就緒（port ${MCP_HTTP_PORT}）=="
ready=""
for i in $(seq 1 "$BOOT_TIMEOUT_SEC"); do
	if ! kill -0 "$EDITOR_PID" 2>/dev/null; then
		echo "編輯器行程提前結束，開機失敗，log：" >&2
		cat /tmp/godot_editor.log >&2
		exit 1
	fi
	out=$(curl -s --max-time 3 -X POST "$MCP_URL" \
		-H "Content-Type: application/json" \
		-H "Accept: application/json, text/event-stream" \
		-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ci","version":"0.1"}}}' \
		2>/dev/null || true)
	if echo "$out" | grep -q '"serverInfo"'; then
		ready="1"
		break
	fi
	sleep 1
done

if [ -z "$ready" ]; then
	echo "等超過 ${BOOT_TIMEOUT_SEC} 秒 MCP server 還沒就緒，開機 log：" >&2
	cat /tmp/godot_editor.log >&2
	exit 1
fi

echo "== MCP handshake：抓 session id =="
SESSION_ID=$(curl -s -D - -o /tmp/mcp_init_body.txt -X POST "$MCP_URL" \
	-H "Content-Type: application/json" \
	-H "Accept: application/json, text/event-stream" \
	-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ci","version":"0.1"}}}' \
	| grep -i "^mcp-session-id:" | tr -d '\r' | awk '{print $2}')

if [ -z "$SESSION_ID" ]; then
	echo "沒有拿到 Mcp-Session-Id，initialize 回應：" >&2
	cat /tmp/mcp_init_body.txt >&2
	exit 1
fi

curl -s -X POST "$MCP_URL" \
	-H "Content-Type: application/json" \
	-H "Accept: application/json, text/event-stream" \
	-H "Mcp-Session-Id: $SESSION_ID" \
	-d '{"jsonrpc":"2.0","id":2,"method":"notifications/initialized"}' > /dev/null

echo "== 呼叫 test_run（timeout_budget_sec=${TEST_TIMEOUT_SEC}）=="
RAW=$(curl -s --max-time "$((TEST_TIMEOUT_SEC + 15))" -X POST "$MCP_URL" \
	-H "Content-Type: application/json" \
	-H "Accept: application/json, text/event-stream" \
	-H "Mcp-Session-Id: $SESSION_ID" \
	-d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"test_run\",\"arguments\":{\"suite\":\"\",\"verbose\":false,\"timeout_budget_sec\":${TEST_TIMEOUT_SEC}}}}")

# streamable-http 回應是 SSE 格式（event: message\ndata: {...}），只取 data 那行的 JSON
JSON_LINE=$(echo "$RAW" | grep '^data:' | sed 's/^data: //')

if [ -z "$JSON_LINE" ]; then
	echo "沒有解析到 test_run 回應，原始輸出：" >&2
	echo "$RAW" >&2
	exit 1
fi

echo "$JSON_LINE" > /tmp/test_run_result.json
echo "== test_run 原始結果 =="
echo "$JSON_LINE" | jq .

RESULT_TEXT=$(echo "$JSON_LINE" | jq -r '.result.content[0].text // empty')
if [ -z "$RESULT_TEXT" ]; then
	ERROR_MSG=$(echo "$JSON_LINE" | jq -r '.error.message // "未知錯誤"')
	echo "test_run 呼叫失敗：$ERROR_MSG" >&2
	exit 1
fi

FAILED=$(echo "$RESULT_TEXT" | jq -r '.failed // 0')
PASSED=$(echo "$RESULT_TEXT" | jq -r '.passed // 0')
TOTAL=$(echo "$RESULT_TEXT" | jq -r '.total // 0')

echo "== 摘要：passed=${PASSED} failed=${FAILED} total=${TOTAL} =="

if [ "$FAILED" != "0" ]; then
	echo "$RESULT_TEXT" | jq -r '.failures[]? | "FAILED: \(.suite)/\(.test): \(.message)"' >&2
	exit 1
fi

echo "全部通過。"
