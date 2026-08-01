# Подключение нового проекта

## Минимальный вариант

1. Инициализировать manifest через [`../scripts/init-project-sync.ps1`](../scripts/init-project-sync.ps1) либо создать его по [`../sync/project-manifest.example.json`](../sync/project-manifest.example.json).
2. Создать корневой [`AGENTS.md`](AGENTS.md), а [`RULESET.md`](RULESET.md) и [`PROJECT_RULES.md`](PROJECT_RULES.md) разместить в `.ai-rules/`; initializer добавляет каждый файл только при отсутствии.
3. Проверить sync plan и отдельно выполнить apply.
4. Добавить продуктовые и архитектурные документы, если они помогают текущей работе.
5. Заменить все placeholders; неизвестное оставить явно неизвестным.
6. Проверить, что ссылки из локального `AGENTS.md` работают внутри целевого репозитория.

Managed-правила находятся только в `.ai-rules/upstream/`; `.ai-rules/RULESET.md` и `.ai-rules/PROJECT_RULES.md` принадлежат проекту и не перезаписываются синхронизацией. Git submodule, remote fetch и автоматический rollout пока не используются.

## Рекомендуемый набор документов

| Шаблон | Когда нужен |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | всегда |
| [`RULESET.md`](RULESET.md) → `.ai-rules/RULESET.md` | всегда |
| [`PROJECT_RULES.md`](PROJECT_RULES.md) → `.ai-rules/PROJECT_RULES.md` | всегда |
| [`PROJECT_RULES.full.md`](PROJECT_RULES.full.md) | расширенная замена минимального project rules, когда реально нужны подробные источники истины и маршрутизация |
| [`PRODUCT.md`](PRODUCT.md) | пользовательский продукт |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | проект с устойчивыми техническими границами |
| [`PROJECT_KNOWLEDGE.md`](PROJECT_KNOWLEDGE.md) | длительный проект с частыми паузами/сессиями |
| [`SESSION_CONTEXT.md`](SESSION_CONTEXT.md) | активная незавершённая работа |
| [`DECISION.md`](DECISION.md) | значимое решение с альтернативами |
| [`RESEARCH.md`](RESEARCH.md) | spike, аудит, неизвестный API или evidence-driven выбор |

Не создавать все документы заранее. Каждый файл должен иметь владельца вопроса и реальную функцию.
