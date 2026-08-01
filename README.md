# AI Rules Hub

AI Rules Hub — локальный набор переносимых правил для разработки с AI-агентами. Хаб помогает выбрать общие правила, добавить специфику проекта и хранить воспроизводимый snapshot прямо в подключённом репозитории.

Хаб не является сервисом и не требует постоянного запуска. После применения правил проект работает автономно.

**Статус:** публичный проект ранней стадии. CLI и локальная синхронизация покрыты автономными проверками, но стабильный release и гарантии обратной совместимости пока не объявлены.

## Требования

- Git;
- Windows;
- Windows PowerShell 5.1 или PowerShell 7+ с доступным `powershell.exe`.

Зависимости и package manager не нужны. Все команды `ai-rules.ps1` ниже запускаются из корня checkout хаба; `-ProjectRoot` всегда указывает на подключаемый проект.

## Установка

```powershell
git clone https://github.com/Dmitryaf/ai-rules-hub.git
Set-Location ai-rules-hub
.\ai-rules.ps1 doctor
```

`doctor` без `-ProjectRoot` проверяет сам хаб. CLI не выполняет `git pull` или `git fetch` автоматически.

## Подключить новый проект

1. Посмотрите доступные наборы:

   ```powershell
   .\ai-rules.ps1 list profiles
   .\ai-rules.ps1 list topics
   ```

2. Инициализируйте проект. Профиль задаёт готовый набор тем, а `-Topics` добавляет отдельные темы:

   ```powershell
   .\ai-rules.ps1 init `
     -ProjectRoot C:\path\to\project `
     -Profiles standard-product `
     -Topics security-and-privacy
   ```

3. Заполните созданные локальные документы:

   - `.ai-rules/RULESET.md` — причины выбора и явные исключения;
   - `.ai-rules/PROJECT_RULES.md` — назначение, границы, структура и проверки проекта;
   - корневой `AGENTS.md` — проверьте маршрутизацию правил.

4. Проверьте подключение и предварительный план:

   ```powershell
   .\ai-rules.ps1 doctor -ProjectRoot C:\path\to\project
   .\ai-rules.ps1 status -ProjectRoot C:\path\to\project
   .\ai-rules.ps1 update -ProjectRoot C:\path\to\project
   ```

5. После просмотра примените текущую версию хаба:

   ```powershell
   .\ai-rules.ps1 update -ProjectRoot C:\path\to\project -Apply
   ```

6. Просмотрите Git diff целевого проекта, выполните его проверки и зафиксируйте подключение обычным процессом проекта.

`init` ничего не применяет, не создаёт lock и не перезаписывает существующие `AGENTS.md`, `RULESET.md` или `PROJECT_RULES.md`. Перед первым `update -Apply` manifest намеренно остаётся без закреплённой revision.

## Подключить существующий проект

Порядок тот же, но локальные инструкции нужно именно объединить, а не заменить:

1. Проверьте `git status` целевого проекта и сохраните несвязанные изменения.
2. Изучите существующие `AGENTS.md`, правила, документы и команды проверок.
3. Выберите минимально нужные профили и темы через `list`.
4. Запустите `init` — существующие локальные файлы будут пропущены.
5. Перенесите маршруты из шаблона хаба в существующий `AGENTS.md`, сохранив проектные инструкции.
6. Заполните `.ai-rules/RULESET.md`: причины выбора, исключения и отложенные требования.
7. Заполните `.ai-rules/PROJECT_RULES.md` только спецификой проекта. Расширенный шаблон доступен в [`templates/PROJECT_RULES.full.md`](templates/PROJECT_RULES.full.md).
8. Запустите проектный `doctor` и устраните ошибки; предупреждения о незаполненных placeholders тоже следует просмотреть.
9. Запустите `status` и read-only `update`.
10. Убедитесь, что Plan содержит только ожидаемые правила и профили.
11. Выполните `update -Apply`.
12. Просмотрите diff и проверки целевого проекта перед его commit.

## Проверить подключение

```powershell
.\ai-rules.ps1 doctor -ProjectRoot C:\path\to\project
.\ai-rules.ps1 status -ProjectRoot C:\path\to\project
.\ai-rules.ps1 plan -ProjectRoot C:\path\to\project
```

- `doctor` выполняет read-only проверку структуры, JSON, revision, маршрутов, placeholders и managed-состояния. `[WARN]` не делает команду ошибочной, `[ERROR]` возвращает ненулевой exit code.
- `status` показывает профили, темы из manifest, итоговые темы с учётом профилей, состояние и следующую команду.
- `plan` проверяет revision, уже указанную в manifest. Для незакреплённого manifest это только предварительный Plan.

## Обновить правила проекта

Сначала просмотрите переход на текущий commit checkout хаба:

```powershell
.\ai-rules.ps1 update -ProjectRoot C:\path\to\project
```

Затем примените его:

```powershell
.\ai-rules.ps1 update -ProjectRoot C:\path\to\project -Apply
```

Вариант с `-Apply` требует чистого рабочего дерева хаба, записывает полный commit SHA в manifest и обновляет managed snapshot. Обычный `apply` предназначен только для повторного применения уже закреплённой revision:

```powershell
.\ai-rules.ps1 apply -ProjectRoot C:\path\to\project
```

Если manifest ещё не закреплён, `apply` остановится и направит к `update -Apply`.

## Изменить набор правил проекта

Команды `configure` пока нет, поэтому выбор меняется явно:

1. отредактируйте массивы `profiles` и `topics` в `.ai-rules/manifest.json`;
2. синхронно обновите человеческие причины и исключения в `.ai-rules/RULESET.md`;
3. выполните `doctor` и `plan`;
4. просмотрите `add`, `update`, `orphan` и `conflict`;
5. выполните `apply`, если revision уже закреплена, или `update -Apply` для перехода на текущую revision;
6. проверьте diff проекта.

Sync не удаляет orphan-файлы автоматически и не перезаписывает локально изменённый managed-файл.

## Получить новую версию хаба

Git обновляет сам checkout хаба, а CLI переносит выбранную revision в проект. Это две отдельные операции:

```powershell
git status --short
git pull --ff-only
.\ai-rules.ps1 doctor
.\ai-rules.ps1 update -ProjectRoot C:\path\to\project
.\ai-rules.ps1 update -ProjectRoot C:\path\to\project -Apply
```

Не выполняйте `pull`, если в хабе есть несохранённые изменения. CLI намеренно не обращается к сети и не считает получение новой версии разрешением применить её к проекту.

## Работать над самим хабом

Перед изменениями прочитайте [`AGENTS.md`](AGENTS.md), [`rules/CORE.md`](rules/CORE.md), [`hub/PROJECT_RULES.md`](hub/PROJECT_RULES.md), [`hub/ARCHITECTURE.md`](hub/ARCHITECTURE.md) и [`hub/COMMIT_RULES.md`](hub/COMMIT_RULES.md).

Основная проверка:

```powershell
.\ai-rules.ps1 doctor
```

Прямые проверки:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/check-hub.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test-tooling.ps1
git diff --check
git status --short
```

## Низкоуровневая архитектура

```text
AGENTS.md       правила работы над хабом
rules/          переносимый baseline и тематические правила
profiles/       готовые композиции тем
templates/      локальные документы проекта
hub/            архитектура и правила самого хаба
sync/           catalog, manifest/lock и sync-контракт
scripts/        initializer, sync и проверки
tests/          автономные тесты tooling
```

Подключённый проект хранит собственные файлы в `.ai-rules/`, но sync управляет только `.ai-rules/upstream/` и `.ai-rules/lock.json`. Manifest выбирает profiles/topics и revision; lock фиксирует точный состав и SHA-256. Подробный низкоуровневый контракт описан в [`sync/README.md`](sync/README.md), шаблоны — в [`templates/README.md`](templates/README.md), архитектурные границы — в [`hub/ARCHITECTURE.md`](hub/ARCHITECTURE.md).

## Ограничения

- Поддерживается локальный clone хаба без remote fetch из CLI.
- Массовое обновление проектов и автоматическое удаление orphan-файлов не поддерживаются.
- Пользовательские `AGENTS.md`, `.ai-rules/RULESET.md` и `.ai-rules/PROJECT_RULES.md` не являются managed snapshot.
- Старый корневой формат manifest/lock не мигрируется молча.
- Проверяемый контракт сейчас ограничен Windows.

## Участие, безопасность и лицензия

Правила участия: [`CONTRIBUTING.md`](CONTRIBUTING.md). Уязвимости сообщайте по [инструкции безопасности](.github/SECURITY.md). Не публикуйте секреты, личный или внутренний контекст и материалы без подтверждённого права распространения в issues, pull requests и comments.

Проект распространяется по [MIT License](LICENSE).
