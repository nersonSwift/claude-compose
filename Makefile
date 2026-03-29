SHELL := /bin/bash
SOURCES := $(sort $(wildcard src/*.sh))
PROMPTS := $(wildcard prompts/*.md)
PLUGIN_FILES := $(shell find plugin -type f -not -name '.DS_Store' 2>/dev/null)
TARGET := claude-compose
WRAPPER := claude-compose-wrapper

.PHONY: clean lint

$(TARGET): $(SOURCES) $(PROMPTS) $(PLUGIN_FILES)
	@echo "Building $(TARGET)..."
	@cat $(SOURCES) > $@.tmp
	@while IFS= read -r line; do \
		case "$$line" in \
			*__PROMPT_COMPOSE_SYSTEM__*) cat prompts/compose-system.md ;; \
			*__PROMPT_COMPOSE_CONFIG__*) cat prompts/compose-config.md ;; \
			*__PROMPT_COMPOSE_INSTRUCTIONS__*) cat prompts/compose-instructions.md ;; \
			*__PROMPT_COMPOSE_DOCTOR__*) cat prompts/compose-doctor.md ;; \
			*__PROMPT_COMPOSE_START__*) cat prompts/compose-start.md ;; \
		*__PROMPT_COMPOSE_KNOWLEDGE__*) cat prompts/compose-knowledge.md ;; \
			*__EMBEDDED_PLUGIN__*) \
				echo 'extract_embedded_plugin() {'; \
				echo '    local dest="$$1"'; \
				for pfile in $$(find plugin -type f -not -name '.DS_Store'); do \
					rel_path=$${pfile#plugin/}; \
					rel_dir=$$(dirname "$$rel_path"); \
					file_b64=$$(base64 < "$$pfile" | tr -d '\n'); \
					[ "$$rel_dir" != "." ] && echo "    mkdir -p \"\$$dest/$$rel_dir\""; \
					echo "    printf '%s' \"$$file_b64\" | base64 -d > \"\$$dest/$$rel_path\""; \
				done; \
				echo '}' ;; \
			*) printf '%s\n' "$$line" ;; \
		esac; \
	done < $@.tmp > $@
	@rm -f $@.tmp
	@chmod +x $@
	@if git describe --exact-match --tags HEAD 2>/dev/null | grep -qE '^v[0-9]'; then \
		TAG_VER=$$(git describe --exact-match --tags HEAD 2>/dev/null | sed 's/^v//'); \
		sed -i.bak "s/^VERSION=\".*\"/VERSION=\"$$TAG_VER\"/" $@ && rm -f $@.bak; \
	fi
	@cp scripts/vscode-wrapper.sh $(WRAPPER)
	@chmod +x $(WRAPPER)
	@echo "Done: $(TARGET) ($$(wc -l < $@) lines)"

TEST_LIB := tests/test_helper/claude-compose-functions.sh

$(TEST_LIB): $(SOURCES) $(PROMPTS) $(PLUGIN_FILES)
	@echo "Building test library..."
	@mkdir -p tests/test_helper
	@cat $(SOURCES) > $@.tmp
	@while IFS= read -r line; do \
		case "$$line" in \
			*__PROMPT_*__*|*__EMBEDDED_PLUGIN__*) ;; \
			'main "$$@"') ;; \
			*) printf '%s\n' "$$line" ;; \
		esac; \
	done < $@.tmp > $@
	@rm -f $@.tmp

.PHONY: test test-unit test-integration

test: $(TARGET) $(TEST_LIB)
	@tests/lib/bats-core/bin/bats tests/unit/ tests/integration/

test-unit: $(TARGET) $(TEST_LIB)
	@tests/lib/bats-core/bin/bats tests/unit/

test-integration: $(TARGET) $(TEST_LIB)
	@tests/lib/bats-core/bin/bats tests/integration/

clean:
	rm -f $(TARGET) $(TARGET).tmp $(WRAPPER) $(TEST_LIB)

lint: $(TARGET)
	shellcheck $(TARGET)
