# Профиль: публичный репозиторий

Подключить:

- [`../rules/SECURITY_AND_PRIVACY.md`](../rules/SECURITY_AND_PRIVACY.md);
- [`../rules/DOCUMENTATION.md`](../rules/DOCUMENTATION.md);
- [`../rules/GIT_AND_DELIVERY.md`](../rules/GIT_AND_DELIVERY.md).

## Дополнительные обязательства

- Публичные и внутренние документы имеют явную границу и не ссылаются друг на друга после публикации.
- README описывает фактический продукт, запуск, ограничения и безопасные публичные evidence.
- Demo/fixtures обезличены и проходят отдельный review.
- Перед открытием проверяются tracked files, вся достижимая history, artifacts, issues, releases и deployments.
- Удалённые из публичной истории внутренние файлы восстанавливаются только как локальные ignored-копии.
- История переписывается только по точному плану, с backup и отдельным разрешением.
- После очистки проверяются `git ls-files`, история путей и reachable objects.
- Публичные утверждения о масштабе, пользователях и результате имеют evidence.

Рекомендуемые локальные документы: `PUBLIC_REPOSITORY.md`, `SECURITY.md`, публичный `README.md` и private publication checklist.
