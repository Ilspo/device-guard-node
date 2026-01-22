#!/bin/bash

# Цвета для красоты
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}--- Установка Device Guard Node ---${NC}"

# Запрос данных, если они не переданы аргументами
BOT_DOMAIN=$1
SECRET_KEY=$2

if [ -z "$BOT_DOMAIN" ]; then
    read -p "Введите домен бота (например, bot.domain.com): " BOT_DOMAIN
fi

if [ -z "$SECRET_KEY" ]; then
    read -p "Введите секретный ключ (X-Api-Key): " SECRET_KEY
fi

# Проверка на пустые значения
if [ -z "$BOT_DOMAIN" ] || [ -z "$SECRET_KEY" ]; then
    echo "Ошибка: Домен и ключ обязательны!"
    exit 1
fi

LOG_PATH="/var/log/remnanode/access.log"

# 1. Установка зависимостей
echo -e "${GREEN}[1/5]${NC} Проверка gawk и curl..."
sudo apt update && sudo apt install gawk curl -y

# 2. Создание структуры папок
echo -e "${GREEN}[2/5]${NC} Подготовка папок..."
sudo mkdir -p /opt/device-guard
sudo mkdir -p $(dirname "$LOG_PATH")
[ -f "$LOG_PATH" ] || sudo touch "$LOG_PATH"

# 3. Создание скрипта отчета (с экранированием $)
echo -e "${GREEN}[3/5]${NC} Создание скрипта /opt/device-guard/report.sh..."
cat <<EOF | sudo tee /opt/device-guard/report.sh > /dev/null
#!/bin/bash

WEBHOOKS=(
  "https://$BOT_DOMAIN/device-report|$SECRET_KEY"
)
TIME_WINDOW=15
LOG_FILE="$LOG_PATH"

DATA=\$(tail -n 10000 "\$LOG_FILE" 2>/dev/null | \\
  awk -v window="\$TIME_WINDOW" '
  /email:/ {
    split(\$1, d, "/")
    split(\$2, t, ":")
    split(t[3], sec, ".")
    ts = mktime(d[1] " " d[2] " " d[3] " " t[1] " " t[2] " " sec[1])

    match(\$0, /from ([0-9.]+):/, iparr)
    match(\$0, /email: ([0-9]+)/, emarr)
    if(iparr[1] && emarr[1]) {
      n = ++total
      all_ts[n] = ts
      all_ip[n] = iparr[1]
      all_em[n] = emarr[1]
      if (ts > global_max) global_max = ts
    }
  }
  END {
    threshold = global_max - window

    for (i = 1; i <= total; i++) {
      if (all_ts[i] >= threshold) {
        em = all_em[i]
        ip = all_ip[i]
        key = em SUBSEP ip
        if (!(key in seen)) {
          seen[key] = 1
          users[em] = users[em] ? users[em] ",\"" ip "\"" : "\"" ip "\""
        }
      }
    }

    printf "{\"ts\":%d,\"users\":{", systime()
    first = 1
    for (em in users) {
      if (!first) printf ","
      printf "\"%s\":[%s]", em, users[em]
      first = 0
    }
    print "}}"
  }')

for entry in "\${WEBHOOKS[@]}"; do
  URL="\${entry%%|*}"
  KEY="\${entry##*|}"
  echo "\$DATA" | curl -s -X POST "\$URL" \\
    -H "Content-Type: application/json" \\
    -H "X-Api-Key: \$KEY" \\
    -d @- > /dev/null 2>&1 &
done
wait
EOF

# 4. Права
echo -e "${GREEN}[4/5]${NC} Настройка прав..."
sudo chmod +x /opt/device-guard/report.sh
sudo chmod -R 777 $(dirname "$LOG_PATH")

# 5. Cron
echo -e "${GREEN}[5/5]${NC} Добавление в автозапуск (cron)..."
CRON_JOB="*/2 * * * * /opt/device-guard/report.sh"
(sudo crontab -l 2>/dev/null | grep -v "report.sh" ; echo "$CRON_JOB") | sudo crontab -

echo -e "${YELLOW}--- Установка завершена! ---${NC}"
echo "Тестовая проверка связи..."
curl -i -X POST "https://$BOT_DOMAIN/device-report" \
     -H "Content-Type: application/json" \
     -H "X-Api-Key: $SECRET_KEY" \
     -d '{"ts":1700000000,"users":{}}'
