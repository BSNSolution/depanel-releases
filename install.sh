#!/bin/sh
# Bsn Depanel — instalador de 1 comando (VM, VPS ou servidor dedicado, Linux amd64/arm64).
#
#   curl -sSL https://<endereço>/install.sh | sh
#   curl -sSL https://<endereço>/install.sh | sh -s -- --dominio painel.exemplo.com.br --email voce@exemplo.com.br
#
# Rodar de novo atualiza (mantém configuração e dados). Opções:
#   --dominio <host>        endereço do painel (sem ele: <ip-público>.sslip.io)
#   --email <e-mail>        e-mail dos avisos do Let's Encrypt (a conta de admin é criada pela tela)
#   --borda <cidr>          proxy à frente que manda PROXY protocol (ex.: 203.0.113.10/32)
#   --imagem <imagem>       imagem do painel (padrão abaixo)
#   --imagem-arquivo <tar>  carrega a imagem de um arquivo (docker save), sem baixar
#   --pasta <caminho>       onde instalar (padrão /opt/depanel)
#   --sim                   não pergunta nada (usa os padrões)
#   --casa                  só para testar no seu computador (Mac, Linux ou WSL), sem root e sem
#                           systemd: tudo no Docker, painel em http://localhost:7420
#
# ESTE ARQUIVO É GERADO por deploy/montar-instalador.mts a partir de deploy/instalador.modelo.sh.
set -eu

VERSAO="0.3.1"
IMAGEM_PADRAO="ghcr.io/bsnsolution/bsn-depanel:${VERSAO}"

# Tudo dentro de funções: se o download cortar no meio, nada roda pela metade.

cor() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
passo() { printf '%s %s\n' "$(cor '1;35' '==>')" "$1"; }
aviso() { printf '%s %s\n' "$(cor '1;33' 'aviso:')" "$1" >&2; }
erro() { printf '%s %s\n' "$(cor '1;31' 'erro:')" "$1" >&2; exit 1; }
tem() { command -v "$1" >/dev/null 2>&1; }

# Perguntas leem do terminal (o script em si chega pela entrada padrão do "| sh").
perguntar() {
  _p="$1"; _padrao="$2"
  if [ "$SEM_PERGUNTAS" = 1 ] || [ ! -r /dev/tty ]; then printf '%s' "$_padrao"; return; fi
  printf '%s [%s]: ' "$_p" "$_padrao" >/dev/tty
  read -r _r </dev/tty || _r=""
  printf '%s' "${_r:-$_padrao}"
}

aleatorio_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
aleatorio_b64() { head -c "$1" /dev/urandom | base64 | tr -d '\n'; }

ip_publico() {
  for _u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    _ip=$(curl -fsS --max-time 5 "$_u" 2>/dev/null | tr -d ' \n' || true)
    case "$_ip" in *.*.*.*) printf '%s' "$_ip"; return ;; esac
  done
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

porta_ocupada() {
  if tem ss; then ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; return; fi
  if tem netstat; then netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"; return; fi
  return 1
}

ajuda() {
  cat <<'FIM_AJUDA'
Bsn Depanel — instalador. Uso: curl -sSL <endereço>/install.sh | sudo sh -s -- [opções]
  --dominio <host>        endereço do painel (sem ele: <ip-público>.sslip.io)
  --email <e-mail>        e-mail dos avisos do Let's Encrypt (a conta de admin é criada pela tela)
  --borda <cidr>          proxy à frente que manda PROXY protocol (ex.: 203.0.113.10/32)
  --imagem <imagem>       imagem do painel
  --imagem-arquivo <tar>  carrega a imagem de um arquivo (docker save)
  --pasta <caminho>       onde instalar (padrão /opt/depanel)
  --sim                   não pergunta nada
  --casa                  testar no seu computador só com Docker (sem root): curl … | sh -s -- --casa
Rodar de novo atualiza (mantém configuração e dados).
FIM_AJUDA
}

ler_opcoes() {
  DOMINIO=""; EMAIL=""; BORDA="127.0.0.1/32"; IMAGEM=""; IMAGEM_ARQUIVO=""; PASTA=""; SEM_PERGUNTAS=0; CASA=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dominio) DOMINIO="${2:-}"; shift 2 ;;
      --email) EMAIL="${2:-}"; shift 2 ;;
      --borda) BORDA="${2:-}"; shift 2 ;;
      --imagem) IMAGEM="${2:-}"; shift 2 ;;
      --imagem-arquivo) IMAGEM_ARQUIVO="${2:-}"; shift 2 ;;
      --pasta) PASTA="${2:-}"; shift 2 ;;
      --sim|-y) SEM_PERGUNTAS=1; shift ;;
      --casa) CASA=1; shift ;;
      -h|--help) ajuda; exit 0 ;;
      *) erro "opção desconhecida: $1 (use --help)" ;;
    esac
  done
  case "$DOMINIO" in *[!A-Za-z0-9.-]*) erro "domínio inválido: $DOMINIO" ;; esac
  case "$BORDA" in *[!0-9a-fA-F:./,]*) erro "--borda inválida: $BORDA" ;; esac
  if [ -z "$PASTA" ]; then
    if [ "$CASA" = 1 ]; then PASTA="${HOME:-.}/depanel-casa"; else PASTA="/opt/depanel"; fi
  fi
}

# Modo "em casa": grava os 3 arquivos do compose de teste e chama o iniciar.sh (sem root, sem systemd).
instalar_casa() {
  tem docker || erro "instale o Docker (Docker Desktop, OrbStack ou o Docker do Linux) e rode de novo."
  docker info >/dev/null 2>&1 || erro "o Docker não respondeu: abra o Docker Desktop/OrbStack e tente de novo."
  passo "Bsn Depanel $VERSAO em casa — em $PASTA"
  mkdir -p "$PASTA"
  cat >"$PASTA/compose.yml" <<'FIM_CASA_COMPOSE_DEPANEL'
# Bsn Depanel — modo "em casa": tudo no Docker do seu computador, sem root nem systemd.
# Para testar e aprender (simula uma VPS). Uso: ./iniciar.sh  (ou docker compose --env-file .env up -d)
# O painel abre em http://localhost:7420. O agente desta máquina roda num contêiner e cuida do Docker
# do seu computador (os apps que você criar sobem aqui mesmo, ao lado deste compose).
name: depanel-casa

services:
  api:
    image: ${DEPANEL_IMAGEM:-ghcr.io/bsnsolution/bsn-depanel:0.3.1}
    restart: unless-stopped
    env_file: .env
    environment:
      DEPANEL_URL: http://localhost:${DEPANEL_PORTA_PAINEL:-7420}
      DATABASE_URL: postgres://depanel:${DEPANEL_PG_SENHA}@postgres:5432/depanel
      DEPANEL_VICTORIA_URL: http://victoria:8428
      DEPANEL_HOST: 0.0.0.0
      DEPANEL_PASTA_FONTES: /fontes
      # O agente em contêiner baixa pacotes de código pela rede interna.
      DEPANEL_URL_AGENTE: http://api:7420
      DEPANEL_AGENTE_LOCAL: /agente-local
    ports:
      - "127.0.0.1:${DEPANEL_PORTA_PAINEL:-7420}:7420"
    volumes:
      - fontes:/fontes
      - agente-local:/agente-local
    depends_on:
      postgres:
        condition: service_healthy
      victoria:
        condition: service_healthy
    stop_grace_period: 20s

  worker:
    image: ${DEPANEL_IMAGEM:-ghcr.io/bsnsolution/bsn-depanel:0.3.1}
    restart: unless-stopped
    command: ["node", "apps/worker/dist/principal.js"]
    env_file: .env
    environment:
      DEPANEL_URL: http://localhost:${DEPANEL_PORTA_PAINEL:-7420}
      DATABASE_URL: postgres://depanel:${DEPANEL_PG_SENHA}@postgres:5432/depanel
    healthcheck:
      disable: true
    depends_on:
      api:
        condition: service_healthy

  # O agente "Este computador": fala com o Docker daqui pelo socket. O painel deixa a chave e o token
  # de cadastro no volume agente-local; o script baixa o binário do próprio painel e confere o SHA-256.
  agente:
    image: debian:trixie-slim
    restart: unless-stopped
    entrypoint: ["/bin/sh", "/agente.sh"]
    environment:
      DEPANEL_PAINEL: http://api:7420
      DEPANEL_PROXY_ENDERECO: host.docker.internal
      DEPANEL_SMART: "nao"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./agente.sh:/agente.sh:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - agente-local:/agente-local:ro
      - agente-dados:/var/lib/depanel-agente
    depends_on:
      api:
        condition: service_healthy

  postgres:
    image: postgres:17.11-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: depanel
      POSTGRES_PASSWORD: ${DEPANEL_PG_SENHA}
      POSTGRES_DB: depanel
    volumes:
      - postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U depanel -d depanel"]
      interval: 5s
      timeout: 5s
      retries: 20

  victoria:
    image: victoriametrics/victoria-metrics:v1.154.0
    restart: unless-stopped
    command:
      - -storageDataPath=/dados
      - -retentionPeriod=30d
      - -httpListenAddr=:8428
    volumes:
      - victoria:/dados
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8428/health"]
      interval: 10s
      timeout: 5s
      retries: 10

volumes:
  postgres:
  victoria:
  fontes:
  agente-local:
  agente-dados:
FIM_CASA_COMPOSE_DEPANEL
  cat >"$PASTA/agente.sh" <<'FIM_CASA_AGENTE_DEPANEL'
#!/bin/sh
# Agente do Bsn Depanel em contêiner (modo "em casa"). Espera o painel cadastrar "Este computador",
# baixa o binário do próprio painel, confere o SHA-256 e roda. O token de uso único sai do arquivo de
# configuração depois que o painel aceita o agente (nas próximas subidas não vai mais).
set -eu
LOCAL=/agente-local
DADOS=/var/lib/depanel-agente
mkdir -p "$DADOS"

if ! command -v docker >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "[agente] instalando docker-cli, compose, git e curl (só na primeira vez)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends docker-cli docker-compose git ca-certificates curl iputils-ping >/dev/null
fi

until [ -s "$LOCAL/chave-painel" ] && [ -s "$LOCAL/maquina-id" ]; do
  echo "[agente] esperando o painel: crie a sua conta de dono em http://localhost:7420 (ou rode ./iniciar.sh)"
  sleep 5
done

case "$(uname -m)" in
  x86_64|amd64) ARQ=linux-amd64 ;;
  aarch64|arm64) ARQ=linux-arm64 ;;
  *) echo "[agente] processador $(uname -m) não suportado"; exit 1 ;;
esac
# O instalador do painel traz o SHA-256 de cada binário.
SHA=$(curl -fsS "$DEPANEL_PAINEL/agente/instalar.sh" | sed -n "s/^SHA_$(echo "$ARQ" | sed 's/linux-//' | tr 'a-z' 'A-Z')='\([0-9a-f]*\)'.*/\1/p")
[ -n "$SHA" ] || { echo "[agente] o painel não informou o SHA-256 do binário $ARQ"; exit 1; }
BIN=/usr/local/bin/depanel-agente
if [ ! -x "$BIN" ] || [ "$(sha256sum "$BIN" | cut -d' ' -f1)" != "$SHA" ]; then
  curl -fsS "$DEPANEL_PAINEL/agente/binario/$ARQ" -o "$BIN.novo"
  [ "$(sha256sum "$BIN.novo" | cut -d' ' -f1)" = "$SHA" ] || { echo "[agente] SHA-256 do binário não confere"; rm -f "$BIN.novo"; exit 1; }
  chmod 755 "$BIN.novo" && mv "$BIN.novo" "$BIN"
fi

CONF="$DADOS/agente.env"
if [ ! -f "$CONF" ]; then
  printf 'DEPANEL_TOKEN=%s\n' "$(cat "$LOCAL/token")" > "$CONF"
  chmod 600 "$CONF"
fi
set -a
. "$CONF"
set +a
export DEPANEL_CHAVE_PAINEL="$(cat "$LOCAL/chave-painel")"
export DEPANEL_ARQUIVO_ENV="$CONF"
export DEPANEL_DADOS="$DADOS"
exec "$BIN"
FIM_CASA_AGENTE_DEPANEL
  cat >"$PASTA/iniciar.sh" <<'FIM_CASA_INICIAR_DEPANEL'
#!/bin/sh
# Bsn Depanel em casa: sobe o painel no Docker do seu computador (Mac, Linux ou Windows com WSL),
# sem root e sem systemd. Uso:
#   ./iniciar.sh            sobe (na 1ª vez cria os segredos e pede os dados do dono)
#   ./iniciar.sh --parar    para tudo (os dados ficam)
#   ./iniciar.sh --apagar   para e APAGA tudo (banco, métricas, apps de teste continuam no seu Docker)
set -eu
cd "$(dirname "$0")"

erro() { printf '\n  ✗ %s\n\n' "$1" >&2; exit 1; }
passo() { printf '  → %s\n' "$1"; }

command -v docker >/dev/null 2>&1 || erro "Instale o Docker (Docker Desktop, OrbStack ou o Docker do Linux) e rode de novo."
docker info >/dev/null 2>&1 || erro "O Docker não respondeu. Abra o Docker Desktop/OrbStack (ou: sudo usermod -aG docker \$USER) e tente de novo."
docker compose version >/dev/null 2>&1 || erro "Falta o 'docker compose' (vem no Docker Desktop; no Linux: pacote docker-compose-plugin)."

case "${1:-}" in
  --parar) docker compose --env-file .env down; exit 0 ;;
  --apagar)
    printf '  Isto apaga o banco e as métricas do Depanel de teste. Digite APAGAR para confirmar: '
    read -r c
    [ "$c" = "APAGAR" ] || erro "Cancelado."
    docker compose --env-file .env down -v
    rm -f .env
    exit 0 ;;
  '') ;;
  *) erro "Opção desconhecida: $1" ;;
esac

aleatorio_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
aleatorio_b64() { head -c "$1" /dev/urandom | base64 | tr -d '\n'; }

if [ ! -f .env ]; then
  passo "Criando os segredos deste painel (.env)"
  umask 077
  cat > .env <<EOF
# Bsn Depanel em casa — gerado em $(date '+%d/%m/%Y %H:%M'). Não compartilhe este arquivo.
DEPANEL_PG_SENHA=$(aleatorio_hex 24)
DEPANEL_CHAVES_MESTRAS=v1:$(aleatorio_b64 32)
DEPANEL_SEGREDO_SESSAO=$(aleatorio_hex 32)
DEPANEL_LOG_NIVEL=info
# DEPANEL_PORTA_PAINEL=7420
EOF
  if [ -n "${DEPANEL_IMAGEM:-}" ]; then printf 'DEPANEL_IMAGEM=%s\n' "$DEPANEL_IMAGEM" >> .env; fi
fi
# A atualização pelo painel precisa saber onde está esta instalação.
grep -q '^DEPANEL_PASTA_INSTALACAO=' .env || printf 'DEPANEL_PASTA_INSTALACAO=%s\n' "$(pwd)" >> .env

passo "Subindo o painel (a 1ª vez baixa as imagens; pode levar alguns minutos)"
docker compose --env-file .env up -d

passo "Esperando o painel ficar pronto"
i=0
until [ "$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose --env-file .env ps -q api)" 2>/dev/null)" = "healthy" ]; do
  i=$((i + 1))
  [ "$i" -lt 90 ] || { docker compose --env-file .env logs --tail 40 api >&2; erro "O painel não ficou pronto em 3 minutos (log acima)."; }
  sleep 2
done

USUARIOS=$(docker compose --env-file .env exec -T postgres psql -U depanel -d depanel -tAc "select count(*) from usuario" 2>/dev/null | tr -d '[:space:]' || echo 0)
CODIGO=""
if [ "${USUARIOS:-0}" = "0" ]; then
  if [ -n "${DEPANEL_ADMIN_EMAIL:-}" ] && [ -n "${DEPANEL_ADMIN_SENHA:-}" ]; then
    # Sem tela (automação): os dados do dono vêm do ambiente.
    docker compose --env-file .env exec -T -e DEPANEL_ADMIN_EMAIL -e DEPANEL_ADMIN_SENHA \
      -e DEPANEL_ADMIN_NOME="${DEPANEL_ADMIN_NOME:-Dono}" api node apps/api/dist/criar-admin.js >/dev/null ||
      erro "Não consegui criar o dono."
  else
    # O painel gera o código de uso único do primeiro acesso no volume do agente local.
    i=0
    until CODIGO=$(docker compose --env-file .env exec -T api cat /agente-local/primeiro-acesso 2>/dev/null | tr -d '[:space:]') && [ -n "$CODIGO" ]; do
      i=$((i + 1)); [ "$i" -lt 15 ] || break; sleep 1
    done
  fi
fi

PORTA=$(sed -n 's/^DEPANEL_PORTA_PAINEL=//p' .env)
if [ -n "$CODIGO" ]; then
  printf '\n  ✓ Pronto! Crie a conta de administrador (o link só vale uma vez):\n'
  printf '    http://localhost:%s/primeiro-acesso#%s\n' "${PORTA:-7420}" "$CODIGO"
else
  printf '\n  ✓ Pronto! Abra http://localhost:%s\n' "${PORTA:-7420}"
fi
printf '    O agente "Este computador" aparece em Máquinas em alguns segundos.\n'
printf '    Para parar: ./iniciar.sh --parar · para apagar tudo: ./iniciar.sh --apagar\n\n'
FIM_CASA_INICIAR_DEPANEL
  chmod 755 "$PASTA/agente.sh" "$PASTA/iniciar.sh"
  # A imagem escolhida entra no .env na 1ª subida (depois vale o que estiver no .env).
  [ -z "$IMAGEM" ] || export DEPANEL_IMAGEM="$IMAGEM"
  [ -z "$IMAGEM_ARQUIVO" ] || docker load -i "$IMAGEM_ARQUIVO" >/dev/null
  if [ -r /dev/tty ]; then exec sh "$PASTA/iniciar.sh" </dev/tty; else exec sh "$PASTA/iniciar.sh"; fi
}

conferir_sistema() {
  [ "$(uname -s)" = Linux ] || erro "o Depanel instala em Linux (VM, VPS ou dedicado)."
  case "$(uname -m)" in x86_64|amd64|aarch64|arm64) ;; *) erro "arquitetura $(uname -m) não suportada (use amd64 ou arm64)." ;; esac
  [ "$(id -u)" = 0 ] || erro "rode como root: curl -sSL <endereço>/install.sh | sudo sh"
  tem curl || erro "precisa do curl."
  _mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  [ "$_mem" -ge 1800 ] || aviso "a máquina tem ${_mem} MB de memória; o recomendado é 2 GB ou mais."
}

# Faixas de rede do Docker: o padrão só dá ~30 redes (cada ambiente do Depanel usa uma). Com /24
# a partir de 172.20.0.0/14 cabem 1024. Só é gravado num Docker novo; num existente, só avisa.
POOLS_DOCKER='{"default-address-pools":[{"base":"172.20.0.0/14","size":24}]}'

conferir_redes_docker() {
  if [ -f /etc/docker/daemon.json ] && grep -q default-address-pools /etc/docker/daemon.json; then
    return
  fi
  aviso "o Docker desta máquina usa as faixas de rede padrão (cabem só ~30 redes; cada ambiente usa uma)."
  aviso "para caber mais, em um horário calmo: acrescente $POOLS_DOCKER em /etc/docker/daemon.json e rode 'systemctl restart docker' (os contêineres reiniciam)."
}

instalar_docker() {
  if tem docker && docker compose version >/dev/null 2>&1; then
    passo "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') já instalado"
    conferir_redes_docker
    return
  fi
  if [ ! -f /etc/docker/daemon.json ]; then
    mkdir -p /etc/docker
    printf '%s\n' "$POOLS_DOCKER" >/etc/docker/daemon.json
    passo "Faixas de rede do Docker preparadas (até 1024 redes)"
  fi
  passo "Instalando o Docker (script oficial get.docker.com)"
  # A saída do script oficial (apt, needrestart) só aparece se der erro.
  _log_docker=$(mktemp)
  if ! curl -fsSL https://get.docker.com | sh >"$_log_docker" 2>&1; then
    tail -n 25 "$_log_docker" >&2
    erro "não consegui instalar o Docker (log acima)."
  fi
  rm -f "$_log_docker"
  tem systemctl && systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || erro "o Docker subiu sem o 'docker compose'. Instale o plugin compose e rode de novo."
}

gravar_arquivos() {
  mkdir -p "$PASTA/backups" "$PASTA/agente-local"
  chmod 700 "$PASTA" "$PASTA/agente-local"
  # A API roda como o usuário node (uid 1000) e deixa ali o token do agente desta máquina.
  chown 1000:1000 "$PASTA/agente-local"
  cat >"$PASTA/compose.yml" <<'FIM_COMPOSE_DEPANEL'
# Bsn Depanel — produção (uma máquina). Uso: docker compose --env-file .env up -d
# Um proxy só por máquina: o agente desta máquina ("Este computador") sobe o proxy de domínios, que
# publica o painel (HTTPS do Let's Encrypt) e os apps. A API fica só no 127.0.0.1:7420 (o agente local
# fala com ela por aí). Com um proxy/borda à frente (PROXY protocol), defina DEPANEL_PROXY_CONFIAVEL.
name: depanel

services:
  api:
    image: ${DEPANEL_IMAGEM:-bsn-depanel:latest}
    restart: unless-stopped
    env_file: .env
    environment:
      DEPANEL_URL: https://${DEPANEL_DOMINIO}
      DATABASE_URL: postgres://depanel:${DEPANEL_PG_SENHA}@postgres:5432/depanel
      DEPANEL_VICTORIA_URL: http://victoria:8428
      DEPANEL_HOST: 0.0.0.0
      DEPANEL_CONFIAR_PROXY: "1"
      DEPANEL_PASTA_BACKUPS_PAINEL: /backups-painel
      DEPANEL_PASTA_FONTES: /fontes
      # A máquina do painel ganha o agente local; o proxy dela publica o painel. O alvo é o nome do
      # contêiner (único), não "api": o proxy também entra nas redes dos apps, onde pode haver outro "api".
      DEPANEL_AGENTE_LOCAL: /agente-local
      DEPANEL_PAINEL_ALVO: depanel-api-1
      DEPANEL_PAINEL_REDE: depanel_default
    ports:
      - "127.0.0.1:7420:7420"
    # Os dumps do contêiner "backup" (só leitura): a tela lista, envia ao S3 e deixa baixar.
    # Pacotes de código enviados pela tela (origem "Enviar arquivo"): o agente baixa daqui para construir.
    volumes:
      - ${DEPANEL_PASTA_BACKUP:-./backups}:/backups-painel:ro
      - fontes:/fontes
      - ./agente-local:/agente-local
    depends_on:
      postgres:
        condition: service_healthy
      victoria:
        condition: service_healthy
    stop_grace_period: 20s

  worker:
    image: ${DEPANEL_IMAGEM:-bsn-depanel:latest}
    restart: unless-stopped
    command: ["node", "apps/worker/dist/principal.js"]
    env_file: .env
    environment:
      DEPANEL_URL: https://${DEPANEL_DOMINIO}
      DATABASE_URL: postgres://depanel:${DEPANEL_PG_SENHA}@postgres:5432/depanel
    healthcheck:
      disable: true
    depends_on:
      api:
        condition: service_healthy

  postgres:
    image: postgres:17.11-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: depanel
      POSTGRES_PASSWORD: ${DEPANEL_PG_SENHA}
      POSTGRES_DB: depanel
    volumes:
      - postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U depanel -d depanel"]
      interval: 10s
      timeout: 5s
      retries: 10
    shm_size: 256mb

  victoria:
    image: victoriametrics/victoria-metrics:v1.154.0
    restart: unless-stopped
    command:
      - -storageDataPath=/dados
      - -retentionPeriod=${DEPANEL_RETENCAO_METRICAS:-90d}
      - -httpListenAddr=:8428
    volumes:
      - victoria:/dados
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8428/health"]
      interval: 15s
      timeout: 5s
      retries: 5

  # Cópia diária do Postgres (formato custom), guardando os últimos N dias.
  backup:
    image: postgres:17.11-alpine
    restart: unless-stopped
    environment:
      PGHOST: postgres
      PGUSER: depanel
      PGPASSWORD: ${DEPANEL_PG_SENHA}
      PGDATABASE: depanel
      DIAS: ${DEPANEL_BACKUP_DIAS:-14}
      HORA: ${DEPANEL_BACKUP_HORA:-03}
      TZ: America/Sao_Paulo
    volumes:
      - ./backup.sh:/backup.sh:ro
      - ${DEPANEL_PASTA_BACKUP:-./backups}:/backups
    entrypoint: ["/bin/sh", "/backup.sh"]
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  postgres:
  victoria:
  fontes:
FIM_COMPOSE_DEPANEL
  # Versões antigas tinham um Traefik próprio do painel; agora o proxy é o do agente desta máquina.
  rm -rf "$PASTA/traefik"
  cat >"$PASTA/backup.sh" <<'FIM_BACKUP_DEPANEL'
#!/bin/sh
# Backup diário do banco do Depanel: pg_dump -Fc em /backups, apaga os mais velhos que $DIAS dias.
# Também roda uma cópia logo ao subir, para nunca ficar sem nenhuma.
set -eu
copiar() {
  arquivo="/backups/depanel-$(date +%Y-%m-%d_%H%M).dump"
  if pg_dump -Fc -f "$arquivo.parcial"; then
    mv "$arquivo.parcial" "$arquivo"
    echo "backup ok: $arquivo ($(du -h "$arquivo" | cut -f1))"
  else
    rm -f "$arquivo.parcial"
    echo "backup FALHOU" >&2
  fi
  find /backups -name 'depanel-*.dump' -mtime "+$DIAS" -delete
}
copiar
while true; do
  # Dorme até a próxima HORA:00.
  agora=$(date +%s)
  alvo=$(date -d "$(date +%Y-%m-%d) $HORA:00:00" +%s 2>/dev/null || echo $((agora + 86400)))
  [ "$alvo" -le "$agora" ] && alvo=$((alvo + 86400))
  sleep $((alvo - agora))
  copiar
done
FIM_BACKUP_DEPANEL
}

configurar() {
  if [ -f "$PASTA/.env" ]; then
    ATUALIZACAO=1
    passo "Instalação encontrada em $PASTA: atualizando (configuração e dados ficam)"
    # Troca só a imagem; o resto da configuração continua como estava.
    _img="${IMAGEM:-$IMAGEM_PADRAO}"
    if grep -q '^DEPANEL_IMAGEM=' "$PASTA/.env"; then
      sed -i "s|^DEPANEL_IMAGEM=.*|DEPANEL_IMAGEM=${_img}|" "$PASTA/.env"
    else
      printf 'DEPANEL_IMAGEM=%s\n' "$_img" >>"$PASTA/.env"
    fi
    # Instalações antigas: a pasta passa a constar (a atualização pelo painel usa).
    grep -q '^DEPANEL_PASTA_INSTALACAO=' "$PASTA/.env" || printf 'DEPANEL_PASTA_INSTALACAO=%s\n' "$PASTA" >>"$PASTA/.env"
    DOMINIO=$(sed -n 's/^DEPANEL_DOMINIO=//p' "$PASTA/.env")
    return
  fi
  ATUALIZACAO=0
  if [ -z "$DOMINIO" ]; then
    _ip=$(ip_publico)
    _sugerido="$(printf '%s' "${_ip:-127.0.0.1}" | tr '.' '-').sslip.io"
    DOMINIO=$(perguntar "Endereço do painel (aponte o DNS para esta máquina)" "$_sugerido")
  fi
  [ -n "$EMAIL" ] || EMAIL=$(perguntar "Seu e-mail (avisos do certificado HTTPS do Let's Encrypt; pode deixar vazio)" "")
  passo "Gerando os segredos"
  umask 077
  cat >"$PASTA/.env" <<FIM_ENV
# Bsn Depanel — gerado pelo instalador $VERSAO em $(date '+%d/%m/%Y %H:%M'). GUARDE uma cópia de DEPANEL_CHAVES_MESTRAS:
# sem ela os segredos guardados no painel não abrem.
DEPANEL_DOMINIO=$DOMINIO
DEPANEL_ACME_EMAIL=$EMAIL
DEPANEL_IMAGEM=${IMAGEM:-$IMAGEM_PADRAO}
DEPANEL_PASTA_INSTALACAO=$PASTA
DEPANEL_PROXY_CONFIAVEL=$BORDA
DEPANEL_PG_SENHA=$(aleatorio_hex 24)
DEPANEL_CHAVES_MESTRAS=v1:$(aleatorio_b64 32)
DEPANEL_SEGREDO_SESSAO=$(aleatorio_hex 32)
DEPANEL_LOG_NIVEL=info
DEPANEL_RETENCAO_METRICAS=90d
DEPANEL_BACKUP_DIAS=14
DEPANEL_BACKUP_HORA=03
DEPANEL_PASTA_BACKUP=./backups
# Login por OIDC (opcional; ex.: BSN Auth, Keycloak, Authentik):
# DEPANEL_OIDC_EMISSOR=https://auth.exemplo.com.br/oidc
# DEPANEL_OIDC_CLIENT_ID=bsn-depanel
# DEPANEL_OIDC_CLIENT_SECRET=
FIM_ENV
  chmod 600 "$PASTA/.env"
}

obter_imagem() {
  if [ -n "$IMAGEM_ARQUIVO" ]; then
    [ -f "$IMAGEM_ARQUIVO" ] || erro "arquivo da imagem não encontrado: $IMAGEM_ARQUIVO"
    passo "Carregando a imagem de $IMAGEM_ARQUIVO"
    docker load -i "$IMAGEM_ARQUIVO" >/dev/null
  fi
  passo "Baixando as imagens"
  (cd "$PASTA" && docker compose --env-file .env pull --ignore-pull-failures --quiet 2>/dev/null) || true
  _img=$(sed -n 's/^DEPANEL_IMAGEM=//p' "$PASTA/.env")
  docker image inspect "$_img" >/dev/null 2>&1 ||
    erro "a imagem $_img não está disponível. Use --imagem-arquivo depanel.tar ou --imagem <registro/imagem:versão>."
}

subir() {
  if [ "$ATUALIZACAO" = 0 ]; then
    for _p in 80 443; do
      porta_ocupada "$_p" && erro "a porta $_p já está em uso nesta máquina (outro proxy/painel?). Libere-a e rode de novo."
    done
  fi
  passo "Subindo o Depanel"
  _saida=$(cd "$PASTA" && docker compose --env-file .env up -d --remove-orphans 2>&1) ||
    { printf '%s\n' "$_saida" >&2; erro "o docker compose não conseguiu subir (detalhes acima)."; }
  passo "Esperando o painel ficar pronto"
  _i=0
  while :; do
    _api=$(cd "$PASTA" && docker compose --env-file .env ps -q api 2>/dev/null)
    _saude=$(docker inspect --format '{{.State.Health.Status}}' "$_api" 2>/dev/null || echo "")
    [ "$_saude" = healthy ] && break
    _i=$((_i + 1))
    [ "$_i" -lt 90 ] || { (cd "$PASTA" && docker compose --env-file .env logs --tail 40 api) >&2 || true; erro "o painel não ficou pronto em 3 minutos (log acima)."; }
    sleep 2
  done
}

# Primeiro acesso: o painel novo gera um código de uso único (na pasta agente-local) e quem abre o link
# cria a conta de administrador pela tela. Para automação, DEPANEL_ADMIN_EMAIL + DEPANEL_ADMIN_SENHA
# no ambiente criam o dono aqui mesmo, sem tela.
primeiro_acesso() {
  CODIGO=""
  if [ -n "${DEPANEL_ADMIN_EMAIL:-}" ] && [ -n "${DEPANEL_ADMIN_SENHA:-}" ] && [ "$ATUALIZACAO" = 0 ]; then
    passo "Criando o dono ($DEPANEL_ADMIN_EMAIL)"
    (cd "$PASTA" && docker compose --env-file .env exec -T -e DEPANEL_ADMIN_EMAIL -e DEPANEL_ADMIN_SENHA \
      -e DEPANEL_ADMIN_NOME="${DEPANEL_ADMIN_NOME:-Dono}" -e DEPANEL_ORG_NOME="${DEPANEL_ORG_NOME:-Minha organização}" \
      api node apps/api/dist/criar-admin.js >/dev/null) || erro "não consegui criar o dono (veja: docker compose logs api)."
    return
  fi
  _i=0
  # Sem o arquivo: o painel já tem dono (atualização) ou ainda está gravando; espera um pouco.
  until [ -s "$PASTA/agente-local/primeiro-acesso" ]; do
    _i=$((_i + 1))
    [ "$_i" -lt 10 ] || return 0
    sleep 1
  done
  CODIGO=$(tr -d '[:space:]' <"$PASTA/agente-local/primeiro-acesso")
}

# O agente desta máquina ("Este computador"): cuida do Docker daqui e sobe o proxy, que publica o painel
# com HTTPS. O painel cria a máquina e o token na 1ª subida (antes do dono); o agente fala com a API pelo
# 127.0.0.1 (o proxy ainda não existe na primeira vez).
instalar_agente_local() {
  if [ -f /etc/depanel-agente/agente.env ]; then
    # Já tem agente (pode ser de outro painel): não mexe. O painel publica a si mesmo pelo proxy do
    # agente "Este computador"; com outro agente aqui, publique o painel pela tela ou pela borda.
    aviso "esta máquina já tem um agente do Depanel; ele foi mantido como está."
    return
  fi
  passo "Instalando o agente desta máquina"
  _i=0
  until [ -s "$PASTA/agente-local/token" ]; do
    _i=$((_i + 1))
    [ "$_i" -lt 30 ] || { aviso "o painel não preparou o agente local; adicione esta máquina pela tela (Máquinas → Adicionar)."; return; }
    sleep 2
  done
  _token=$(cat "$PASTA/agente-local/token")
  curl -fsS http://127.0.0.1:7420/agente/instalar.sh |
    DEPANEL_TOKEN="$_token" DEPANEL_PAINEL=http://127.0.0.1:7420 sh >/dev/null ||
    { aviso "não consegui instalar o agente desta máquina (veja: journalctl -u depanel-agente)."; return; }
  passo "Esperando o proxy desta máquina publicar o painel"
  _i=0
  # -k: aqui só confere a rota; o certificado do Let's Encrypt sai sozinho quando o DNS apontar para cá.
  until curl -kfsS --max-time 5 --resolve "$DOMINIO:443:127.0.0.1" "https://$DOMINIO/saude" >/dev/null 2>&1; do
    _i=$((_i + 1))
    [ "$_i" -lt 60 ] || { aviso "o proxy ainda não publicou o painel (veja Máquinas → Este computador no 127.0.0.1:7420 por um túnel SSH)."; return; }
    sleep 3
  done
}

resumo() {
  printf '\n%s\n\n' "$(cor '1;32' "Bsn Depanel $VERSAO pronto.")"
  printf '  Painel:  https://%s\n' "$DOMINIO"
  if [ -n "$CODIGO" ]; then
    printf '\n  %s\n' "$(cor '1;33' 'Crie a conta de administrador (só funciona uma vez):')"
    printf '    https://%s/primeiro-acesso#%s\n' "$DOMINIO" "$CODIGO"
    printf '    (o código também está em %s/agente-local/primeiro-acesso)\n\n' "$PASTA"
  fi
  printf '  Pasta:   %s (configuração em .env, backups diários em backups/)\n' "$PASTA"
  printf '\n  Esta máquina já aparece em Máquinas ("Este computador"): crie apps, bancos e domínios nela.\n'
  printf '  Outras máquinas: no painel, Máquinas → Adicionar → copie o comando do agente.\n'
  printf '  Atualizar: rode o mesmo comando de instalação de novo.\n'
  case "$DOMINIO" in
    *.sslip.io) ;;
    *) printf '  DNS: o domínio %s precisa apontar para esta máquina para o HTTPS sair.\n' "$DOMINIO" ;;
  esac
  if tem ufw && ufw status 2>/dev/null | grep -q 'Status: active'; then
    printf '  Firewall: libere as portas com "ufw allow 80,443/tcp".\n'
  fi
  printf '\n'
}

principal() {
  ler_opcoes "$@"
  if [ "$CASA" = 1 ]; then instalar_casa; return; fi
  conferir_sistema
  passo "Bsn Depanel $VERSAO — instalando em $PASTA"
  instalar_docker
  gravar_arquivos
  configurar
  obter_imagem
  subir
  primeiro_acesso
  instalar_agente_local
  resumo
}

principal "$@"
