# Профиль: исследовательский проект

Подключить:

- [`../rules/RESEARCH_AND_EVIDENCE.md`](../rules/RESEARCH_AND_EVIDENCE.md);
- [`../rules/ARCHITECTURE_AND_DATA.md`](../rules/ARCHITECTURE_AND_DATA.md);
- [`../rules/PRODUCT.md`](../rules/PRODUCT.md);
- [`../rules/QUALITY.md`](../rules/QUALITY.md).

## Дополнительные обязательства

- Каждое исследование начинается с decision question, вариантов решения и stop rule.
- Research adapter собирает факты и не превращается незаметно в production recommendation rule.
- Runtime evidence хранит версию среды, контекст, фактические значения и unknown.
- Вывод ограничен исследованной версией, выборкой и сценарием.
- Сначала проверяется содержание решения, затем отдельно его удобство и продуктовая полезность.
- Для рекомендации используется простой comparator, если он возможен.
- Отложенные сигналы остаются debug evidence и не становятся пользовательскими функциями без нового решения.
- Фазовый документ фиксирует цель, входные evidence, exit criteria, результат и незакрытые проверки.

Рекомендуемые локальные документы: `RESEARCH_POLICY.md`, `ROADMAP.md`, `NOT_NOW.md`, фазовые отчёты.
