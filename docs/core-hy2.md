# Hysteria2 на core

Установлен 2026-11-12: Hysteria2 v2.13.0, Ubuntu 24.04, UDP 443.
Адрес: 188.241.196.251. Служба: hysteria-core.service (enabled).
Бинарник /usr/local/bin/hysteria-core проверен по SHA-256 из GitHub Releases.
Конфиг и сертификат: /etc/hysteria-core; отдельный пользователь hy2core.
Существующие Amnezia, Docker, TCP 443 и SSH не перенастраивались.

Самоподписанный сертификат на 825 дней, имя core-vpn; домен не требуется.
Перед истечением сертификата нужно обновить сертификат и клиентские профили.
Профиль sing-box доверяет вложенному сертификату и проверяет имя core-vpn.
URI использует insecure=1 ВМЕСТЕ с pinSHA256: импортировать только в клиент,
который поддерживает и сохраняет pinSHA256. Для текущего sing-box использовать JSON.

Локальные артефакты в .local-stage (0600, исключены из Git):
- core-hy2-sing-box.json — полный кандидат на замену /etc/sing-box/config.json;
- core-hy2-outbound.json — только outbound для интеграции;
- core-hy2-uri.txt — ссылка импорта с паролем и отпечатком;
- core-hy2.crt — публичный сертификат.
Не публиковать профили: они содержат пароль доступа.

Проверено: служба active/enabled, слушает UDP 443, клиент на сервере проверил
TLS/пароль и получил HTTP 200 через Hysteria2. Полный локальный конфиг прошёл
sing-box check. Доступность UDP 443 с компьютера ещё не проверена.
Локальный VPN не запускался и не переключался.

Для переключения вручную в обычном терминале (возможен разрыв VPN-соединений):

```sh
cd /home/noukey/Documents/Mega_vpn
sudo systemctl stop vpn-watchdog.service
sudo mkdir -p /root/mega-vpn-backup
sudo cp -a /etc/sing-box/config.json /root/mega-vpn-backup/before-core-hy2.json
sudo cp .local-stage/core-hy2-sing-box.json /etc/sing-box/config.json
sudo systemctl restart sing-box.service sing-vpn.service
vpn-ping -c 4 && sudo systemctl start vpn-watchdog.service
```

Кандидат основан на конфиге от 2026-11-12. Если оригинал менялся, сначала
перенести outbound в актуальный конфиг. Адрес сервера задан IP: DNS для
установления самого туннеля не нужен. Конфликт других VPN и блокировка
прямого выхода этим не устраняются.

Журнал сервера: ssh core 'journalctl -u hysteria-core -n 30 --no-pager'.
Отключить только новую серверную службу: ssh core 'systemctl disable --now hysteria-core'.
