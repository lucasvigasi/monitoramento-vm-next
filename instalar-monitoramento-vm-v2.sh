#!/bin/bash

SCRIPT_NAME="alerta-monitor-v2"
SCRIPT_PATH="/usr/local/bin/${SCRIPT_NAME}"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"

echo "=== Instalador do ${SCRIPT_NAME} ==="

# 1. Cria o script de monitoramento (com BOT_TOKEN e CHAT_IDS fixos) CUIDADO!!!
cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash

# Configurações
BOT_TOKEN="^_^^_^^_^^_^^_^^_^^_^"
CHAT_IDS=("lucas""anderson" "cesar" "willian")
LOG_FILE="/var/log/alerta-monitor-v2.log"
STATE_DIR="/var/lib/alerta-monitor-v2"
mkdir -p "$STATE_DIR"

# Thresholds
RAM_THRESHOLD_MB=300
DISK_THRESHOLD_MB=$((15 * 1024))  # 15 GB em MB

# Horário mínimo para envio de alertas (09:00)
HORA_MINIMA="09:00"

# Função para enviar alerta
send_alert() {
    local message="$1"
    for CHAT_ID in "${CHAT_IDS[@]}"; do
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="${CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="Markdown" >> "$LOG_FILE" 2>&1
    done
}

# Função para registrar log local
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Função para verificar se é permitido enviar alerta (máx. 2/dia e intervalo de 2h)
can_send_alert() {
    local type="$1"   # "RAM" ou "DISK"
    local now_ts=$(date +%s)
    local state_file="${STATE_DIR}/${type}_alert"
    local current_time=$(date +"%H:%M")

    # Bloqueia antes de 09:00
    if [[ "$current_time" < "$HORA_MINIMA" ]]; then
        log_message "INFO: Horário atual $current_time é antes de $HORA_MINIMA. Alerta $type bloqueado."
        return 1
    fi

    # Se nunca enviou hoje, cria estado com count=1
    if [ ! -f "$state_file" ]; then
        echo "1 $now_ts" > "$state_file"
        return 0
    fi

    # Lê count e timestamp do último alerta
    read -r count last_ts < "$state_file"
    last_date=$(date -d @"$last_ts" +%F)
    today=$(date +%F)

    # Se foi em dia diferente, reinicia contador
    if [ "$last_date" != "$today" ]; then
        echo "1 $now_ts" > "$state_file"
        return 0
    fi

    # Se ainda não chegou a 2 alerts e já se passaram >=2h
    if (( count < 2 )) && (( now_ts - last_ts >= 7200 )); then
        count=$((count + 1))
        echo "$count $now_ts" > "$state_file"
        return 0
    fi

    log_message "INFO: Alerta $type já enviado $count vezes hoje. Próximo só após 2h e se count<2."
    return 1
}

# Coleta dados do sistema
HOSTNAME=$(hostname)
IP_ADDRESS=$(hostname -I | awk '{print $1}')

# RAM
RAM_TOTAL_MB=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED_MB=$(free -m | awk '/Mem:/ {print $3}')
RAM_FREE_MB=$((RAM_TOTAL_MB - RAM_USED_MB))

# Disco em /var
DISK_FREE_MB=$(df -Pm /var | awk 'NR==2 {print $4}')

# --- Verifica RAM ---
if [ "$RAM_FREE_MB" -lt "$RAM_THRESHOLD_MB" ]; then
    MESSAGE="⚠️ *ALERTA DE MEMÓRIA* ⚠️
Servidor: \`${HOSTNAME}\` \`${IP_ADDRESS}\`
Memória livre: \`${RAM_FREE_MB} MB\`
Memória usada: \`${RAM_USED_MB} MB / ${RAM_TOTAL_MB} MB\`"

    if can_send_alert "RAM"; then
        send_alert "$MESSAGE"
        log_message "ALERTA ENVIADO: Memória baixa - ${RAM_FREE_MB} MB livres (${RAM_USED_MB} MB usados)."
    fi
else
    # Reseta estado se RAM normalizou (apaga arquivo para começar novo dia)
    rm -f "${STATE_DIR}/RAM_alert"
    log_message "OK: Memória - ${RAM_FREE_MB} MB livres (${RAM_USED_MB} MB usados)."
fi

# --- Verifica Disco ---
if [ "$DISK_FREE_MB" -lt "$DISK_THRESHOLD_MB" ]; then
    read -r -d '' MESSAGE <<DISK_EOF
⚠️ *ALERTA DE DISCO* ⚠️
Servidor: \`${HOSTNAME}\`
IP: \`${IP_ADDRESS}\`
Espaço livre em /var: \`$((DISK_FREE_MB / 1024)) GB\`
DISK_EOF

    if can_send_alert "DISK"; then
        send_alert "$MESSAGE"
        log_message "ALERTA ENVIADO: Espaço em disco baixo - $((DISK_FREE_MB / 1024)) GB disponíveis em /var."
    fi
else
    rm -f "${STATE_DIR}/DISK_alert"
    log_message "OK: Disco - $((DISK_FREE_MB / 1024)) GB disponíveis em /var."
fi

EOF

# 2. Ajusta permissões
chmod +x "$SCRIPT_PATH"
echo "[OK] Script instalado em ${SCRIPT_PATH}"

# 3. Cria arquivo de log e diretório de estado
mkdir -p /var/lib/alerta-monitor-v2
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    echo "[OK] Arquivo de log criado em ${LOG_FILE}"
fi

# 4. Pergunta se quer adicionar ao cron
read -p "Deseja agendar o monitoramento no cron a cada 5 minutos? (s/n): " ADD_CRON

if [[ "$ADD_CRON" =~ ^[Ss]$ ]]; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * ${SCRIPT_PATH}") | crontab -
    echo "[OK] Tarefa agendada no cron para rodar a cada 5 minutos."
else
    echo "[INFO] Agendamento no cron ignorado."
fi

echo "=== Instalação concluída com sucesso! ==="
