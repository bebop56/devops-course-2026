# Конфигурация виртуальной машины devops-vm

Документ описывает конфигурацию так, чтобы её можно было восстановить со снимка
`01-clean-install`. Команды выполняются от имени пользователя с правом sudo.

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Средство виртуализации | VirtualBox 7.2.22 (хост Windows 11, работа через Hyper-V/NEM) |
| Гостевая ОС | Ubuntu Server 24.04.5 LTS, образ `ubuntu-24.04.5-live-server-amd64.iso` |
| Память | 2048 МБ |
| Процессор | 2 ядра |
| Диск | 25 ГБ, VDI, динамический; разметка «Use an entire disk» + LVM |
| Паравиртуализация | `none` (при KVM-паравиртуализации под Hyper-V ядро зависает на «Loading essential drivers») |
| Контроллер SATA | 1 порт (`VBoxManage storagectl devops-vm --name SATA --portcount 1`) |
| Имя узла | `devops-vm`, FQDN `devops-vm.devops.local` |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | enp0s3 | 10.0.2.15/24 (DHCP) | выход в Интернет, вход по SSH через проброс порта |
| 2 | Виртуальный адаптер хоста (Host-only), `VirtualBox Host-Only Ethernet Adapter` | enp0s8 | 192.168.56.101/24 (DHCP) | прямой доступ с хоста: HTTP/HTTPS, имя `devops.local` |

На хосте в `C:\Windows\System32\drivers\etc\hosts` добавлена строка:

```
192.168.56.101	devops.local
```

## 3. Правило проброса портов

| Имя | Протокол | IP хоста | Порт хоста | IP гостя | Порт гостя |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | — | 2222 |

До смены порта службы гостевой порт был 22. Изменение без выключения ВМ:

```
VBoxManage controlvm devops-vm natpf1 delete ssh
VBoxManage controlvm devops-vm natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Имя | UID | Группы | Аутентификация |
|---|---|---|---|
| student | 1000 | student, adm, cdrom, sudo, dip, plugdev, lxd | создан установщиком; только локальная консоль (по SSH запрещён `AllowUsers`) |
| devops | 1001 | devops, sudo, users | SSH только по ключу ED25519 (`~/.ssh/devops_vm` на хосте); пароль — для sudo и консоли |

Создание учётной записи и размещение ключа:

```bash
sudo adduser devops            # пароль не короче 12 символов, не словарный
sudo usermod -aG sudo devops
# на хосте:
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
# права на сервере: ~/.ssh — 700, ~/.ssh/authorized_keys — 600
```

Файл `~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

Правило sudo для неинтерактивного запуска `scripts/audit.sh` (только команды чтения),
файл `/etc/sudoers.d/90-audit`, права 440, проверка `sudo visudo -cf`:

```
devops ALL=(root) NOPASSWD: /usr/sbin/sshd -T, /usr/sbin/ufw status, /usr/sbin/ufw status verbose
```

## 5. Служба SSH

- Основной файл `/etc/ssh/sshd_config` не изменяется, копия — `/etc/ssh/sshd_config.backup`.
- Изменения — в `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30

AllowUsers devops

X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

- В `/etc/ssh/sshd_config.d/50-cloud-init.conf` закомментирована строка
  `PasswordAuthentication yes`: файл читается раньше `99-hardening.conf`, а sshd
  берёт первое встреченное значение директивы.
- Активация по сокету отключена, иначе порт берётся из `ssh.socket` (22):

```bash
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo sshd -t && sudo systemctl restart ssh
sudo ss -tlnp | grep sshd        # 0.0.0.0:2222 и [::]:2222
```

- Проверка действующих значений: `sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"`.

## 6. Правила межсетевого экрана

Порядок важен: разрешающее правило для 2222 создаётся до `ufw enable`.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw allow 80/tcp  comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw delete allow 2222/tcp
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw logging medium
```

Итог (`sudo ufw status verbose`): политика `deny (incoming), allow (outgoing)`,
правила `80/tcp ALLOW IN`, `443/tcp ALLOW IN`, `2222/tcp LIMIT IN` (и то же для v6).
Правило `limit` блокирует источник, открывший 6 и более соединений за 30 с.

## 7. Снимки состояния

| Снимок | Момент создания |
|---|---|
| 01-clean-install | 05.11.2026, после установки ОС и `apt upgrade`, ВМ выключена |
| 02-keys-configured | 05.11.2026, после задания 1 ПР № 5 (devops, ключ, `~/.ssh/config`) |
| 03-ssh-hardened | 05.11.2026, после задания 2 ПР № 5 (усиление sshd) |

Снимки делаются на выключенной машине: под Hyper-V сохранение состояния памяти
работающей ВМ идёт несколько десятков минут.

## 8. Веб-сервер

- Пакет: `nginx` из репозитория Ubuntu (`sudo apt install -y nginx`), версия 1.24.0.
  Главный процесс работает от `root`, рабочие — от `www-data`.
- Порты 80 и 443 уже открыты правилами раздела 6; профили `Nginx Full` и т. п. не добавляются.
- Конфигурация ресурса: `/etc/nginx/sites-available/devops-site` (копия в репозитории —
  `deploy/nginx/devops-site`), активирована ссылкой в `/etc/nginx/sites-enabled/`;
  ссылка `sites-enabled/default` удалена, файл `sites-available/default` сохранён.
  Блок 1 — порт 80, `return 301 https://$host$request_uri`; блок 2 — порт 443 ssl,
  `ssl_protocols TLSv1.2 TLSv1.3`, `root /var/www/devops-site`, `error_page 404 /404.html`,
  журналы `/var/log/nginx/devops-site.{access,error}.log`. HSTS не включается.
- Применение изменений только так: `sudo nginx -t && sudo systemctl reload nginx`.
- Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`, каталоги `755`,
  файлы `644` (владелец пишет, веб-сервер читает). Содержимое доставляется
  `scripts/deploy.sh` из каталога `site/`.
- Сертификат: `/etc/ssl/certs/devops.crt`, `root:root`, `644`.
- Закрытый ключ: `/etc/ssl/private/devops.key`, `root:root`, `600` (каталог `private` — `700`).
- Формирование сертификата (самоподписанный, RSA 2048, срок 365 дней,
  выпущен 05.11.2026, действителен до 05.11.2027):

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```

- На хосте сертификат лежит в `~/devops.crt` (скопирован `scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`)
  и передаётся клиенту через `curl --cacert ~/devops.crt`.
- Правило `/etc/sudoers.d/90-audit` дополнено командами `/usr/sbin/nginx -t` и
  `/usr/bin/stat -c %a /etc/ssl/private/devops.key`.
- Снимок `04-nginx-https` — 06.11.2026, после задания 2 ПР № 6.

## 9. Контейнеризация

- Docker Engine 29.9.3 и Docker Compose v5.7.0 установлены из официального репозитория
  Docker (не из пакетов дистрибутива; `docker.io`, `podman-docker` и т. п. отсутствуют):

```bash
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops     # затем новый вход, чтобы группа применилась
```

- Группа `docker`: только `devops` (членство в группе равносильно правам root;
  у `devops` уже есть sudo, поэтому привилегии не расширяются).
- Проект: `~/app` пользователя devops (`/home/devops/app`), копия каталога `app/`
  репозитория; доставка с исключением `.env` (`rsync -av --delete --exclude=.env`).
  Образ `devops-app:1.0` (python:3.12-slim, пользователь `app`, gunicorn на 0.0.0.0:5000).
- Секреты: `~/app/.env`, владелец `devops`, права `600`, создаётся только на сервере
  из `.env.example` со случайным паролем `openssl rand -hex 16`; в репозиторий и образ не попадает
  (`.gitignore`, `.dockerignore`).
- Сервисы Compose: `db` (postgres:16-alpine, проверка `pg_isready`), `app`
  (запускается после `service_healthy`), оба `restart: unless-stopped`, сеть `app_backend`.
- Публикуемые порты: только `127.0.0.1:5000 -> app:5000`; порт 5432 не публикуется.
  Публикация на всех адресах (`"5000:5000"`) обходит UFW через правила DNAT Docker —
  её отсутствие проверяет раздел [5] `scripts/audit.sh`.
- Именованный том: `app_db_data` -> `/var/lib/postgresql/data`
  (`docker compose down` его сохраняет, `down -v` удаляет).
- Обратный прокси: в блок HTTPS `/etc/nginx/sites-available/devops-site` добавлено

```nginx
location /app/ {
    proxy_pass http://127.0.0.1:5000/;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

  Приложение доступно по `https://devops.local/app/`, статический ресурс — по `https://devops.local/`.
- Запуск: `cd ~/app && docker compose up -d --build`; проверка: `docker compose ps`.
- Снимок `05-docker-compose` — 06.11.2026, после задания 2 ПР № 7.

## 10. Контрольная работа № 2 (вариант 4)

- Проект: `/home/devops/kr2` — копия репозитория https://github.com/bebop56/devops-kr2
  (ветка `kr2/variant-4`), доставляется без `.env` и `.git`.
- Сервисы Compose: `app` (образ `kr2-app:1.0`, порт `127.0.0.1:8004`) и `redis` (`redis:7-alpine`,
  пароль, AOF, том `kr2_redis_data`), сеть `kr2_backend`, `restart: unless-stopped`.
- Секрет: `~/kr2/.env` (права 600, владелец devops), пароль сгенерирован на сервере `openssl rand -hex 32`;
  в репозитории только `.env.example`.
- Ресурс `https://kv.devops.local`: `/etc/nginx/sites-available/kr2` (ссылка в `sites-enabled`),
  HTTP → HTTPS (301), прокси на `127.0.0.1:8004`, журналы `/var/log/nginx/kr2.{access,error}.log`.
- Сертификат: `/etc/ssl/certs/kr2.crt` (SAN `DNS:kv.devops.local`, 365 дней), ключ `/etc/ssl/private/kr2.key` (600, root).
- Хост: в `hosts` добавлено `192.168.56.101  kv.devops.local`.
- Правила UFW не менялись; `scripts/audit.sh` дополнен разделом `[6]`.
- Снимки `06-before-kr2` и `07-kr2` — 06.11.2026.
