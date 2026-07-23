# Набор правил проекта

## Зафиксированная версия

- Manifest: `.ai-rules-hub.json`
- Lock: `.ai-rules-hub.lock.json`
- Managed rules: `.ai-rules/`
- Источник baseline: `<путь или URL к AI Rules Hub>`
- Commit/version: `<значение source.revision из lock>`
- Дата принятия: `<YYYY-MM-DD>`

Manifest выбирает topics и profiles. Lock фиксирует фактически применённый revision и нормализованный SHA-256; локальные исключения остаются только в этом документе и `PROJECT_RULES.md`.

## Обязательный baseline

- `.ai-rules/rules/CORE.md`

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

Отмеченные темы должны совпадать с manifest и фактическим lock:

- `<путь>`

## Выбранные профили

- `<профиль из manifest и причина выбора>`

## Правила обновления

- Сначала выполнить sync в режиме `Plan`.
- `conflict` разрешать вручную; не перезаписывать локальную копию автоматически.
- `orphan` не удалять без проверки входящих ссылок и локальных исключений.
- После `Apply` просмотреть diff целевого проекта и обновить дату принятия.

## Локальные источники истины

- Product: `<путь или не требуется>`
- Architecture: `<путь или не требуется>`
- Data contract: `<путь или не требуется>`
- Delivery: `<путь или не требуется>`
- Current knowledge/context: `<путь или не требуется>`

## Явные исключения

### `<название>`

- Общее правило: `<ссылка>`
- Локальное решение: `<что делаем иначе>`
- Причина: `<почему>`
- Риск и компенсация: `<как защищаемся>`
- Пересмотреть: `<событие, дата или never с объяснением>`
