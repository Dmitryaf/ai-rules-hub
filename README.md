# AI Rules Hub

AI Rules Hub — база переносимых правил для разработки и сопровождения проектов с участием AI-агентов.

**Статус:** публичный проект ранней стадии. Структура правил и локальная синхронизация реализованы и покрыты автономными проверками, но пилотные подключения внешних проектов ещё не подтверждены как стабильный контракт.

Хаб решает две задачи:

1. хранит небольшой обязательный baseline, пригодный для большинства репозиториев;
2. позволяет собирать проектный набор из тематических правил, профилей и локальных исключений.

Хаб создан на основе документации трёх реальных проектов, но не хранит её полные копии. Нормативными для новых проектов считаются только документы в [`rules/`](rules/README.md), явно выбранные профили и собственные правила целевого проекта.

## С чего начать

- Для работы над самим хабом: [`AGENTS.md`](AGENTS.md) и [`hub/PROJECT_RULES.md`](hub/PROJECT_RULES.md).
- Для подключения нового проекта: [`templates/README.md`](templates/README.md).
- Для выбора готового набора: [`profiles/README.md`](profiles/README.md).
- Для синхронизации принятого набора: [`sync/README.md`](sync/README.md).
- Для понимания происхождения правил: [`hub/SOURCE_PROVENANCE.md`](hub/SOURCE_PROVENANCE.md).
- Для отложенных направлений после пилотных подключений: [`hub/BACKLOG.md`](hub/BACKLOG.md).

## Требования

- Git;
- Windows;
- Windows PowerShell 5.1 или PowerShell 7+ с доступным `powershell.exe` для текущих скриптов и тестов.

Внешние package managers и установка зависимостей не требуются.

## Quick Start из чистого clone

```powershell
git clone https://github.com/Dmitryaf/ai-rules-hub.git
Set-Location ai-rules-hub
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/check-hub.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test-tooling.ps1
```

После успешной проверки выберите профиль в [`profiles/README.md`](profiles/README.md), изучите [`templates/README.md`](templates/README.md) и выполните первичную настройку по [`sync/README.md`](sync/README.md). По умолчанию синхронизация работает в read-only режиме `Plan`.

## Структура

```text
AGENTS.md                  краткая точка входа для агента этого репозитория
rules/                     переносимые правила
profiles/                  готовые тематические надстройки
templates/                 шаблоны локальных документов проекта
hub/                       правила и архитектура самого хаба
scripts/                   проверки целостности хаба
sync/                      manifest, catalog и контракт синхронизации
tests/                     автономные проверки tooling без зависимостей
```

## Модель подключения

В новом проекте действуют четыре слоя, от общего к частному:

```text
универсальный baseline
→ выбранные тематические правила
→ выбранные профили
→ локальные `.ai-rules/PROJECT_RULES.md` и явно записанные исключения проекта
```

Локальное правило уточняет общий default, но не должно молча ослаблять безопасность, приватность, достоверность данных или требование явного разрешения на необратимые операции.

## Принцип отбора

Правило переносится в baseline только если оно:

- применимо более чем к одному типу проекта;
- описывает наблюдаемое поведение или проверяемое ограничение;
- не зависит от конкретного домена, стека или временного состояния;
- достаточно важно, чтобы оправдать постоянную стоимость чтения и поддержки.

Остальное становится профилем, шаблоном, кратким provenance либо остаётся только в каноническом проекте.

## Проверка

Из PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/check-hub.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test-tooling.ps1
git diff --check
git status --short
```

Скрипт проверяет обязательные документы, локальные Markdown-ссылки, sync-каталог и формат текстовых файлов.

## Коммиты и синхронизация

Формат коммитов и допустимые scopes описаны в [`hub/COMMIT_RULES.md`](hub/COMMIT_RULES.md). Локальный `commit-msg` hook устанавливается явно:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/install-git-hooks.ps1
```

Синхронизация использует `.ai-rules/manifest.json`, `.ai-rules/lock.json` и режимы `Plan`/`Apply`. Она управляет только `.ai-rules/upstream/`, не перезаписывает локальные проектные правила и не удаляет orphan-файлы автоматически.

## Ограничения

- Синхронизация использует локальный clone хаба и не выполняет remote fetch.
- Массовое обновление проектов и автоматическое удаление orphan-файлов не поддерживаются.
- Пользовательские `AGENTS.md`, `.ai-rules/RULESET.md` и `.ai-rules/PROJECT_RULES.md` не являются managed snapshot.
- Старый корневой формат manifest/lock не мигрируется молча.
- Поддержка Windows является текущим проверяемым контрактом; другие платформы не заявлены.
- Стабильный release и гарантии обратной совместимости пока не объявлены.

## Участие и безопасность

- Правила участия: [`CONTRIBUTING.md`](CONTRIBUTING.md).
- Сообщение об уязвимости: [`.github/SECURITY.md`](.github/SECURITY.md).
- Происхождение обобщённых правил: [`hub/SOURCE_PROVENANCE.md`](hub/SOURCE_PROVENANCE.md).

Не публикуйте секреты, приватный context или сырые документы других проектов в issues, pull requests и comments.

## Лицензия

Проект распространяется по [MIT License](LICENSE). Правила и tooling можно использовать в публичных и закрытых проектах при сохранении copyright и license notice.
