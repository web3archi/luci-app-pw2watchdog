# Инструкция для агента — проект openwrt-passwall2-watchdog

## Кто я и что мы делаем

Я — Alexey Pokrovskiy, IT-специалист. Мы разрабатываем LuCI-аддон для OpenWrt под названием **pw2watchdog** — watchdog и менеджер нод для PassWall2. Аддон автоматически переключает прокси-ноды по латентности, показывает статус в LuCI и имеет монитор реального состояния соединения.

**Репо:** https://github.com/web3archi/openwrt-passwall2-watchdog  
**Роутер:** `root@Shelter`, Asus RT-AX53U, MT7621, OpenWrt 23.05.5, адрес `192.168.206.1`  
**Workspace:** `/home/user/workspace/repo`

---

## Режим работы (читай внимательно)

### Репо — первично
Все актуальные версии файлов живут в `/home/user/workspace/repo`. Перед любой правкой — читай файл из репо через `read` или `bash`, не угадывай содержимое.

### Работаем строго пошагово
1. Анализ текущей реализации (читаем код)
2. Проектирование (обсуждаем с пользователем)
3. Минимально рискованная реализация
4. Проверка
5. Только потом следующий шаг

### Если нужны данные с роутера — спроси, жди
Не придумывай что там лежит. Дай команду, дождись вывода.

### Ничего не хардкодим
Все пути, имена, значения — через env/UCI. Нет исключений. Никаких названий конкретного железа (MT7621, RT-AX53U и т.д.) — только абстракции Weak/Medium/Powerful.

### Layered Robustness — главный архитектурный принцип (зафиксирован 10.06.2026)

**Ядро должно работать на любом OpenWrt + PassWall2 без угадывания. Всё специфичное — опционально, отключаемо, переопределяемо вручную.**

Семь правил:

1. **Никаких имён по умолчанию** — только из `env.static` (autodetect + UCI override). Если значение пустое — функция выключается с сообщением в logread/UI, не «угадывает».
2. **Любая «умная» фича** = UCI-секция с `enabled='0'` по умолчанию. Пользователь включает осознанно.
3. **Любая autodetect-функция** возвращает либо результат, либо пусто. Падать нельзя. UI показывает «не определено — введите вручную».
4. **Использовать только то, что есть в OpenWrt 23.05+ stock:** `ash` (POSIX), `awk`, `grep`, `sed`, `nft`, `jsonfilter`, `ubus`, `uci`, `curl`, `ping`, `wget`, `/proc/*`. Запрещено: `bash`, `setsid`, `nohup`, `ss`, `jq`, `bc`, `python`.
5. **Sing-box vs Xray vs другое** — никогда не предполагаем. Backend-specific фичи (DIVERT chain, transparent socket counter, ESTABLISHED count) — только opt-in.
6. **Если фича выключена** — соответствующий код не выполняется, jsonl не пишется, ресурсы не тратятся.
7. **Каждая опциональная фича в UI** показывает текущий статус автодетекта («Found: PSW2_DIVERT, counter visible» / «Not detected — disable or set manually»).

Применение к scoring (v0.4.0): core-сигналы (latency, proxy, stability, age) работают на любой системе. Backend-specific сигналы (iface_anomaly через PSW2_DIVERT counter, ESTABLISHED count через /proc/net/tcp) — opt-in модули с автодетектом и manual override.

### Деплой — строго в таком формате

Сначала `share_file` с файлом, потом команды. Файлы НЕ через curl из GitHub — только через `share_file`.

Команды давать по одной строке (сначала rm, потом nano — отдельно):

**Деплой JS-файла:**
```
rm /www/luci-static/resources/view/pw2watchdog/FILE.js && nano /www/luci-static/resources/view/pw2watchdog/FILE.js
```
```
rm -f /tmp/luci-indexcache && /etc/init.d/uhttpd restart
```

**Деплой скрипта:**
```
rm /usr/bin/FILE.sh && nano /usr/bin/FILE.sh
```
```
chmod +x /usr/bin/FILE.sh && /etc/init.d/pw2watchdog restart
```

**Деплой init.d:**
```
rm /etc/init.d/pw2watchdog && nano /etc/init.d/pw2watchdog
```
```
chmod +x /etc/init.d/pw2watchdog
```

Если несколько файлов — "все команды деплоя в одном сообщении".

### После изменений — всегда коммит и пуш
```bash
cd /home/user/workspace/repo && git add <файлы> && git commit -m "..." && git push origin master
```
с `api_credentials=["github"]`

### Язык общения — русский
Команды для роутера — без ssh (пользователь уже в терминале).

### GitHub доступен через коннектор
Не говори "нет доступа к GitHub" не проверив. Вызови `list_external_tools` с запросом "github" — там есть `github_mcp_direct`. Клон репо также лежит в `/home/user/workspace/repo`.

---

## Стратегическое решение (принято 10.06.2026)

**Эволюция текущей базы, не переписывание.**

Причины: код структурно чист — единая decision point в `run_once`, изолированные функции `choose_target → apply_fallback_policy → should_switch`. Новые требования (health-сигналы, trusted_fallback, killswitch) встраиваются хирургически. Rewrite 2000+ строк с nft-интеграцией и UCI-migration гарантирует регрессии в том что уже работает.

**Нельзя называть внутренние временные сущности в UCI/UI.** "Candidate node v0.4" — только рабочее имя. В финальный UCI/UI/README не попадает.

---

## Текущее состояние (v0.3.7, последний коммит `06630ee`)

### Задеплоено на роутере
- `pw2watchdog.sh` v0.3.7 — `_ip2int`, `_ip_in_cidr`, `DIRECT_IP_RANGES`, fix node lookup (type=Xray вместо type=nodes)
- `pw2watchdog-env.sh` — без изменений относительно репо
- `pw2watchdog-init` (`/etc/init.d/pw2watchdog`) — актуальный с case-защитой boot_delay
- `overview.js` — Monitor proxy connection блок над Device performance
- `settings.js` — поле `direct_ip_ranges` в Advanced
- `help.js` — полная документация монитора
- Симлинк: `ln -sf /var/run/pw2watchdog /www/pw2data`
- Виджет: `/www/pw2widget.html` (в репо не вносим — личный инструмент)

### Только в репо, ещё не деплоили
- `README.md` — обновлён (docs-коммиты), на роутере не нужен

---

## Структура проекта

```
repo/
  root/
    usr/bin/
      pw2watchdog.sh          — главный watchdog daemon (1276 строк)
      pw2watchdog-env.sh      — env resolver, HW detection, nft helpers (474 строки)
      pw2watchdog-scanner.sh  — latency scanner (309 строк)
      pw2watchdog-subscribe.sh — subscription updater
  luasrc/view/pw2watchdog/
      overview.js             — главная страница LuCI
      nodes.js                — страница нод
      settings.js             — настройки
      help.js                 — справка
  root/etc/init.d/pw2watchdog — init script
  README.md
```

## UCI структура (актуальная)
```
pw2watchdog.main: enabled, passwall_config, passwall_section, check_interval(180),
  timeout(4), max_latency(1500), min_switch_interval(600),
  latency_improvement_threshold(80), test_url, node_selection(auto),
  fallback_action(blackhole/direct/rotate_all), rotate_max_rounds(3),
  rotate_final_action(blackhole), candidate_node, exclude_node

pw2watchdog.advanced: init_script, test_script, nftable_name, nftchain_mangle,
  tmp_path, nftables_script, utils_script, fwmark, sub_auto_update(0),
  sub_update_time(04:00), sub_update_on_boot(0), sub_boot_delay(120),
  pw2_restart_on_failure(0), proxy_check_enabled(0), proxy_check_interval(120),
  proxy_check_url(https://api.ipify.org), direct_ip_ranges('')
```

## Критические детали

**PassWall2:**
- NFT таблица: `inet passwall2` (ДВА аргумента — никогда не квотировать в одну строку)
- Chain: `PSW2_MANGLE`, FWMARK: `0x50535732`
- `passwall2.rulenode.default_node` — активная нода

**КОНВЕНЦИЯ: `$PW2_NFTABLE_NAME` всегда без кавычек в nft-командах.**
Содержит два слова (`inet passwall2`) и обязано word-splitting в family+name. Пример в pw2watchdog.sh:
```sh
nft insert rule $PW2_NFTABLE_NAME "$PW2_NFTCHAIN_MANGLE" counter drop
```
Это единственное место где кавычки вокруг переменной ломают логику. shellcheck: `# shellcheck disable=SC2086`.

**Runtime файлы на роутере:**
- State: `/var/run/pw2watchdog/state`
- Status: `/var/run/pw2watchdog/status.json`
- History: `/var/run/pw2watchdog/history.jsonl`
- Cache: `/var/run/pw2watchdog/latency_cache.json`

**Диагностика:**
```sh
logread | grep pw2watchdog | grep -v scanner | tail -20
cat /var/run/pw2watchdog/status.json
cat /var/run/pw2watchdog/history.jsonl | tail -20
cat /var/run/pw2watchdog/state
```

---

## Backlog — ПОЛНЫЙ СПИСОК (актуален на 10.06.2026)

Это исчерпывающий список. Не выдумывай новых задач. Не называй задачи из этого списка "выполненными" без подтверждения от пользователя.

### Этап 3: Наблюдаемость (делаем первым)

**[П1] proxy_check в history.jsonl**
При каждом замере монитора писать `{ts, action:"proxy_check", state, ip, node_label}`.
Даст таймлайн: когда переключился current_node и когда монитор "догнал".

**[П2] Real connectivity check в watchdog**
Latency тест (cp.cloudflare.com) не обнаруживает "мёртвую" ноду — нода отвечает на ping но не проксирует. Инцидент 09.06: 6 минут FAILED без реакции watchdog.
Решение: curl через прокси + проверка exit IP внутри watchdog. N провалов подряд → форс-свитч.
Точка встраивания: `_check_proxy_connection` уже вызывается в `run_once`, нужно связать результат с `choose_target`.

**[П3] fail_streak / suspicion счётчик**
Считать сколько раз подряд нода дала плохой сигнал (latency=0 или proxy_check fail).
Хранить в state/status. Отображать в UI как health-индикатор (preview, без влияния на switch — сначала).

### Этап 4: Trusted fallback и ladder

**[П4] trusted_fallback_node**
Новое UCI-поле `pw2watchdog.main.trusted_fallback_node` — ID ноды PassWall2 (не label).
Decision ladder: candidates → refresh → trusted_fallback → terminal fallback.
В Settings: дропдаун из реальных нод PassWall2, отображает `Label — Protocol/Transport/Security`, сохраняет node ID.
В status.json: `trusted_fallback_node`, `trusted_fallback_label`, `trusted_fallback_valid`, `trusted_fallback_last_result`.

### Этап 5: Killswitch

**[П5] Real killswitch (killswitch_mode)**
Отделить от `fallback_action`. `killswitch_mode` — отдельная policy-подсистема.
Защита от direct leakage: на старте watchdog, во время переключений, при деградации, при падении PassWall2.
Реализация через nft/firewall — не через живой shell-процесс.
Если выбран `direct` как fallback — killswitch семантически несовместим (direct = допустимое поведение).
В Settings: отдельное поле `killswitch_mode`, независимое от `fallback_action`.

### Этап Robustness Audit (10.06.2026) — фиксы текущего кода

**[R1] init.d hardcoded nft table/chain** ✅ FIXED в v0.4.0-dev
start() и stop() напрямую дёргали `nft delete rule inet passwall2 PSW2_MANGLE`. Теперь через `cleanup_stale_blackhole` с чтением env.static; при отсутствии env.static — skip с logger note.

**[R2] find_fwmark fallback ищет `meta mark set 0x`** — специфично nft (не iptables-форкам PassWall). Не критично т.к. в advanced есть `fwmark` override. → документировать в help.

**[R3] find_nftchain_mangle регексп `PSW[0-9A-Z_]+MANGLE`** — захардкожен префикс `PSW` для PassWall2/PassWall. Для других форков может быть другое имя. Override в Settings есть. → документировать.

**[R4] iface signal через PSW2_DIVERT counter** (в работе для v0.4.0) — sing-box + transparent socket. На xray-backend может выглядеть иначе. → По умолчанию **выключен**. Auto-detect ищет «socket transparent» + «counter» в PSW-цепочках; не нашёл — выключает себя с UI-сообщением. UCI: `iface_chain_override`, `iface_counter_index`.

**[R5] ESTABLISHED count в proxy_check** (для v0.4.0) — использовать ТОЛЬКО `/proc/net/tcp` (везде есть), не `ss` (отсутствует на нашей сборке).

**[R6] env.sh комментарий про xray UDP dual-stack** — специфика xray. Документировать.

**[R7] jsonfilter** — есть в OpenWrt 22.03+. Зафиксировать минимум 23.05 в README.

**[R8] setsid отсутствует** на нашей сборке busybox. Урок: использовать `( cmd ) &` с редиректами и `disown 2>/dev/null`. Запретить `setsid`, `nohup` в guidelines.

### Этап Scoring v0.4.0 (в работе)

**[S1] Probabilistic score per node** с весами:
- Core mode: `0.45·latency + 0.40·proxy + 0.10·stability + 0.05·age`
- Если iface включён и автодетект ОК: `0.30·latency + 0.30·proxy + 0.25·iface + 0.10·stability + 0.05·age`
- Stability = success rate последних N=20 проверок (дешевле stdev/mean для MT7621).

**[S2] evaluate_decision** — каскад: critical_recover / preventive_better / relative_improvement / no_better_option / cooldown / recent_switch.

**[S3] Telemetry** — `scores.jsonl` (per-tick snapshot), `decisions.jsonl` (per-decision); ротация 10MB; CLI `pw2watchdog stats [--last 24h]`.

**[S4] UI** — Health scores на Overview (progress-bars + %), Settings секции с прогрессивным раскрытием (Включить → Кастомизировать).

**[S5] iface anomaly как opt-in модуль** — пилот данных собран на нашей сборке (PSW2_DIVERT counter, sing-box). Адаптивный baseline + anomaly streak. Только при `iface_anomaly_enabled=1` И успешном автодетекте/override.

### Этап 6: LuCI UI

**[П6] Overview — human-readable status page**
Убрать: отдельный `Current PassWall2 default node`, дубль current node, `Target node`, `Last target`, `Initial default node`, raw status JSON.
Добавить: current latency справа у current node, best candidate latency справа, last decision + reason в читаемом виде, recent events.
Footer кнопки Save/SaveApply/Reset отключить через `handleSave = null` и т.д.

**[П7] Nodes — human-readable + health preview**
Убрать raw section IDs из основного вида.
Добавить: Protocol, Transport, Security из UCI-метаданных.
Со временем: health-индикатор (healthy/suspect/cooldown/fail) — preview-only сначала.

**[П8] Settings — control plane**
Добавить: trusted_fallback_node (дропдаун), killswitch_mode.
Auto-detect direct IP — кнопка: стоп passwall2 → curl → старт → сохранить CIDR.

### Мелкие улучшения

**[П9] Auto-detect direct IP** (см. П8 — Settings)

**[П10] Exit IP vs inbound IP**
Ноды AEZA/CDN: exit IP ≠ inbound address. Монитор показывает proxy_ok без лейбла.
Возможное решение: ASN/org матчинг через ipinfo.io вместо точного IP.

**[П11] IPv6 поддержка в поиске нод монитора**
Текущий фильтр `*[!0-9.]*` пропускает только IPv4-адреса нод.

**[П12] History дедупликация**
Паттерн `repeated N times` для однотипных stay-записей. Лимит 200 → 1000.

**[П13] Force rotate by time**
Поле в Settings: максимальное время на одной ноде (N минут) → принудительная ротация.

**[П14] Select all / Clear all**
Скрыть кнопки в авто режиме в Nodes.

**[П15] Overview Device performance блок**
Показывать только в manual режиме.

---

## Что НЕ делаем

- Не хардкодим названия железа — только Weak/Medium/Powerful
- Не хардкодим пути и имена файлов — всё через env/UCI
- Не выдаём файлы через curl из GitHub — только через share_file
- Не реализуем фичи из backlog без явного запроса пользователя
- Не добавляем в backlog задачи которые уже решены
- Не называем "Candidate node v0.4" во внешнем интерфейсе — только временное рабочее имя
- Blackhole ≠ killswitch (задокументировано, это не баг — это разные сущности)
- Не используем в shell-коде: `bash`, `setsid`, `nohup`, `ss`, `jq`, `bc`, `python` — только то, что гарантированно есть в OpenWrt 23.05+ stock
- Не предполагаем backend (sing-box/xray) — backend-specific фичи только opt-in
