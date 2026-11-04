PREFIX ?= /usr/local
CONFIG_DIR ?= /etc/ollama-node-monitor
UNIT_DIR ?= /etc/systemd/system
BATS ?= bats

.PHONY: help install uninstall lint test test-unit test-integration

help:
	@echo "make install      Instala o monitor, a configuração e o serviço systemd (requer root)"
	@echo "make uninstall    Remove o monitor e o serviço (mantém a configuração)"
	@echo "make lint         Roda o shellcheck"
	@echo "make test         Roda os testes (bats)"

install:
	install -Dm755 bin/ollama-node-monitor $(DESTDIR)$(PREFIX)/bin/ollama-node-monitor
	install -dm750 $(DESTDIR)$(CONFIG_DIR)
	@if [ ! -f $(DESTDIR)$(CONFIG_DIR)/config.env ]; then \
		install -m600 config.env.example $(DESTDIR)$(CONFIG_DIR)/config.env; \
		echo "Configuração criada em $(CONFIG_DIR)/config.env: preencha o token e o chat do Telegram."; \
	else \
		echo "Configuração existente mantida em $(CONFIG_DIR)/config.env."; \
	fi
	install -Dm644 deploy/systemd/ollama-node-monitor.service $(DESTDIR)$(UNIT_DIR)/ollama-node-monitor.service
	@echo "Pronto. Ative com: systemctl daemon-reload && systemctl enable --now ollama-node-monitor"

uninstall:
	-systemctl disable --now ollama-node-monitor 2>/dev/null
	rm -f $(DESTDIR)$(PREFIX)/bin/ollama-node-monitor $(DESTDIR)$(UNIT_DIR)/ollama-node-monitor.service
	@echo "Removido. A configuração em $(CONFIG_DIR) foi mantida."

lint:
	shellcheck -x -P SCRIPTDIR bin/ollama-node-monitor tests/*.bats

test: test-unit test-integration

test-unit:
	$(BATS) tests/unit.bats

test-integration:
	$(BATS) tests/integration.bats
