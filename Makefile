SHELL := /bin/bash
SOURCES := $(sort $(wildcard src/*.sh))
PROMPTS := $(wildcard prompts/*.md)
SKILLS := $(wildcard skills/*/SKILL.md)
TARGET := claude-compose

.PHONY: clean lint

$(TARGET): $(SOURCES) $(PROMPTS) $(SKILLS)
	@echo "Building $(TARGET)..."
	@cat $(SOURCES) > $@.tmp
	@while IFS= read -r line; do \
		case "$$line" in \
			*__PROMPT_COMPOSE_SYSTEM__*) cat prompts/compose-system.md ;; \
			*__PROMPT_COMPOSE_CONFIG__*) cat prompts/compose-config.md ;; \
			*__PROMPT_COMPOSE_INSTRUCTIONS__*) cat prompts/compose-instructions.md ;; \
			*__PROMPT_COMPOSE_FIX__*) cat prompts/compose-fix.md ;; \
			*__EMBEDDED_SKILLS__*) \
				echo 'extract_embedded_skills() {'; \
				echo '    local dest="$$1"'; \
				for skill_md in skills/*/SKILL.md; do \
					[ -f "$$skill_md" ] || continue; \
					skill_name=$$(basename $$(dirname "$$skill_md")); \
					skill_b64=$$(base64 < "$$skill_md" | tr -d '\n'); \
					echo "    mkdir -p \"\$$dest/$$skill_name\""; \
					echo "    printf '%s' \"$$skill_b64\" | base64 --decode > \"\$$dest/$$skill_name/SKILL.md\""; \
				done; \
				echo '}' ;; \
			*) printf '%s\n' "$$line" ;; \
		esac; \
	done < $@.tmp > $@
	@rm -f $@.tmp
	@chmod +x $@
	@echo "Done: $(TARGET) ($$(wc -l < $@) lines)"

clean:
	rm -f $(TARGET) $(TARGET).tmp

lint: $(TARGET)
	shellcheck $(TARGET)
