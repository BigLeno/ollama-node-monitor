#!/usr/bin/env bats
# Roda o monitor de verdade (curl, jq, arquivos) contra um servidor falso que imita o Ollama e o Telegram.

setup_file() {
  export WORK="$BATS_FILE_TMPDIR"
  export PS_FILE="$WORK/ps.json"
  export MESSAGES="$WORK/messages.jsonl"
  export PORT=$((20000 + RANDOM % 20000))
  python3 "$BATS_TEST_DIRNAME/fake_server.py" "$PORT" "$PS_FILE" "$MESSAGES" &
  echo $! >"$WORK/server.pid"
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.1
  done
}

teardown_file() {
  kill "$(cat "$WORK/server.pid")" 2>/dev/null || true
}

setup() {
  export OLLAMA_URL="http://127.0.0.1:$PORT"
  export TELEGRAM_API_URL="http://127.0.0.1:$PORT"
  export TELEGRAM_BOT_TOKEN="123456:TOKEN-SECRETO"
  export TELEGRAM_CHAT_ID="-1001"
  export STATE_DIR="$BATS_TEST_TMPDIR/state"
  export METRICS_FILE="$BATS_TEST_TMPDIR/ollama.prom"
  export NODE_NAME="node-ci"
  export PROXMOX_CTID=""
  : >"$MESSAGES"
  MONITOR="$BATS_TEST_DIRNAME/../bin/ollama-node-monitor"
}

serve() {
  if [ -n "$1" ]; then cp "$BATS_TEST_DIRNAME/fixtures/$1" "$PS_FILE"; else rm -f "$PS_FILE"; fi
}

messages() {
  jq -r '.text' "$MESSAGES"
}

@test "fluxo completo: início, carga, descarga, queda e volta do Ollama" {
  serve ps_empty.json
  run "$MONITOR" --once
  [ "$status" -eq 0 ]
  [[ "$(messages)" == *"Monitor iniciado"*"Nenhum modelo carregado"* ]]

  : >"$MESSAGES"
  serve ps_llama.json
  "$MONITOR" --once 2>/dev/null
  [[ "$(messages)" == *"Modelo carregado"*"llama3.2:3b"*"3.2B"*"100% GPU"* ]]

  : >"$MESSAGES"
  serve ps_empty.json
  "$MONITOR" --once 2>/dev/null
  [[ "$(messages)" == *"Modelo descarregado"*"llama3.2:3b"* ]]

  : >"$MESSAGES"
  serve ""
  "$MONITOR" --once 2>/dev/null
  "$MONITOR" --once 2>/dev/null
  [ "$(grep -c 'indispon' "$MESSAGES")" -eq 1 ]

  : >"$MESSAGES"
  serve ps_empty.json
  "$MONITOR" --once 2>/dev/null
  [[ "$(messages)" == *"voltou a responder"* ]]
}

@test "manda para o chat certo, em HTML, sem vazar o token no log" {
  serve ps_llama.json
  run "$MONITOR" --once
  [ "$(jq -r '.chat_id' "$MESSAGES")" = "-1001" ]
  [[ "$(jq -r '.path' "$MESSAGES")" == "/bot123456:TOKEN-SECRETO/sendMessage" ]]
  [[ "$output" != *"TOKEN-SECRETO"* ]]
}

@test "grava métricas e estado em disco" {
  serve ps_two.json
  "$MONITOR" --once 2>/dev/null
  grep -q '^ollama_models_loaded{node="node-ci"} 2$' "$METRICS_FILE"
  [ "$(jq '.models | length' "$STATE_DIR/state.json")" -eq 2 ]
  [ "$(stat -c '%a' "$METRICS_FILE")" = "644" ]
}

@test "lê a configuração de um arquivo com --config" {
  serve ps_empty.json
  cat >"$BATS_TEST_TMPDIR/config.env" <<CFG
NODE_NAME=no-do-arquivo
CFG
  unset NODE_NAME
  "$MONITOR" --once --config "$BATS_TEST_TMPDIR/config.env" 2>/dev/null
  [[ "$(messages)" == *"no-do-arquivo"* ]]
}

@test "modo contínuo encerra na hora com SIGTERM" {
  serve ps_empty.json
  POLL_INTERVAL=60 "$MONITOR" 2>/dev/null &
  pid=$!
  sleep 1
  kill -TERM "$pid"
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$pid" 2>/dev/null
}
