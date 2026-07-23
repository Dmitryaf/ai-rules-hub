# Синхронизация правил с проектами

Версия `0.1` реализует локальную pull-модель: команда запускается из checkout AI Rules Hub и копирует выбранный набор в managed-каталог целевого проекта.

## Файлы целевого проекта

```text
.ai-rules-hub.json       выбор topics, profiles и destination
.ai-rules-hub.lock.json  сгенерированный revision и SHA-256 managed-файлов
.ai-rules/               только синхронизируемые правила и профили
AGENTS.md                 локальная точка входа, sync её не перезаписывает
PROJECT_RULES.md          локальные правила, sync их не перезаписывает
RULESET.md                локальное описание композиции и исключений
```

## Граница владения

- Хаб владеет только файлами под `destination`, перечисленными в lock-файле.
- `AGENTS.md`, `PROJECT_RULES.md`, `RULESET.md` и продуктовые документы всегда принадлежат целевому проекту.
- Изменённый managed-файл не перезаписывается: plan показывает `conflict`, apply останавливается.
- Файл, удалённый из выбора, сохраняется в lock со статусом `orphan`; версия 0.1 не удаляет его автоматически.
- Новый профиль автоматически подключает свои тематические зависимости из [`catalog.json`](catalog.json).

## Первичное подключение

Из корня хаба:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/init-project-sync.ps1 `
  -ProjectRoot C:\path\to\project `
  -Profiles standard-product `
  -SeedProjectFiles
```

Команда создаёт `.ai-rules-hub.json` и, только если файлов ещё нет, копирует стартовые `AGENTS.md`, `RULESET.md` и `PROJECT_RULES.md`. Она не запускает apply автоматически.

Проверить план:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/sync-rules.ps1 `
  -ProjectRoot C:\path\to\project `
  -Mode Plan
```

Применить безопасные изменения:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/sync-rules.ps1 `
  -ProjectRoot C:\path\to\project `
  -Mode Apply
```

## Pinning

`source.revision: null` разрешает текущий checkout хаба и записывает фактический Git revision и dirty-state в lock. Для воспроизводимого обновления указать полный commit hash. Apply отклонит другой revision и dirty checkout.

До первого опубликованного commit хаба pinning недоступен; контроль обеспечивается SHA-256 каждого файла в lock. Для текстовых файлов переносы строк нормализуются перед расчётом, поэтому `LF` и `CRLF` не создают ложный конфликт.

## Состояния plan

- `add` — managed-файла ещё нет;
- `update` — source изменился, а локальная копия совпадает с предыдущим lock;
- `unchanged` — source и target совпадают;
- `conflict` — target изменён локально или появился без подтверждённого lock;
- `orphan` — ранее managed-файл больше не выбран;
- `orphan-modified` — исключённый из выбора файл также изменён локально.

Версия 0.1 сознательно не выполняет remote fetch, массовое обновление проектов, merge конфликтов и автоматическое удаление orphan-файлов.
