# agent-sync (шаблон проекта)

Русский текст — этот файл. English: [README.md](README.md).

Держит конфиги, правила, скиллы, хуки и память AI-агентов (сначала Claude Code) одинаковыми на всех машинах через **приватный** git-репозиторий. В комплекте постоянные агенты-роли (review, developer, QA, DevOps, DB, logs, PM, cleaner, docs): они переписываются через панели [herdr](https://herdr.dev). Рядом лежат помощники для worktree, истории сессий и сообщений между машинами.

License: MIT, see LICENSE; skills/init is MIT by Matteo Collina, see NOTICE.

В шаблоне нет личных данных. `init` подставляет имя проекта, пути и организацию GitHub. После этого клон — ваш `~/.agent-sync`, и в нём окажутся ваши правила, планы и та память, которую вы сами включите. `history-sync` может отправить транскрипты всех проектов на машине.

## Репозиторий должен оставаться приватным

После `init` в репозитории лежат ваши правила, скиллы, планы и память по проектам. Публичный remote отдаёт это любому, кто может клонировать. Создайте remote как **private** до первого push и оставьте его приватным.

Где может жить git:

| Где | Когда |
|---|---|
| Приватный репозиторий на GitHub | нужен GitHub как remote синхронизации или запасная копия |
| Bare-репозиторий на диске или на SSH-хосте, который вы контролируете | данные не должны попадать на GitHub |

`SYNC_SERVER` (необязательно) — это другое: SSH-алиас только для транскриптов сессий. Git-remote у `~/.agent-sync` синхронизирует конфиги. Это может быть одна машина. Это могут быть разные машины.

## Требования

| Система | Статус | Что нужно |
|---|---|---|
| Linux | поддерживается | bash 4+, GNU coreutils, git; пользовательский systemd для таймеров |
| macOS 12.3+ | поддерживается, кроме `standctl` | [Homebrew](https://brew.sh) и `brew install bash coreutils gnu-sed findutils`; задачи запускает launchd |
| Windows | только внутри WSL2 | дистрибутив WSL2 (например Ubuntu) с включённым systemd. Обычная Windows (PowerShell, Git Bash) не поддерживается |

Скрипты написаны на bash и используют GNU-утилиты (`date -d`, `stat -c`, `sed -i`). На macOS `bin/lib/compat.sh` ставит GNU-утилиты Homebrew первыми в `PATH` и перезапускает скрипт под bash из Homebrew, если его запустил `/bin/bash` 3.2. Если их нет, скрипт останавливается и печатает строку `brew install`.

### Перед шагом 1

**Linux.** Ничего дополнительно. `bin/tools-check.sh` покажет, чего не хватает.

**macOS.**

```bash
# сначала Homebrew: https://brew.sh
brew install bash coreutils gnu-sed findutils git jq
```

Дальше по шагам ниже. На macOS `tools-check` читает `tools.macos.conf` (строки brew). `agent-sync timers` пишет агенты launchd в `~/Library/LaunchAgents/dev.agent-sync.*.plist`, их логи — в `~/Library/Logs/agent-sync/`. У launchd нет хука на выход из сессии, поэтому последние изменения отправляет синк раз в 5 минут. Только Linux и WSL: `tailcat-serve` и `standctl` из agent-devops (он использует `ss`, `/proc` и `setsid`).

Каждый plist хранит `PATH` той оболочки, из которой запустили `timers enable`. Если инструмент переехал (например, новый префикс Homebrew), запустите `agent-sync timers enable` ещё раз.

**Windows (WSL2).**

1. В PowerShell от администратора: `wsl --install -d Ubuntu`. Перезагрузитесь и создайте пользователя Linux.
2. В Ubuntu включите systemd:

   ```bash
   printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
   ```

   Затем `wsl --shutdown` в PowerShell и снова откройте Ubuntu. `systemctl --user status` должен отвечать.
3. Claude Code, herdr и остальные инструменты ставьте внутри Ubuntu, не в Windows.
4. `~/.agent-sync` и checkout'ы проекта держите в домашнем каталоге Linux (`/home/<вы>`), не в `/mnt/c`. На диске Windows плохо работают симлинки, права файлов и скорость.
5. Дальше по шагам для Linux. Таймеры работают, только пока запущен дистрибутив WSL.

**Несколько машин.** Возобновление сессии ищет транскрипты по абсолютному `PROJECT_ROOT`. Домашние каталоги на macOS — `/Users/<вы>`, на Linux и WSL — `/home/<вы>`. Синк конфигов между ними работает, а возобновление сессий — только между машинами с одинаковым путём `PROJECT_ROOT`.

## Что решить до начала

`init` один раз спрашивает эти значения и пишет их в `agent-sync.env`. Без значения по умолчанию только первые три.

| Значение | Флаг `init` | Обязательно | Пример | Примечание |
|---|---|---|---|---|
| Имя проекта | `--name` | да | `acme` | slug `[a-z0-9][a-z0-9_-]*`, входит в имена хуков и скиллов |
| Папка checkout'ов | `--root` | да | `/home/me/acme` | один и тот же путь на всех машинах, иначе возобновление сессий не работает |
| Язык чата | `--user-language` | да | `Polish` | язык длинных ответов в чате |
| Базовая ветка | `--base-branch` | лучше задать | `develop` или `main` | определяется сама, только если `--root` — один git checkout |
| Организация GitHub | `--org` | нет | по умолчанию — имя | для `gh` и ссылок на PR |
| Папка секретов | `--creds` | нет | по умолчанию `/home/me/acme-creds` | вне всех checkout'ов |
| Сервер истории | `--server` | нет | по умолчанию пусто | SSH-алиас; пусто — транскрипты остаются на этой машине |
| Репозиторий синка | (git remote) | да | `git@github.com:me/agent-sync.git` | обязательно **приватный** |

Необязательные функции настраиваются отдельно, каждая в своём разделе: сообщение в Telegram, когда агент ждёт (`~/.config/herdr-notify.env`, см. [Где лежат секреты](#где-лежат-секреты)), проверка страны внешнего IP (`GEO_ALLOWED`, см. [Хуки](#хуки)), сообщения между машинами (`~/.config/herdr-hosts.conf`, см. [Сообщения между машинами](#сообщения-между-машинами-необязательно)). Остальные переменные только подстраивают лимиты и таймауты, значения по умолчанию рабочие: [Переменные](#переменные-agent-syncenv).

## По шагам: первая машина

Пример проекта называется `acme`. Чекауты лежат в `/home/me/acme`. Remote у agent-sync — приватный.

### 1. Приватный GitHub

На странице шаблона в GitHub: **Use this template → Create a new repository** → владелец `me` → имя `agent-sync` → **Private**. Новый репозиторий начинается с одного коммита, без истории шаблона. Через `gh`: `gh repo create me/agent-sync --template <template-owner>/<template-repo> --private`.

```bash
git clone git@github.com:me/agent-sync.git ~/.agent-sync
cd ~/.agent-sync
bin/tools-check.sh            # отчёт
bin/tools-check.sh --install  # поставить то, что ставится без sudo (строки apt только печатаются)
bin/agent-sync.sh init \
  --name acme \
  --root /home/me/acme \
  --org acme \
  --server '' \
  --base-branch develop \
  --user-language Polish
git add -A && git commit -m "Render for acme"
git push
bin/agent-sync.sh install
```

`tools.conf` (на macOS `tools.macos.conf`): `команда :: установка :: зачем`. Отсутствующий OPTIONAL-инструмент показывается в списке и не считается ошибкой. Отсутствующий обязательный считается, и `tools-check.sh` завершается с кодом 1. Обязательны: `git`, `jq`, `claude`, `herdr`, `node`.

`git add -A` не коммитит `agent-sync.env`: файл в gitignore. В нём только пути, без секретов, и он остаётся на этой машине.

`git@github.com:me/agent-sync.git` — тот самый приватный репозиторий. Если начинаете с обычного `git clone` шаблона, создайте пустой приватный репозиторий и перед push выполните `git remote set-url origin git@github.com:me/agent-sync.git`.

`init` читает `origin/HEAD` внутри `--root`, если этот путь — git-чекаут. Папка с несколькими чекаутами таким чекаутом не является, и `origin/HEAD` самого клона — не ветка проекта. Передайте `--base-branch` (в примере `develop`; если у проекта основная ветка `main`, укажите её).

### 1b. Локальный bare-репозиторий (без GitHub)

```bash
git clone <url-этого-шаблона> ~/.agent-sync
cd ~/.agent-sync
bin/tools-check.sh
bin/tools-check.sh --install
bin/agent-sync.sh init \
  --name acme \
  --root /home/me/acme \
  --org acme \
  --server '' \
  --base-branch develop \
  --user-language Polish
git add -A && git commit -m "Render for acme"
git init --bare -b main /home/me/agent-sync.git
git remote remove origin
git remote add origin /home/me/agent-sync.git
git push -u origin main
bin/agent-sync.sh install
```

Каталог `/home/me/agent-sync.git` — на диске, который читаете только вы, или на SSH-хосте (`user@host:agent-sync.git`). Bare-репозиторий не кладите внутрь публичного чекаута проекта.

### 2. Симлинки в `$HOME` и таймер

`install` переносит каждый путь из `sync.conf` в `store/` и оставляет симлинк на старом месте. Короткие команды попадают в `~/.local/bin`.

### Что install делает с уже существующим ~/.claude

Без `--adopt` локальный файл, который отличается от копии в репозитории, остаётся на месте. Команда пишет об этом и называет `install --adopt`. Первый `--adopt` убирает этот файл в `имя.local-<время>` и ставит симлинк на копию из репозитория, даже если ваш файл новее. Позже `pull`, `push` или `sync` могут скопировать более новый локальный файл в репозиторий: так бывает, когда программа подменила симлинк уже после adopt. `install` без `--adopt` пишет `~/.agent-sync/.link-adopt-pending`. `pull`, `push`, `sync` и таймер при входе не заменяют отличающийся файл, пока этот файл есть, и создают его, если вы ещё не включали adopt. Удаляет его только `install --adopt`. После этого эти команды делают adopt.

Уже существующий симлинк сохраняется, с предупреждением, если в репозитории нет файла по этому пути. Install его не удаляет.

`--adopt` переносит существующий каталог целиком. `~/.claude/skills` становится `skills.local-<время>`, и Claude перестаёт загружать скиллы, которые были только там. Нужные перенесите в репозиторий и закоммитьте:

```bash
ls -d ~/.claude/skills.local-*                       # копия, которую сделал install
cp -r ~/.claude/skills.local-<время>/my-skill ~/.agent-sync/store/.claude/skills/
agent-sync sync
```

Включите задачи по расписанию:

```bash
bin/agent-sync.sh timers enable    # agent-sync-boundary и agent-sync; agent-history, если задан SYNC_SERVER
bin/agent-sync.sh timers status
```

На Linux и WSL команда линкует юниты из `systemd/` в `~/.config/systemd/user` и включает их. Для синка по SSH без графической сессии выполните ещё `loginctl enable-linger "$USER"`. Если в WSL systemd выключен, команда печатает строки для `/etc/wsl.conf`. На macOS загружает агенты launchd. Необязательные задачи по имени: `timers enable herdr-notify herdr-host-ping`. `timers disable` их убирает.

### 3. Вход на этой машине

Учётные данные Claude свои на каждой машине. Запустите `claude`, затем `/login`. Проверка:

```bash
bin/check.sh
agent-sync status
```

`init` выполняется один раз. Он заменяет `{{PLACEHOLDER}}` в `store/`, переименовывает пути вроде `skills/{{PROJECT_NAME}}-recipes`, пишет `agent-sync.env` и создаёт `CLAUDE.md` в `PROJECT_ROOT`, если каталог есть и файла ещё нет. Повторный `init` ничего не меняет. `install` сам вызывает `init`, пока плейсхолдеры на месте. Незнакомые `{{...}}` остаются. `{{CLICKUP_*}}` только предупреждает: заполните скилл ClickUp-docs или удалите его.

В терминале `init` без флагов задаёт вопросы. В скрипте нужны `--name`, `--root` и `--user-language` (или те же переменные). Если их нет, скрипт выходит и ничего не пишет.

## По шагам: вторая машина

Чекауты должны лежать по тому же `PROJECT_ROOT` (в примере `/home/me/acme`). Продолжение сессии ищет транскрипт по этому пути.

```bash
git clone git@github.com:me/agent-sync.git ~/.agent-sync
# или: git clone user@host:agent-sync.git ~/.agent-sync
cd ~/.agent-sync
# agent-sync.env в git нет. Скопируйте его с первой машины или запустите init
# с теми же флагами. install его не создаёт: в store плейсхолдеров уже нет.
cp /path/from/the/first/machine/agent-sync.env ~/.agent-sync/agent-sync.env
# bin/agent-sync.sh init --name acme --root /home/me/acme --org acme --server '' --user-language Polish
bin/agent-sync.sh install
bin/agent-sync.sh timers enable
claude    # снова /login; токен в git не лежит
bin/check.sh
```

Секретные файлы скопируйте руками (следующий раздел). В этот репозиторий их не добавляйте.

## Где лежат секреты

| Секрет | Где | В этом git |
|---|---|---|
| OAuth-токен Claude | `~/.claude/.credentials.json` | нет; на каждой машине `/login` |
| Идентификатор машины Claude | `~/.claude.json` | нет |
| Пароли БД и ключи API проекта | `$PROJECT_CREDS_DIR` (по умолчанию `/home/me/acme-creds`) и gitignore-файлы `.env*` в чекаутах | нет |
| Telegram-бот «агент ждёт ответа» | `~/.config/herdr-notify.env` (`chmod 600`) | нет; нет файла — таймер молча выходит |
| Адреса tailcat других хостов | `~/.config/herdr-hosts.conf` (`chmod 600`) | нет; адреса достаточно, чтобы подключиться |
| Разрешённые внешние IP для geo-guard | `GEO_IPS_FILE` (по умолчанию `~/.agent-sync/geo-allowed-ips`) | нет; `geo-allowed-ips` в gitignore |
| SSH-ключи, токены `gh` | `~/.ssh`, `gh auth` | нет |

Каталог учётных данных — рядом с чекаутами, не внутри них:

```bash
mkdir -p /home/me/acme-creds
chmod 700 /home/me/acme-creds
# пример: /home/me/acme-creds/.acme-dev.cnf
```

`prevent-secret-commit.sh` блокирует `git commit`, если в индексе похоже на секрет, файл `.env` или путь `node_modules`. Хук — страховка. Правило — раскладка выше.

## Обычная работа

```bash
cd /home/me/acme/api          # git-корень внутри PROJECT_ROOT, не папка всех чекаутов
wt-new api task-123 --branch feat/task-123
# последняя строка вывода — путь worktree
```

Передать работу панели роли (herdr запущен, `HERDR_ENV=1`):

```bash
herdr-spaces list
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-developer "[DEV REQUEST] ..."
```

Подтянуть основные чекауты на базовую ветку:

```bash
project-develop --dry-run
project-develop
```

Синк вручную: `agent-sync sync`. Таймер делает то же каждые 5 минут.

## Параметры `init`

Флаг сильнее переменной окружения, окружение сильнее `agent-sync.env`, файл сильнее вопроса в терминале.

| Флаг | Куда пишет |
|---|---|
| `--name` | `PROJECT_NAME` (короткое имя `[a-z0-9][a-z0-9_-]*`) |
| `--root` | `PROJECT_ROOT` (абсолютный путь) |
| `--org` | `PROJECT_GIT_ORG` (по умолчанию имя) |
| `--server` | `SYNC_SERVER` (пустая строка — сервера истории нет) |
| `--base-branch` | `PROJECT_BASE_BRANCH` (по умолчанию `origin/HEAD` внутри `--root`, если это git-чекаут, иначе `main`) |
| `--creds` | `PROJECT_CREDS_DIR` (по умолчанию `${PROJECT_ROOT}-creds`) |
| `--user-language` | `USER_LANGUAGE` (одно слово, например `Polish`) |

Плейсхолдеры, которые `init` заменяет в `store/`: `{{PROJECT_NAME}}`, `{{PROJECT_ROOT}}`, `{{PROJECT_GIT_ORG}}`, `{{PROJECT_CREDS_DIR}}`, `{{PROJECT_BASE_BRANCH}}`, `{{PROJECT_KEY}}`, `{{USER_LANGUAGE}}`, `{{SYNC_SERVER}}`.

## Переменные (`agent-sync.env`)

`bin/lib/project-env.sh` читает `${SYNC_HOME:-$HOME/.agent-sync}/agent-sync.env`. Настоящая переменная окружения перекрывает файл.

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `PROJECT_NAME` | `project` | короткое имя в хуках и скиллах |
| `PROJECT_ROOT` | `$HOME/$PROJECT_NAME` | папка git-чекаутов или сам репозиторий |
| `PROJECT_GIT_ORG` | `$PROJECT_NAME` | организация GitHub для `gh` и ссылок на PR |
| `PROJECT_CREDS_DIR` | `${PROJECT_ROOT}-creds` | секреты вне репозиториев |
| `PROJECT_BASE_BRANCH` | `origin/HEAD` у `--root`, если это git-чекаут, иначе `main` | `wt-new` и `project-develop` берут `origin/<это>` |
| `SYNC_SERVER` | пусто | SSH-алиас; пусто — история сессий не синхронизируется |
| `USER_LANGUAGE` | обязательна для `init` | язык длинных ответов в чате |
| `STAND_DB_HOST` | пусто | LAN-хост общих dev MySQL/Redis/Mongo; пусто — режима LAN нет |
| `HISTORY_REMOTE` | `$SYNC_SERVER:agent-history/claude` | куда rsync кладёт транскрипты |
| `PROJECT_KEY` | вычисляется | `PROJECT_ROOT`, где `/` и `.` заменены на `-` |

Остальные ручки (окружение, не файл env):

| Переменная | По умолчанию | Кто читает |
|---|---|---|
| `GEO_ALLOWED` | пусто (выключено) | список стран `geo-guard.sh`; пусто — хук ничего не делает |
| `GEO_IP_TTL` | `60` (`0` — на каждом промпте) | как часто узнавать внешний IP |
| `GEO_IPS_FILE` | `~/.agent-sync/geo-allowed-ips` | IP без запроса страны |
| `HERDR_NOTIFY_ENV` | `~/.config/herdr-notify.env` | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| `HERDR_NOTIFY_BLOCKED_SEC` | `600` | пауза до одного сообщения в Telegram |
| `CONTEXT_WARN_TOKENS` | `150000` | предупреждение context-guard |
| `CONTEXT_REWARN_STEP` | `50000` | повторить предупреждение после такого прироста |
| `LIMIT_WARN_PCT` | `90` | limit-guard и метка `!!!` в сайдбаре |
| `LIMIT_PACE_TZ` | пусто (зона процесса) | зона для времени сброса из `/usage`, если в тексте нет `(Zone)` |
| `LIMIT_PACE_GAP_HOURS` | пусто | целое число часов от UTC со знаком; только когда в тексте нет зоны и `LIMIT_PACE_TZ` пуст |
| `SIDEBAR_WARN_PCT` | `80` | метка `!` в сайдбаре |
| `BATTERY_WARN_PCT` | `20` | предупреждение о низком заряде |
| `LIMIT_QUIET_MINUTES` | `20` | пауза между предупреждениями limit-guard |
| `ONDEMAND_SESSION_PCT` | `95` | подсказка ondemand-guard по сессии |
| `ONDEMAND_WEEK_PCT` | `98` | подсказка ondemand-guard по неделе |
| `ONDEMAND_QUIET_MINUTES` | `20` | пауза ondemand-guard |
| `KEEP_AWAKE_TTL_MINUTES` | `180` | запрет сна, пока агент работает от батареи |
| `HISTORY_MAX_AGE_DAYS` | `30` | какие транскрипты забирать с сервера истории |
| `HISTORY_SRC` | `~/.claude/projects` | локальное дерево транскриптов |
| `SESSIONS_IGNORE_PROMPTS` | пусто | дополнительный regex; промпты ролей из `bin/role-agent-prompts.ere` и так не пишутся |
| `HANDOFF_SETTLE_START` | `3` | секунды до опроса herdr-handoff |
| `HANDOFF_POLL` | `2` | интервал опроса herdr-handoff |
| `BIN_DIR` | `~/.local/bin` | куда `install` кладёт команды |

`settings.json` (синхронизируется) содержит `hooks`, `env`, `permissions`, `autoMode` и `model`. Остальные предпочтения (`theme`, `effortLevel`, `promptCacheTtl`, `skillOverrides` и прочие) лежат с пустыми значениями в `settings.example.json`. Нужные перенесите вручную.

`bin/wt-short-names.conf`: `каталог-репо = короткое-имя` для папок worktree.

`sync.conf`: путь относительно `$HOME`, по одному в строке, glob `*`, строка с `!` в начале исключает совпадение. Файл синхронизируется сам.

## Что синхронизируется

Из `sync.conf`: правила, `settings.json`, хуки, скиллы и планы в `~/.claude`; `config.toml` herdr. `settings.local.json` остаётся на этой машине. Память проекта включается отдельно: раскомментируйте одну строку `.claude/projects/<project-key>/memory` в `sync.conf`. В шаблоне эта строка закомментирована, так что память не синхронизируется, пока вы этого не сделаете.

`history-sync` при заданном `SYNC_SERVER` отправляет каждый `*.jsonl` из `HISTORY_SRC`. По умолчанию это `~/.claude/projects`: транскрипты всех проектов Claude на этой машине, не только этого. Ограничьте каталогом одного проекта через `HISTORY_SRC` или оставьте `SYNC_SERVER` пустым — тогда история остаётся локальной.

Остаётся на машине: учётные данные и `~/.claude.json` (таблица выше), `settings.local.json`, раскладка панелей herdr (`session.json`), сокеты, логи.

Бэкап восстанавливает одно состояние. Этот git сводит правки с двух машин.

## Команды

```
bin/agent-sync.sh init [флаги]          один раз подставить плейсхолдеры
bin/agent-sync.sh install [--remote URL]
bin/agent-sync.sh sync                  pull + push; adopt только после install --adopt
bin/agent-sync.sh pull | push | status
bin/agent-sync.sh timers enable|disable|status [name...]
bin/check.sh                            agent-sync-check: поднялся ли синк после загрузки
```

`install` ставит в `~/.local/bin` имена из `CLI_COMMANDS` в `bin/agent-sync.sh`:

| Команда | Зачем |
|---|---|
| `agent-sync` | сам скрипт синхронизации |
| `agent-sync-check` | `check.sh` (имя `check` в `PATH` слишком общее) |
| `tools-check` | отчёт по `tools.conf`; `--install` |
| `wt-new <repo> <task> [--branch имя] [--base ветка] [--at sha] [--env]` | worktree в `$PROJECT_ROOT/.worktrees/<короткое>-<task>` |
| `wt-install [worktree]` | `node_modules` через pnpm для этого worktree |
| `project-develop [--dry-run] [repo...]` | fast-forward основных чекаутов на `origin/$PROJECT_BASE_BRANCH` |
| `pr-diff <repo> <n> [файл...]` | diff PR по частям |
| `history-sync` | rsync транскриптов; молчит, если `SYNC_SERVER` пуст |
| `agent-sessions list [текст] [--on ДАТА] [--since D --until D] [--host H] [--page N] [--all]` | |
| `agent-sessions resume <id\|n> [--print]` | |
| `agent-sessions brief <id>` | |
| `agent-sessions pickup <id\|n> [--agent claude\|cursor] [--print]` | новая сессия с выжимкой |
| `register-me [--id <session-id>] "над чем работаю"` | записать сессию, стартовавшую до хука |
| `herdr-spaces [list [host...]]` / `me` / `send <host> <label> [текст\|--file путь]` | |
| `herdr-pane-reply <pane_id>` | последний блок `[… RESULT]`; код 1, если его нет |
| `template-drift.sh` / `--diff [путь]` / `--mark [sha]` | только тем, кто переносит живой репозиторий обратно в шаблон |

Помощники worktree (в `PATH` по умолчанию не стоят): `herdr-handoff.sh [--no-clear] <pane_id> <skill> [сообщение]`, `herdr-pane-send.sh`, `herdr-agent-send.sh <host> <pane\|--label L>`, `herdr-host-ping.sh <host> [Label]`.

`wt-new`: `--branch` берёт существующую ветку или создаёт новую от `origin/<base>`; без `--branch` и `--at` worktree отсоединён на `origin/<base>`; `--at` — отсоединённый коммит, вместе с `--branch` его не указывают; `--env` копирует `.env*` из основного чекаута.

`project-develop` пропускает грязное дерево, разошедшуюся локальную базовую ветку, отсутствие `origin/<ветка>` и detached HEAD с коммитами, которых нет ни в одной ветке. Чистый worktree, который держит базовую ветку, снимается, чтобы основной чекаут мог на неё переключиться. `--dry-run` печатает `PLAN` и ничего не меняет.

Коды выхода `herdr-handoff.sh`: `0` — запрос виден (или панель в `working`), `1` — отправка не удалась или текст так и не появился, `2` — панель ещё должна `[TAG RESULT]` (`/clear` её сотрёт). `--no-clear` продолжает ту же задачу. Панель не Claude получает запрос сразу.

## Когда синхронизируется

Ниже — имена юнитов systemd. На macOS каждая задача — `~/Library/LaunchAgents/dev.agent-sync.<имя>.plist`, шага при выключении нет.

| Событие | Юнит | Действие |
|---|---|---|
| вход в сессию | `agent-sync-boundary.service` | `pull`, затем `history-sync` (macOS: `pull`) |
| выключение / выход | тот же юнит, `ExecStop` | `sync`, затем `history-sync` (только Linux) |
| каждые 5 минут | `agent-sync.timer` | `sync` |
| раз в час | `agent-history.timer` | `history-sync` (включать только с `SYNC_SERVER`) |
| раз в минуту | `herdr-notify.timer` | Telegram, если агент в `blocked` ≥ 10 минут |
| каждые 5 минут | `herdr-host-ping.timer` | кэш, какие удалённые хосты отвечают |
| вручную | `tailcat-serve.service` | необязательный SSH через DERP, только Linux; см. ниже |

Три неудачи синка подряд поднимают уведомление рабочего стола (`notify-send` на Linux, Центр уведомлений на macOS). Недоступный сервер сюда не входит: коммит остаётся локально до следующего push.

Правила истории (`tests/history.sh`): на обеих сторонах ничего не удаляется; более новый файл не затирается старым; забираются только файлы моложе 30 дней; недоступный сервер — пропуск прогона.

Сессии продолжаются по пути, поэтому `PROJECT_ROOT` на всех машинах один и тот же. Сессии постоянных ролей в реестр не пишутся.

## Хуки

Подключены в `store/.claude/settings.json`. Хук без `"async": true` может остановить промпт (код выхода 2). Блокирующие хуки асинхронными не делают.

| Хук | События | Блокирует | Что делает |
|---|---|---|---|
| `geo-guard.sh` | UserPromptSubmit | да, если задан `GEO_ALLOWED` | Блокирует, если страна внешнего IP не из `GEO_ALLOWED`. Пустой `GEO_ALLOWED` выключает хук. При заданном списке любой сбой проверки тоже блокирует. IP из файла пропускает запрос страны, сам IP всё равно проверяется. |
| `limit-guard.sh` | UserPromptSubmit | нет | Говорит агенту, что лимит или батарея на исходе, чтобы он записал план. |
| `context-guard.sh` | UserPromptSubmit | нет | Говорит агенту, что контекст большой. `/clear` — только после того, как `herdr-handoff.sh` подтвердил доставку. |
| `ondemand-guard.sh` | UserPromptSubmit | нет | Печатает подсказку, когда лимит почти выбран и включена оплата on-demand. Ход не останавливает. |
| `plan-resume.sh` | SessionStart, matcher `clear` | нет | После `/clear` указывает план, у которого `**Herdr space:**` совпадает с этим пространством. |
| `herdr-pane-meta.sh` | SessionStart, UserPromptSubmit, PreToolUse, Notification, Stop, SessionEnd | нет | Сайдбар: ветка на вкладке, агент и лимит снизу, стрелки темпа, батарея `AC`/`B`, свежий процент уходит на остальные панели Claude. |
| `session-record.sh` | SessionStart, UserPromptSubmit, Stop, SessionEnd, PostToolUse | нет | Реестр для `agent-sessions`. |
| `awake-hook.sh` | UserPromptSubmit, Notification, Stop, SessionEnd | нет | На батарее держит блокировку сна, пока агент работает (`keep-awake.sh`: `systemd-inhibit` на Linux, `caffeinate` на macOS). |
| `limit-wake-hook.sh` | Notification, Stop | нет | После сброса лимита просит панель продолжить (таймер `systemd-run` на Linux, одноразовый агент launchd на macOS). Вручную: `--run --target PANE --message TEXT`. |
| `role-clear.sh` | Stop | нет | Шлёт `/clear` панели постоянной роли после законченного запроса. Пока не отправлен `[TAG RESULT]`, оставляет маркер. |
| `project-block-primary-checkout-write.sh` | PreToolUse Edit, Write, NotebookEdit | да | Блокирует запись в основной чекаут под `PROJECT_ROOT`. Работайте в worktree. |
| `block-dangerous-rm.sh` | PreToolUse Bash | да | Блокирует `rm -rf` по `/`, `$HOME` или glob, который накрывает всё. |
| `prevent-secret-commit.sh` | PreToolUse Bash | да | Блокирует `git commit` вероятных секретов, `.env` или `node_modules`. |
| `project-worktree-via-wt-new.sh` | PreToolUse Bash и EnterWorktree | да | Блокирует голый `git worktree add\|move` под `PROJECT_ROOT`. Используйте `wt-new`. |

`limit-pace.sh` — не хук. Его вызывает сайдбар. Прогноз = использовано% × окно / прошедшее время. Окно сессии — 5 часов, недели — 7 дней. Время сброса без зоны берётся из `LIMIT_PACE_TZ`, а если она пуста — из `LIMIT_PACE_GAP_HOURS`. ↑ ниже 60% (запас останется), без стрелки 60–100%, ↓ 100–130%, ↓↓ выше 130% или лимит уже 100%. Первые 10% окна без стрелки, кроме лимита 100%. Нет даты сброса — нет стрелки. Шрифт herdr не рисует эмодзи, поэтому метки — `↑` `↓` `↓↓`.

## Скиллы

Скиллы ролей живут в пространстве herdr. Запрашивающий шлёт `[TAG REQUEST]`, роль отвечает `[TAG RESULT]`. Отправка через `herdr-handoff.sh`, не тремя отдельными `agent prompt`. Ненужные скиллы удаляйте. Примеры стоят между `<!-- EXAMPLE:BEGIN -->` и `<!-- EXAMPLE:END -->`.

| Скилл | Метка / пространство | Что делает |
|---|---|---|
| `agent-pm` | `[PM REQUEST]` / PM | Ведёт план: раздаёт работу остальным ролям, сверяет результаты, код не пишет. |
| `agent-developer` | `[DEV REQUEST]` / Developer | Реализует план в worktree, открывает черновик PR. |
| `agent-review` | `[REVIEW REQUEST]` / Review Cursor, Review Claude | Ревью PR. Ключи находок: `agent-review/review-keys.md`. |
| `agent-qa` | `[QA REQUEST]` / QA | Гоняет тесты, проверку типов и линт; пишет, что упало. |
| `agent-db` | `[DB REQUEST]` / DB | Только `SELECT` / `EXPLAIN`, учётные данные из `PROJECT_CREDS_DIR`. |
| `agent-logs` | `[LOGS REQUEST]` / Logs | Читает логи (Loki, стенд, сервис) и возвращает короткий ответ. |
| `agent-devops` | `[DEVOPS REQUEST]` / DevOps | Поднимает и гасит локальный стенд (только Linux и WSL). В скилле описано, как исследовать свои репозитории и написать раздел «Project stand map»; факты проекта — в `stand-project.sh` (образец `stand-project.example.sh`). |
| `agent-cleaner` | `[CLEANER REQUEST]` / Cleaner | Снимает законченные worktree. `/agent-cleaner` без запроса чистит рабочие worktree под `PROJECT_ROOT` без второго подтверждения; грязные деревья, непушенные коммиты и открытые PR остаются. |
| `agent-docs` | `[DOCS REQUEST]` / Docs | Заметки о предметной области и страница ClickUp. Нужен `{{PROJECT_NAME}}-clickup-docs`. |
| `{{PROJECT_NAME}}-clickup-docs` | | Стиль страниц ClickUp. Заполните `{{CLICKUP_*}}` или удалите скилл. |
| `herdr` | | CLI herdr. Когда пользователь называет Herdr. Нужен `HERDR_ENV=1`. |
| `remote-agents` | | Написать агенту на другой машине. |
| `retro` | | Разбор транскриптов сессий в предложения для памяти. `scripts/ttl-sim.sh` сравнивает стоимость кэша промпта `5m` и `1h`. |
| `pr-review-retro` | | Повторяющиеся замечания из GitHub и `[REVIEW RESULT]`. |
| `init` | | Написать или ужать `AGENTS.md` репозитория. |

Project recipe skills (test-data how-tos) are yours to add; name them `{{PROJECT_NAME}}-<topic>`.

## Блоки-примеры и свои литералы

Всё проектное в шаблоне — либо `{{PLACEHOLDER}}`, который заполняет `init`, либо пример про выдуманный проект `acme`. Примеры бывают трёх видов:

- Блоки `<!-- EXAMPLE:BEGIN ... -->` … `<!-- EXAMPLE:END -->` внутри скиллов. В открывающем комментарии написано, что туда вставить. Замените блок своими фактами или удалите; текст вне блока — общее правило, он остаётся.
- Файлы `*.example` / `*.example.*` рядом с настоящими (`agent-sync.env.example`, `stand-project.example.sh`, `tests/no-literals.words.example`). Скопируйте, переименуйте, заполните.
- Значения-примеры в шаблонах запросов и ответов (`acme-api`, `orders.id 12345`, `w7:p2`). Они только показывают форму.

Самый большой случай — скилл agent-devops: сервисы, порты и режимы БД стенда угадать нельзя, поэтому в скилле лежит пошаговая процедура, как исследовать репозитории в `PROJECT_ROOT` и самому написать раздел «Project stand map» и `stand-project.sh`.

Перед публикацией своей копии шаблона скопируйте `tests/no-literals.words.example` в `tests/no-literals.words` (в `.gitignore`) и перечислите то, что не должно уйти наружу: названия компании и продукта, свои логины и фамилию, ssh-алиас сервера, id ClickUp/Jira/Sentry, префиксы хостов локальной сети. После этого `tests/no-literals.sh` падает на любом из них вне блоков-примеров и на IP частных сетей где угодно. История git хранит всё, что было закоммичено хоть раз: если литерал просочился, перепишите историю (или начните новый репозиторий), а не просто удалите строку.

## Сообщения между машинами (необязательно)

`herdr-host-ping.sh <host>` говорит, может ли хост принять запрос. `herdr-agent-send.sh` шлёт его по Tailscale SSH. [tailcat](https://github.com/tailscale/tailcat) — запасной канал (WireGuard + DERP, без открытого порта): `systemd/tailcat-serve.service`.

На каждом хосте:

1. Поставьте бинарник tailcat из GitHub Releases в `~/.local/bin` и проверьте контрольную сумму.
2. `tailcat genkey --key=$(hostname)`.
3. `agent-sync timers enable tailcat-serve` (только Linux и WSL).
4. Адрес: `journalctl --user -u tailcat-serve -n 5 --no-pager`.
5. На каждом другом хосте добавьте `host=tc-адрес` в `~/.config/herdr-hosts.conf` (`chmod 600`). Адреса передавайте по каналу, которому уже доверяете.

Юнит использует ваш `~/.ssh/authorized_keys`.

## Тесты

Каждый файл в `tests/` работает на временном `HOME` и локальных bare-репозиториях. Одна команда запускает их все, а также тесты хуков и `test_mine.py`:

```bash
bash tests/all.sh
```

CI (`.github/workflows/test.yml`) запускает её на Ubuntu и macOS и проверяет историю git через gitleaks.

`tests/no-literals.sh` падает, если имена из `tests/no-literals.words` встречаются вне блоков-примеров, и если где угодно встречается IP частной сети (см. «Блоки-примеры и свои литералы»). `tests/no-cyrillic.sh` держит прозу этого дерева на английском; `README.ru.md` — русская копия, из проверки он исключён.

## Перенос живого `~/.agent-sync` обратно сюда

В живом репозитории лежит `template.ported` (sha `main`, уже скопированный сюда). После push обновлённого шаблона:

```bash
bin/template-drift.sh               # код 1, если main ушёл вперёд
bin/template-drift.sh --diff [путь]
bin/template-drift.sh --mark [sha]  # коммит "template: ported up to <sha>"
```

Планы, сессии, `skills/synced` и личные скрипты из списка в `template-drift.sh` в расчёт не входят. Переносите паттерны и примеры. Токены, имена хостов, id аккаунтов и приватные пути оставляйте снаружи.
