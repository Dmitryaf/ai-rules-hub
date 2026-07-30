# Профиль: пользовательский продукт

Подключить:

- [`../rules/PRODUCT.md`](../rules/PRODUCT.md);
- [`../rules/ARCHITECTURE_AND_DATA.md`](../rules/ARCHITECTURE_AND_DATA.md);
- [`../rules/IMPLEMENTATION.md`](../rules/IMPLEMENTATION.md);
- [`../rules/QUALITY.md`](../rules/QUALITY.md);
- [`../rules/DOCUMENTATION.md`](../rules/DOCUMENTATION.md);
- [`../rules/GIT_AND_DELIVERY.md`](../rules/GIT_AND_DELIVERY.md).

## Дополнительные обязательства

- У проекта есть короткое описание проблемы, пользователя, основного цикла ценности и границ.
- Единица работы — законченный пользовательский vertical slice.
- Каждая версия имеет самостоятельный демонстрируемый результат.
- Backlog приоритизируется по безопасности, основному сценарию, частоте и цене ошибки.
- UI проверяется на loading/empty/error/not-found только для реально возможных состояний.
- Технология, инфраструктура и абстракция добавляются под текущий сценарий.
- Product, architecture, backlog и session context не подменяют друг друга.
- Документация имеет один индекс и маршрутизацию по типу задачи; чтение всей папки `docs/` не является обязательным стартом работы.

Рекомендуемые локальные документы: `docs/README.md`, `PRODUCT.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `PROJECT_KNOWLEDGE.md`. Создавать только те из них, которым есть отдельная роль в проекте.
