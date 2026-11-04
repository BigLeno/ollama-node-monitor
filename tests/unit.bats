#!/usr/bin/env bats
# Testes das funções do monitor, sem rede: http_get e send_telegram são substituídas.

setup() {
  # shellcheck source=../bin/ollama-node-monitor
  source "$BATS_TEST_DIRNAME/../bin/ollama-node-monitor"
  # O script liga nounset; o bats precisa dele desligado. errexit continua ligado,
  # que é o que faz cada asserção no meio do teste falhar de verdade.
  set +u
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export STATE_DIR="$BATS_TEST_TMPDIR/state"
  export METRICS_FILE="$BATS_TEST_TMPDIR/metrics/ollama.prom"
  export NODE_NAME="gpu-01"
  export PROXMOX_CTID=""
  export TELEGRAM_BOT_TOKEN="123:abc"
  export TELEGRAM_CHAT_ID="42"
  load_defaults
  SENT="$BATS_TEST_TMPDIR/sent.log"
  : >"$SENT"
  PS_FILE="$FIXTURES/ps_empty.json"
  http_get() { [[ -n "$PS_FILE" ]] && cat "$PS_FILE"; }
  send_telegram() { printf '%s\n---\n' "$1" >>"$SENT"; }
  sleep() { :; }
}

# `! comando` no meio de um teste não falha no bats; esta função falha de verdade.
refute_grep() {
  if grep -q "$@"; then
    echo "não deveria encontrar: $1" >&2
    return 1
  fi
}

poll_with() {
  PS_FILE="$1"
  poll_once 2>/dev/null
}

@test "format_bytes usa unidades legíveis" {
  [ "$(format_bytes 512)" = "512 B" ]
  [ "$(format_bytes 1536)" = "1.5 KB" ]
  [ "$(format_bytes 3772002304)" = "3.5 GB" ]
}

@test "processor_split segue o formato do ollama ps" {
  [ "$(processor_split 100 100)" = "100% GPU" ]
  [ "$(processor_split 100 0)" = "100% CPU" ]
  [ "$(processor_split 6000000000 3600000000)" = "40%/60% CPU/GPU" ]
}

@test "html_escape protege nomes de modelo" {
  [ "$(html_escape 'a<b>&c')" = "a&lt;b&gt;&amp;c" ]
}

@test "normalize_models aceita a resposta da API e ordena por nome" {
  run normalize_models <"$FIXTURES/ps_two.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.name) | join(",")' <<<"$output")" = "llama3.2:3b,qwen2.5:7b" ]
  [ "$(jq -r '.[1].quantization' <<<"$output")" = "Q4_K_M" ]
}

@test "normalize_models falha com resposta inválida" {
  run normalize_models <<<"<html>erro</html>"
  [ "$status" -ne 0 ]
}

@test "primeira verificação manda só a mensagem de início" {
  poll_with "$FIXTURES/ps_llama.json"
  [ "$(grep -c -- '---' "$SENT")" -eq 1 ]
  grep -q "Monitor iniciado" "$SENT"
  grep -q "llama3.2:3b" "$SENT"
}

@test "avisa quando um modelo é carregado e quando é descarregado" {
  poll_with "$FIXTURES/ps_llama.json"
  : >"$SENT"
  poll_with "$FIXTURES/ps_two.json"
  grep -q "Modelo carregado" "$SENT"
  grep -q "qwen2.5:7b" "$SENT"
  grep -q "40%/60% CPU/GPU" "$SENT"
  refute_grep "llama3.2:3b" "$SENT"

  : >"$SENT"
  poll_with "$FIXTURES/ps_qwen.json"
  grep -q "Modelo descarregado" "$SENT"
  grep -q "llama3.2:3b" "$SENT"
  [ "$(grep -c -- '---' "$SENT")" -eq 1 ]
}

@test "sem mudança, não manda nada" {
  poll_with "$FIXTURES/ps_two.json"
  : >"$SENT"
  poll_with "$FIXTURES/ps_two.json"
  [ ! -s "$SENT" ]
}

@test "Ollama fora do ar: avisa uma vez, mantém os modelos e avisa a volta" {
  poll_with "$FIXTURES/ps_llama.json"
  : >"$SENT"
  poll_with ""
  poll_with ""
  [ "$(grep -c 'Ollama indisponível' "$SENT")" -eq 1 ]
  [ "$(jq -r '.models[0].name' "$STATE_DIR/state.json")" = "llama3.2:3b" ]

  : >"$SENT"
  poll_with "$FIXTURES/ps_llama.json"
  grep -q "voltou a responder" "$SENT"
  refute_grep "Modelo carregado" "$SENT"
}

@test "NOTIFY_API_DOWN=false silencia os avisos de indisponibilidade" {
  NOTIFY_API_DOWN=false
  poll_with "$FIXTURES/ps_llama.json"
  : >"$SENT"
  poll_with ""
  [ ! -s "$SENT" ]
}

@test "sem Telegram configurado, só registra no log" {
  TELEGRAM_BOT_TOKEN=""
  TELEGRAM_CHAT_ID=""
  run poll_once
  [ "$status" -eq 0 ]
  [[ "$output" == *"Monitor iniciado"* ]]
  [ ! -s "$SENT" ]
}

@test "falha no Telegram não interrompe o monitor" {
  send_telegram() { return 1; }
  run poll_once
  [ "$status" -eq 0 ]
  [[ "$output" == *"Mensagem não enviada"* ]]
  [ -f "$STATE_DIR/state.json" ]
}

@test "estado corrompido é tratado como primeira execução" {
  mkdir -p "$STATE_DIR"
  echo "lixo" >"$STATE_DIR/state.json"
  poll_with "$FIXTURES/ps_llama.json"
  grep -q "Monitor iniciado" "$SENT"
}

@test "métricas no formato do Prometheus" {
  poll_with "$FIXTURES/ps_two.json"
  grep -q '^ollama_up{node="gpu-01"} 1$' "$METRICS_FILE"
  grep -q '^ollama_models_loaded{node="gpu-01"} 2$' "$METRICS_FILE"
  grep -q '^ollama_model_vram_bytes{node="gpu-01",model="qwen2.5:7b"} 3600000000$' "$METRICS_FILE"
  grep -q '^# TYPE ollama_model_size_bytes gauge$' "$METRICS_FILE"

  poll_with ""
  grep -q '^ollama_up{node="gpu-01"} 0$' "$METRICS_FILE"
  refute_grep 'ollama_model_size_bytes{' "$METRICS_FILE"
}

@test "rótulos das métricas escapam aspas e barras" {
  [ "$(prometheus_label 'a"b\c')" = 'a\"b\\c' ]
}

@test "nome do Proxmox aparece quando há CTID" {
  PROXMOX_CTID=105
  [ "$(node_label)" = "gpu-01 (CT 105)" ]
}

@test "detect_proxmox_ctid não quebra fora do Proxmox" {
  findmnt() { return 1; }
  run detect_proxmox_ctid
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_proxmox_ctid extrai o CTID do volume raiz" {
  findmnt() { echo "rpool/data/subvol-105-disk-0"; }
  [ "$(detect_proxmox_ctid)" = "105" ]
}

@test "validação de configuração" {
  run bash -c "POLL_INTERVAL=0 '$BATS_TEST_DIRNAME/../bin/ollama-node-monitor' --once"
  [ "$status" -ne 0 ]
  [[ "$output" == *"POLL_INTERVAL"* ]]
  run bash -c "TELEGRAM_BOT_TOKEN=x TELEGRAM_CHAT_ID= '$BATS_TEST_DIRNAME/../bin/ollama-node-monitor' --once"
  [ "$status" -ne 0 ]
  [[ "$output" == *"juntos"* ]]
}

@test "--help e --version" {
  run "$BATS_TEST_DIRNAME/../bin/ollama-node-monitor" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--once"* ]]
  run "$BATS_TEST_DIRNAME/../bin/ollama-node-monitor" --version
  [[ "$output" == "ollama-node-monitor "* ]]
}
