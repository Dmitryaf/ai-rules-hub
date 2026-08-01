# AI Rules Hub

AI Rules Hub — база переносимых правил для разработки и сопровождения проектов с участием AI-агентов.

AI Rules Hub не является сервисом и не требует постоянного запуска. Это локальный источник правил, шаблонов и обновлений для других проектов. После применения выбранный snapshot хранится в проекте и доступен автономно.

**Статус:** публичный проект ранней стадии. Структура правил и локальная синхронизация реализованы и покрыты автономными проверками, но пилотные подключения внешних проектов ещё не подтверждены как стабильный контракт.

Хаб решает две задачи:

1. хранит небольшой обязательный baseline, пригодный для большинства репозиториев;
2. позволяет собирать проектный набор из тематических правил, профилей и локальных исключений.

Нормативными для подключённого проекта являются документы в [`rules/`](rules/README.md), явно выбранные профили и собственные локальные правила проекта.

## Подключить новый проект

Посмотреть доступные профили и создать manifest с минимальными локальными файлами:

```powershell
.\ai-rules.ps1 list profiles
.\ai-rules.ps1 list topics
.\ai-rules.ps1 init `
  -ProjectRoot C:\path\to\project `
  -Profiles standard-product
```

`init` не выполняет Apply. По умолчанию он создаёт manifest, корневой `AGENTS.md`, `.ai-rules/RULESET.md` и минимальный `.ai-rules/PROJECT_RULES.md`, не перезаписывая существующие локальные файлы. Расширенный проектный шаблон доступен в [`templates/PROJECT_RULES.full.md`](templates/PROJECT_RULES.full.md).

## Проверить состояние проекта

```powershell
.\ai-rules.ps1 status -ProjectRoot C:\path\to\project
.\ai-rules.ps1 plan -ProjectRoot C:\path\to\project
```

`status` показывает manifest, lock, managed-каталог, revision и итоговое состояние подключения. `plan` строит подробный read-only план для revision, уже зафиксированной в manifest.

## Обновить правила проекта

Применение revision, уже указанной в manifest:

```powershell
.\ai-rules.ps1 apply -ProjectRoot C:\path\to\project
```

Переход на текущий commit checkout хаба:

```powershell
.\ai-rules.ps1 update -ProjectRoot C:\path\to\project
.\ai-rules.ps1 update -ProjectRoot C:\path\to\project -Apply
```

После `init` manifest остаётся unpinned; для воспроизводимого первого принятия используй `update -Apply`. `update` без `-Apply` только показывает целевую revision и Plan. Вариант с `-Apply` требует чистый checkout хаба, записывает полный SHA и вызывает обычный безопасный Apply. Ни одна команда не выполняет `git pull` или `git fetch` автоматически.

## Проверить или изменить сам хаб

Перед изменениями прочитайте [`AGENTS.md`](AGENTS.md) и [`hub/PROJECT_RULES.md`](hub/PROJECT_RULES.md). Полная проверка хаба запускается одной командой:

```powershell
.\ai-rules.ps1 doctor
```

Архитектура описана в [`hub/ARCHITECTURE.md`](hub/ARCHITECTURE.md), отложенные направления — в [`hub/BACKLOG.md`](hub/BACKLOG.md).

## Требования

- Git;
- Windows;
- Windows PowerShell 5.1 или PowerShell 7+ с доступным `powershell.exe` для текущих скриптов и тестов.

Внешние package managers и установка зависимостей не требуются.

## Проверка хаба после клонирования

```powershell
git clone https://github.com/Dmitryaf/ai-rules-hub.git
Set-Location ai-rules-hub
.\ai-rules.ps1 doctor
```

Прямые вызовы проверок также поддерживаются и перечислены ниже. По умолчанию синхронизация работает в read-only режиме `Plan`.

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

Остальное становится профилем, шаблоном или локальным правилом конкретного проекта.

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
Не публикуйте секреты, личный или внутренний контекст и материалы без подтверждённого права распространения в issues, pull requests и comments.

## Лицензия

Проект распространяется по [MIT License](LICENSE). Правила и tooling можно использовать в публичных и закрытых проектах при сохранении copyright и license notice.
