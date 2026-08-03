# AI Rules Hub

AI Rules Hub — локальный набор переносимых правил для разработки с AI-агентами. Хаб помогает выбрать общие правила, добавить специфику проекта и хранить воспроизводимый snapshot прямо в подключённом репозитории.

Хаб не является сервисом и не требует постоянного запуска. После применения правил проект работает автономно.

**Статус:** публичный проект ранней стадии. CLI и локальная синхронизация покрыты автономными проверками, но стабильный release и гарантии обратной совместимости пока не объявлены.

## Требования

- Git;
- Windows;
- Windows PowerShell 5.1 или PowerShell 7+ с доступным `powershell.exe`.

Зависимости и package manager не нужны. Все команды `ai-rules.ps1` ниже запускаются из корня checkout хаба; `-ProjectRoot` всегда указывает на подключаемый проект.

## Выбрать profiles и topics

Profile описывает устойчивое свойство проекта и всегда читается после CORE. Сочетание profiles не является наследованием: проект может выбрать несколько независимых усилений. `standard-product` обычно служит основой пользовательского приложения; `learning-project`, `public-repository` и `data-sensitive` часто добавляются к ней. `research-driven` может быть самостоятельным исследовательским прототипом или дополнением продукта. Это рекомендации, а не ограничения одиночных profiles.

| Сценарий                             | Profiles                                                  |
| ------------------------------------ | --------------------------------------------------------- |
| Обычное приложение                   | `standard-product`                                        |
| Учебное приложение                   | `standard-product + learning-project`                     |
| Публичное приложение                 | `standard-product + public-repository`                    |
| Публичный учебный проект             | `standard-product + learning-project + public-repository` |
| Приложение с чувствительными данными | `standard-product + data-sensitive`                       |
| Исследовательский прототип           | `research-driven`                                         |
| Продукт, зависящий от исследования   | `standard-product + research-driven`                      |

Topics выбираются отдельно для дополнительных классов задач, которые не выражены profiles, например `reliability-and-operations` для эксплуатационного риска.

## Установка

```powershell
git clone https://github.com/Dmitryaf/ai-rules-hub.git
Set-Location ai-rules-hub
.\ai-rules.ps1 doctor
```

`doctor` без `-ProjectRoot` проверяет сам хаб. CLI не выполняет `git pull` или `git fetch` автоматически.

## Три отдельных режима работы

### Подключение

Подключение меняет только локальный нормативный слой: `AGENTS.md`, `.ai-rules/manifest.json`, `.ai-rules/RULESET.md`, `.ai-rules/PROJECT_RULES.md`, `.ai-rules/lock.json` и `.ai-rules/upstream/**`. Проект изучается лишь настолько, насколько нужно для достоверного заполнения локальных правил. `README`, остальная документация, код, тесты, CI, `.gitignore`, лицензия, contribution/security policy и repository settings не меняются без отдельного разрешения.

### Проверка исходного состояния

Проверка исходного состояния — отдельная задача без изменений проекта. Она классифицирует выбранные требования как `satisfied`, `gap`, `not applicable` или `unknown` и возвращает отчёт; специальный формат отчёта и команда аудита пока не вводятся.

### Исправление разрывов

Исправление начинается только после того, как владелец выбрал конкретные разрывы и файлы, которые разрешено менять. Обнаруженное несоответствие не расширяет границы подключения или проверки исходного состояния.

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
   - корневой `AGENTS.md` — проверьте маршрутизацию CORE, выбранных profiles и task topics.

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

6. Просмотрите Git diff локального нормативного слоя и managed snapshot и зафиксируйте подключение обычным процессом проекта. Проверки или исправления остальной поверхности выполняйте только в отдельно согласованной задаче.

`init` ничего не применяет, не создаёт lock и не перезаписывает существующие `AGENTS.md`, `RULESET.md` или `PROJECT_RULES.md`. Перед первым `update -Apply` manifest намеренно остаётся без закреплённой revision.

## Подключить существующий проект

Порядок тот же, но задача остаётся подключением правил: локальные инструкции нужно объединить, а не заменить, а проблемы проекта — только зафиксировать.

1. Проверьте `git status` целевого проекта и сохраните несвязанные изменения.
2. Изучите существующие `AGENTS.md`, правила, документы и команды проверок только в объёме, нужном для заполнения локальных правил.
3. Выберите минимально нужные профили и темы через `list`.
4. Запустите `init` — существующие локальные файлы будут пропущены.
5. Перенесите маршруты из шаблона хаба в существующий `AGENTS.md`, сохранив проектные инструкции.
6. Заполните `.ai-rules/RULESET.md`: причины выбора, исключения и отложенные требования.
7. Заполните `.ai-rules/PROJECT_RULES.md` только спецификой проекта. Расширенный шаблон доступен в [`templates/PROJECT_RULES.full.md`](templates/PROJECT_RULES.full.md).
8. Запустите проектный `doctor` и просмотрите ошибки целостности подключения и предупреждения о placeholders; это не аудит соответствия всего проекта.
9. Запустите `status` и read-only `update`.
10. Убедитесь, что Plan содержит только ожидаемые правила и профили.
11. Выполните `update -Apply`.
12. Просмотрите diff локального нормативного слоя и managed snapshot перед его commit. Найденные разрывы проекта оставьте для отдельной проверки исходного состояния или задачи на исправление.

## Проверить подключение

```powershell
.\ai-rules.ps1 doctor -ProjectRoot C:\path\to\project
.\ai-rules.ps1 status -ProjectRoot C:\path\to\project
.\ai-rules.ps1 plan -ProjectRoot C:\path\to\project
```

- `doctor` выполняет read-only проверку целостности подключения: структуры, JSON, revision, маршрутов, placeholders и managed-состояния. `[WARN]` не делает команду ошибочной, `[ERROR]` возвращает ненулевой exit code. Успешный `doctor` не означает соответствие всего проекта выбранным правилам.
- `status` показывает профили, темы из manifest, итоговые темы с учётом профилей, состояние и следующую команду.
- `plan` проверяет revision, уже указанную в manifest. Для незакреплённого manifest это только предварительный Plan.

| State               | Значение                                   |
| ------------------- | ------------------------------------------ |
| `not-initialized`   | проект ещё не подключён                    |
| `unpinned`          | подготовлен, но revision не закреплена     |
| `synchronized`      | проект соответствует текущему checkout     |
| `update-available`  | checkout хаба является более новой версией |
| `checkout-older`    | checkout хаба старее проекта               |
| `checkout-diverged` | истории расходятся                         |
| `checkout-mismatch` | relation определить невозможно             |
| `inconsistent`      | подключение повреждено или незавершено     |

`update-available` означает именно подтверждённую Git ancestry более новую revision, а не любое несовпадение SHA. Для остальных mismatch-состояний следуйте отдельной подсказке `Next`, чтобы случайно не выполнить откат или переход на другую историю.

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

Read-only `update` разрешён из dirty checkout хаба, но такой preview строится по текущим рабочим файлам и не соответствует только показанному HEAD SHA. CLI выводит отдельное предупреждение; `update -Apply` остаётся заблокированным до сохранения или отмены изменений и повторного preview.

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
