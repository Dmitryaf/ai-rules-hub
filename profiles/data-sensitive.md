# Профиль: чувствительные данные

Подключить:

- [`../rules/SECURITY_AND_PRIVACY.md`](../rules/SECURITY_AND_PRIVACY.md);
- [`../rules/ARCHITECTURE_AND_DATA.md`](../rules/ARCHITECTURE_AND_DATA.md);
- [`../rules/QUALITY.md`](../rules/QUALITY.md);
- [`../rules/GIT_AND_DELIVERY.md`](../rules/GIT_AND_DELIVERY.md).

## Дополнительные обязательства

- Создать карту данных: категория, цель, источник, место хранения, доступ, срок и удаление.
- Явно различать local cache, server source, backup, export и publication snapshot.
- Не допускать внешних пользователей до проверки access isolation, полного удаления, backup/restore и incident procedure.
- Проверять миграции на старых данных и выполнять критичные замены атомарно.
- Отделять отсутствие ответа, явное пустое значение и ноль.
- Автоматические наблюдения содержат evidence, версию правила и ограничения интерпретации.
- Public model строится allowlist-проекцией и тестируется на отсутствие private-полей.
- Staging не содержит реальных production-данных и использует отдельные credentials.

Рекомендуемые локальные документы: `DATA_CONTRACT.md`, `DATA_GOVERNANCE.md`, `SECURITY.md`, `DELIVERY.md`.
