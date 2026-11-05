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
