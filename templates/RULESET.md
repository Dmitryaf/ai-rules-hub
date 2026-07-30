# Набор правил проекта

## Зафиксированная версия

- Manifest: `.ai-rules/manifest.json`
- Lock: `.ai-rules/lock.json`
- Managed rules: `.ai-rules/upstream/`
- Источник baseline: `<путь или URL к AI Rules Hub>`
- Commit/version: `<значение source.revision из lock>`
- Дата принятия: `<YYYY-MM-DD>`

Manifest выбирает topics и profiles. Lock фиксирует фактически применённый revision и нормализованный SHA-256. Этот документ описывает только композицию и явные исключения; обычные правила конкретного проекта находятся в `.ai-rules/PROJECT_RULES.md`.

## Обязательный baseline

- `.ai-rules/upstream/CORE.md`

## Выбранные темы

- [ ] Product
- [ ] Architecture and data
- [ ] Implementation
- [ ] Quality
- [ ] Security and privacy
- [ ] Documentation
- [ ] Git and delivery
- [ ] AI collaboration
- [ ] Research and evidence
- [ ] Project study

Отмеченные темы должны совпадать с manifest и фактическим lock. Файлы тем находятся в `.ai-rules/upstream/rules/`:

- `<путь>`

## Исключённые общие правила

- `<ссылка на правило; соответствующее исключение ниже>`

## Выбранные профили

- `<профиль из manifest и причина выбора>`

## Правила обновления

- Сначала выполнить sync в режиме `Plan`.
- `conflict` разрешать вручную; не перезаписывать локальную копию автоматически.
- `orphan` не удалять без проверки входящих ссылок и локальных исключений.
- После `Apply` просмотреть diff `.ai-rules/upstream/` и `.ai-rules/lock.json`, затем обновить дату принятия.

## Явные исключения

### `<название>`

- Исходное правило: `<ссылка на конкретное общее правило>`
- Причина: `<почему>`
- Заменяющее поведение: `<что действует вместо него>`
- Область действия: `<где именно применяется исключение>`
