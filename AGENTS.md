# Правила работы агента

Перед изменениями прочитай:

1. [`rules/CORE.md`](rules/CORE.md) — обязательный baseline;
2. [`hub/PROJECT_RULES.md`](hub/PROJECT_RULES.md) — правила именно этого хаба;
3. [`hub/ARCHITECTURE.md`](hub/ARCHITECTURE.md) — границы нормативных правил, профилей, шаблонов и provenance;
4. [`hub/COMMIT_RULES.md`](hub/COMMIT_RULES.md) — формат и границы коммитов;
5. релевантные тематические документы из [`rules/README.md`](rules/README.md).

Полные документы проектов-источников не хранятся в хабе. При повторном аудите подключай канонический проект read-only и обновляй [`hub/SOURCE_PROVENANCE.md`](hub/SOURCE_PROVENANCE.md), не копируя сырой dump без отдельного решения.

Для средней или большой задачи веди короткий план с одним активным пунктом. Сначала проверь `git status`, сохрани чужие изменения и отдели изменение правил от реорганизации источников.

После изменения структуры, ссылок или состава источников выполни:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/check-hub.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test-tooling.ps1
git diff --check
git status --short
```

Не выполняй commit, push, публикацию, переписывание истории или удаление данных без отдельного явного разрешения пользователя.
