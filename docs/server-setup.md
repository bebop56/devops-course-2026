# Настройка сервера devops-vm

## 10. Ansible

Проект автоматической настройки расположен в каталоге `ansible/` репозитория
`devops-course-2026`. Управляющий узел — WSL Ubuntu с Ansible и `sshpass`;
управляемый узел — виртуальная машина `devops-vm` (Ubuntu Server 24.04 amd64,
Host-only `192.168.56.101`).

### Inventory и учётные записи

- `ansible/inventory/bootstrap.ini` — первичный запуск от пользователя `student`
  на порту 22 с интерактивным вводом пароля (`--ask-pass`) и пароля sudo
  (`--ask-become-pass`).
- `ansible/inventory/prod.ini` — последующие запуски от пользователя `devops`
  по закрытому ключу `~/.ssh/devops_vm`, без интерактивного ввода.

Переход от bootstrap к prod выполняется ролью `ssh`: она создаёт пользователя
`devops`, устанавливает открытый ключ, добавляет правило sudo без пароля и
только после этого отключает аутентификацию по паролю.

### Роли

| Роль | Ответственность |
| --- | --- |
| `base` | Проверка Ubuntu 24.04 amd64, базовые пакеты, официальный репозиторий Docker, Docker Engine, `python3-debian` и `python3-requests` |
| `ssh` | Пользователь `devops`, ключ, sudo, hardening `sshd`, правила UFW |
| `nginx` | Установка Nginx, reverse proxy на `127.0.0.1:5000`, отключение default site |
| `app` | Загрузка образа, контейнер с публикацией только на loopback, проверка `/health` |

### Приложение

- Образ: `ghcr.io/bebop56/devops-ci-app`
- Полный SHA: `08e097ec6561be03d15bc1aa0602557eba8fe659`
- Контейнер: `devops-ci-app`
- Порт: `127.0.0.1:5000`
- Проверка здоровья: `http://127.0.0.1:5000/health`

Версия образа задаётся переменной `app_tag` в `ansible/group_vars/all.yml`.
Тег `latest` не используется.

### Команды

Первичный запуск из каталога `ansible/`:

```bash
ansible-playbook -i inventory/bootstrap.ini site.yml --ask-pass --ask-become-pass
```

Повторный запуск и неинтерактивный аудит:

```bash
ansible-playbook site.yml
ansible-playbook verify.yml
```

`verify.yml` только читает состояние (effective `sshd -T`, контейнер, health)
и не меняет конфигурацию.
