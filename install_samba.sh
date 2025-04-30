#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "\033[0;31mЭтот скрипт должен запускаться с правами root\033[0m" >&2
  exit 1
fi

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Глобальные переменные
DOMAIN=""
REALM=""
DOMAIN_ADMINS="Domain Admins"
ADMIN_USER=""

# Функция для вывода заголовка
function print_header() {
  clear
  echo -e "${YELLOW}============================================${NC}"
  echo -e "${YELLOW}  Samba Domain Member Management Script     ${NC}"
  echo -e "${YELLOW}============================================${NC}"
  echo
}

# Функция проверки подключения к домену
function check_domain_join() {
  if wbinfo --ping-dc &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Функция получения информации о домене из конфигурации
function get_domain_info() {
  DOMAIN=$(grep -i '^ *workgroup *=' /etc/samba/smb.conf | awk '{print $3}')
  REALM=$(grep -i '^ *realm *=' /etc/samba/smb.conf | awk '{print $3}')
}

# Функция корректного удаления из домена
function leave_domain() {
  echo -e "${YELLOW}Выполняем корректное удаление из домена...${NC}"
  
  # Останавливаем winbind перед выходом из домена
  systemctl stop winbind
  
  # Выходим из домена
  net ads leave -U "$ADMIN_USER"
  
  # Чистим кеш winbind
  echo -e "${YELLOW}Очистка кеша winbind...${NC}"
  rm -f /var/lib/samba/winbindd_cache.tdb
  rm -f /var/lib/samba/winbindd_idmap.tdb
  
  # Отключаем winbind от автозагрузки
  systemctl disable winbind
  
  # Редактируем конфиг Samba
  echo -e "${YELLOW}Обновление конфигурации Samba...${NC}"
  sed -i 's/^\( *security *=\).*/\1 user/g' /etc/samba/smb.conf
  sed -i '/idmap config/d' /etc/samba/smb.conf
  
  # Перезапускаем службы
  systemctl restart smbd nmbd
  
  echo -e "${GREEN}Сервер успешно удален из домена${NC}"
}

# Функция установки Samba
function install_samba() {
  print_header
  echo -e "${GREEN}=== ПОЛНАЯ УСТАНОВКА SAMBA ===${NC}"
  
  # Запрос информации о домене
  read -p "Введите краткое имя домена (например, EXAMPLE): " DOMAIN
  read -p "Введите полное имя домена (например, EXAMPLE.OFFICE): " REALM
  read -p "Введите IP-адрес NTP-сервера: " NTP_SERVER
  read -p "Введите имя доменного администратора (например, Domain Admins): " DOMAIN_ADMINS

  # Запрос информации о сервере
  read -p "Введите сетевое имя этой виртуальной машины: " HOSTNAME
  read -p "Введите IP-адрес этой виртуальной машины: " HOST_IP

  # Установка hostname
  echo -e "${GREEN}Установка имени сервера...${NC}"
  hostnamectl set-hostname $HOSTNAME

  # Установка необходимых пакетов
  echo -e "${GREEN}Установка необходимых пакетов...${NC}"
  apt update
  apt install -y sudo acl attr samba winbind libpam-winbind libnss-winbind krb5-config krb5-user dnsutils python3-setproctitle

  # Настройка NTP
  echo -e "${GREEN}Настройка NTP...${NC}"
  cat > /etc/systemd/timesyncd.conf <<EOF
[Time]
NTP=$NTP_SERVER
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
EOF

  systemctl enable systemd-timesyncd
  systemctl start systemd-timesyncd

  # Настройка Kerberos
  echo -e "${GREEN}Настройка Kerberos...${NC}"
  cat > /etc/krb5.conf <<EOF
[libdefaults]
default_realm = $REALM
dns_lookup_realm = false
dns_lookup_kdc = true
EOF

  # Настройка /etc/hosts
  echo -e "${GREEN}Настройка /etc/hosts...${NC}"
  cat > /etc/hosts <<EOF
127.0.0.1       localhost
$HOST_IP       $HOSTNAME.$REALM $HOSTNAME
EOF

  # Настройка Samba
  echo -e "${GREEN}Настройка Samba...${NC}"
  cat > /etc/samba/smb.conf <<EOF
[global]
        workgroup = $DOMAIN
        security = ADS
        realm = $REALM
        log file = /var/log/samba/%m.log
        log level = 1

        min protocol = NT1
        max protocol = SMB3

        idmap config * : backend = autorid
        idmap config * : range = 10000-99999999
        winbind use default domain = yes
        vfs objects = acl_xattr recycle
        map acl inherit = yes
        recycle:exclude = *.tmp *.temp *.log *.trace *.iso ~\$* *.docx# ~~\$*.pdf
        recycle:versions = yes
        recycle:touch = yes
        recycle:keeptree = yes
EOF

  # Настройка nsswitch.conf
  echo -e "${GREEN}Настройка /etc/nsswitch.conf...${NC}"
  cat > /etc/nsswitch.conf <<EOF
passwd:     files winbind sss
shadow:     files sss
group:      files winbind sss
hosts:      files dns myhostname
bootparams: nisplus [NOTFOUND=return] files
ethers:     files
netmasks:   files
networks:   files
protocols:  files
rpc:        files
services:   files sss
netgroup:   nisplus sss
publickey:  nisplus
automount:  files nisplus sss
aliases:    files nisplus
EOF

  # Создание файлов сопоставления пользователей
  mkdir -p /usr/local/samba/etc/
  echo "!root = $DOMAIN\\$ADMIN_USER" > /usr/local/samba/etc/user.map
  echo "!root = $DOMAIN\\$ADMIN_USER" > /etc/samba/user.map

  # Запуск служб
  systemctl enable smbd nmbd winbind
  systemctl start smbd nmbd winbind

  echo -e "${GREEN}Полная установка Samba завершена!${NC}"
  read -p "Нажмите Enter для продолжения..."
}

# Функция управления доменным подключением
function domain_membership() {
  print_header
  echo -e "${GREEN}=== УПРАВЛЕНИЕ ДОМЕННЫМ ПОДКЛЮЧЕНИЕМ ===${NC}"
  
  if check_domain_join; then
    echo -e "Текущий статус: ${GREEN}сервер в домене${NC}"
    echo -e "\n1. Оставить как есть"
    echo -e "2. Удалить из домена"
    echo -e "3. Переприсоединить к домену"
    read -p "Выберите действие (1-3): " DOMAIN_CHOICE
    
    case $DOMAIN_CHOICE in
      1) 
        echo -e "${GREEN}Доменное подключение не изменено${NC}"
        ;;
      2)
        echo -e "${YELLOW}Удаление из домена...${NC}"
        read -p "Введите логин администратора домена: " ADMIN_USER
        leave_domain
        ;;
      3)
        echo -e "${YELLOW}Переприсоединение к домену...${NC}"
        get_domain_info
        read -p "Введите логин администратора домена: " ADMIN_USER
        net ads leave -U "$ADMIN_USER"
        net ads join -U "$ADMIN_USER"
        systemctl restart smbd nmbd winbind
        echo -e "${GREEN}Сервер успешно переприсоединен к домену${NC}"
        ;;
      *)
        echo -e "${RED}Неверный выбор!${NC}"
        ;;
    esac
  else
    echo -e "Текущий статус: ${RED}сервер не в домене${NC}"
    read -p "Присоединить сервер к домену? (y/N): " JOIN_CHOICE
    if [[ $JOIN_CHOICE =~ ^[Yy]$ ]]; then
      get_domain_info
      read -p "Введите логин администратора домена: " ADMIN_USER
      net ads join -U "$ADMIN_USER"
      systemctl restart smbd nmbd winbind
      echo -e "${GREEN}Сервер успешно присоединен к домену${NC}"
    fi
  fi
  read -p "Нажмите Enter для продолжения..."
}

# Функция добавления папки
function add_share() {
  print_header
  echo -e "${GREEN}=== ДОБАВЛЕНИЕ ОБЩЕЙ ПАПКИ ===${NC}"
  
  if [ ! -f "/etc/samba/smb.conf" ]; then
    echo -e "${RED}Ошибка: Samba не установлена или файл конфигурации не найден!${NC}"
    read -p "Нажмите Enter для возврата в меню..."
    return
  fi

  get_domain_info

  read -p "Введите название общей папки (для отображения в сети): " SHARE_NAME
  read -p "Введите полный путь к папке (например, /smbpool/folder1): " SHARE_PATH
  read -p "Введите путь для корзины (например, /smbpool/folder1/.trash): " RECYCLE_PATH

  # Создание папок
  echo -e "${GREEN}Создание папок...${NC}"
  mkdir -p "$SHARE_PATH" || { echo -e "${RED}Ошибка создания папки!${NC}"; exit 1; }
  mkdir -p "$RECYCLE_PATH" || { echo -e "${RED}Ошибка создания корзины!${NC}"; exit 1; }

  # Добавление раздела в smb.conf
  echo -e "${GREEN}Обновление конфигурации Samba...${NC}"
  cat >> /etc/samba/smb.conf <<EOF

[$SHARE_NAME]
        path = $SHARE_PATH
        read only = no
        vfs objects = recycle
        recycle:repository = $RECYCLE_PATH
        recycle:keeptree = yes
        recycle:versions = yes
        recycle:touch = yes
        recycle:exclude = *.tmp *.temp *.log *.trace *.iso ~\$* *.docx# ~~\$*.pdf
EOF

  # Установка прав
  echo -e "${GREEN}Установка прав...${NC}"
  if [ -n "$DOMAIN" ] && [ -n "$DOMAIN_ADMINS" ]; then
    chown -R "root:$DOMAIN\\$DOMAIN_ADMINS" "$SHARE_PATH" || echo -e "${YELLOW}Не удалось установить владельца папки${NC}"
    chmod -R 0770 "$SHARE_PATH"
    chown -R "root:$DOMAIN\\$DOMAIN_ADMINS" "$RECYCLE_PATH" || echo -e "${YELLOW}Не удалось установить владельца корзины${NC}"
    chmod -R 0770 "$RECYCLE_PATH"
  else
    chown -R root:root "$SHARE_PATH"
    chmod -R 0770 "$SHARE_PATH"
    chown -R root:root "$RECYCLE_PATH"
    chmod -R 0770 "$RECYCLE_PATH"
    echo -e "${YELLOW}Информация о домене не найдена, установлены права root:root${NC}"
  fi

  # Перезагрузка сервисов
  echo -e "${GREEN}Перезагрузка сервисов Samba...${NC}"
  systemctl restart smbd nmbd

  echo -e "${GREEN}Общая папка успешно добавлена!${NC}"
  echo -e "Имя папки: ${SHARE_NAME}"
  echo -e "Путь: ${SHARE_PATH}"
  echo -e "Корзина: ${RECYCLE_PATH}"
  read -p "Нажмите Enter для продолжения..."
}

# Функция отображения списка общих папок с номерами
function list_shares() {
  local shares=()
  while IFS= read -r line; do
    shares+=("$line")
  done < <(grep -E '^\[[^]]+\]' /etc/samba/smb.conf | grep -v global | tr -d '[]')
  
  if [ ${#shares[@]} -eq 0 ]; then
    echo -e "${RED}Нет настроенных общих папок${NC}"
    return 1
  fi
  
  echo -e "${BLUE}Список общих папок:${NC}"
  for i in "${!shares[@]}"; do
    echo "$((i+1)). ${shares[$i]}"
  done
  return 0
}

# Функция удаления папки по номеру
function remove_share_by_number() {
  print_header
  echo -e "${GREEN}=== УДАЛЕНИЕ ОБЩЕЙ ПАПКИ ===${NC}"
  
  if ! list_shares; then
    read -p "Нажмите Enter для возврата в меню..."
    return
  fi
  
  read -p "Введите номер папки для удаления: " SHARE_NUM
  mapfile -t shares < <(grep -E '^\[[^]]+\]' /etc/samba/smb.conf | grep -v global | tr -d '[]')
  
  if ! [[ "$SHARE_NUM" =~ ^[0-9]+$ ]] || [ "$SHARE_NUM" -lt 1 ] || [ "$SHARE_NUM" -gt "${#shares[@]}" ]; then
    echo -e "${RED}Неверный номер папки!${NC}"
    read -p "Нажмите Enter для продолжения..."
    return
  fi
  
  SHARE_NAME="${shares[$((SHARE_NUM-1))]}"
  
  # Получаем путь к папке
  SHARE_PATH=$(awk -v section="$SHARE_NAME" -v RS='\n\\[' '/\['section'\]/ {print; while(getline && $0 !~ /^\[/) {if($0 ~ /path *= */) {print $3; exit}}}' /etc/samba/smb.conf)
  RECYCLE_PATH=$(awk -v section="$SHARE_NAME" -v RS='\n\\[' '/\['section'\]/ {print; while(getline && $0 !~ /^\[/) {if($0 ~ /recycle:repository *= */) {print $3; exit}}}' /etc/samba/smb.conf)

  # Удаление раздела из smb.conf
  echo -e "${YELLOW}Удаление конфигурации для '$SHARE_NAME'...${NC}"
  sed -i "/\[$SHARE_NAME\]/,/^$/d" /etc/samba/smb.conf

  # Вопрос об удалении файлов
  if [ -n "$SHARE_PATH" ]; then
    read -p "Удалить файлы папки '$SHARE_PATH'? (y/N): " DELETE_FILES
    if [[ $DELETE_FILES =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}Удаление файлов...${NC}"
      rm -rf "$SHARE_PATH"
      # Также удаляем корзину, если она находится внутри папки
      if [[ -n "$RECYCLE_PATH" && "$RECYCLE_PATH" == "$SHARE_PATH"* ]]; then
        rm -rf "$RECYCLE_PATH"
      fi
    fi
  fi

  # Перезагрузка сервисов
  echo -e "${YELLOW}Перезагрузка сервисов Samba...${NC}"
  systemctl restart smbd nmbd

  echo -e "${GREEN}Общая папка '$SHARE_NAME' успешно удалена!${NC}"
  read -p "Нажмите Enter для продолжения..."
}

# Функция проверки состояния
function check_status() {
  print_header
  echo -e "${GREEN}=== СОСТОЯНИЕ СИСТЕМЫ ===${NC}"
  
  # Проверка служб
  echo -e "${YELLOW}Службы:${NC}"
  systemctl status smbd nmbd winbind | grep -E '●|Active:'
  
  # Проверка домена
  echo -e "\n${YELLOW}Домен:${NC}"
  if check_domain_join; then
    echo -e "${GREEN}Подключение к домену активно${NC}"
    echo -e "Информация о домене:"
    realm list
  else
    echo -e "${RED}Нет подключения к домену${NC}"
  fi
  
  # Список общих папок
  echo -e "\n${YELLOW}Общие папки:${NC}"
  list_shares
  
  read -p "Нажмите Enter для продолжения..."
}

# Главное меню
while true; do
  print_header
  echo -e "${GREEN}ГЛАВНОЕ МЕНЮ:${NC}"
  echo -e "1. Полная установка Samba (доменный член)"
  echo -e "2. Управление доменным подключением"
  echo -e "3. Добавить общую папку"
  echo -e "4. Удалить общую папку (по номеру)"
  echo -e "5. Проверить состояние системы"
  echo -e "6. Выход"
  echo
  read -p "Выберите действие (1-6): " CHOICE

  case $CHOICE in
    1) 
      install_samba 
      ;;
    2) domain_membership ;;
    3) add_share ;;
    4) remove_share_by_number ;;
    5) check_status ;;
    6) echo -e "${GREEN}Выход...${NC}"; exit 0 ;;
    *) echo -e "${RED}Неверный выбор!${NC}"; sleep 1 ;;
  esac
done