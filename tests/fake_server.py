"""Servidor falso para os testes de integração: faz o papel do Ollama e da API do Telegram.

- GET /api/ps devolve o conteúdo do arquivo indicado em PS_FILE (503 se o arquivo não existir).
- POST /bot<token>/sendMessage grava o texto recebido, uma mensagem por linha (JSON), em MESSAGES_FILE.

Uso: python3 fake_server.py PORTA PS_FILE MESSAGES_FILE
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        ps_file = Path(self.server.ps_file)
        if self.path != "/api/ps" or not ps_file.exists():
            self.send_response(503)
            self.end_headers()
            return
        body = ps_file.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        form = parse_qs(self.rfile.read(length).decode())
        if not self.path.endswith("/sendMessage"):
            self.send_response(404)
            self.end_headers()
            return
        record = {"path": self.path, "chat_id": form.get("chat_id", [""])[0], "text": form.get("text", [""])[0]}
        with open(self.server.messages_file, "a", encoding="utf-8") as output:
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port, ps_file, messages_file = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    server = HTTPServer(("127.0.0.1", port), Handler)
    server.ps_file, server.messages_file = ps_file, messages_file
    server.serve_forever()
