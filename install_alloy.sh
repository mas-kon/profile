#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Установка и настройка Grafana Alloy на новом хосте
# Использование: sudo GCLOUD_RW_API_KEY=xxx ./install-alloy.sh
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Запусти через sudo: sudo GCLOUD_RW_API_KEY=xxx $0"
  exit 1
fi

if [[ -z "${GCLOUD_RW_API_KEY:-}" ]]; then
  echo "Нужно передать GCLOUD_RW_API_KEY, например:"
  echo "  sudo GCLOUD_RW_API_KEY=glc_xxxxx ./install-alloy.sh"
  exit 1
fi

HOSTNAME_ID=$(hostname)
echo ">> Хост: ${HOSTNAME_ID}"

# --- 1. Установка Alloy (если ещё не установлен) ---
if ! command -v alloy &>/dev/null; then
  echo ">> Устанавливаю Alloy..."
  sudo apt-get install -y gpg
  sudo mkdir -p /etc/apt/keyrings/
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
  sudo apt-get update
  sudo apt-get install -y alloy
else
  echo ">> Alloy уже установлен, пропускаю установку"
fi

# --- 2. Добавляем alloy в группу docker (на всякий случай, хотя запускаем от root) ---
usermod -aG docker alloy 2>/dev/null || true

# --- 3. Пишем config.alloy ---
echo ">> Записываю /etc/alloy/config.alloy"
cat > /etc/alloy/config.alloy << 'EOF'
logging {
  level = "info"
}

remotecfg {
  url            = "https://fleet-management-prod-011.grafana.net"
  id             = constants.hostname
  poll_frequency = "60s"
  attributes     = encoding.from_json(coalesce(``, `{}`))
  basic_auth {
    username = "665961"
    password = sys.env("GCLOUD_RW_API_KEY")
  }
}

prometheus.remote_write "metrics_service" {
  endpoint {
    url = "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
    basic_auth {
      username = "1034241"
      password = sys.env("GCLOUD_RW_API_KEY")
    }
  }
}

loki.write "grafana_cloud_loki" {
  endpoint {
    url = "https://logs-prod-012.grafana.net/loki/api/v1/push"
    basic_auth {
      username = "619014"
      password = sys.env("GCLOUD_RW_API_KEY")
    }
  }
}

prometheus.exporter.unix "host" {
  set_collectors = [
    "cpu",
    "meminfo",
    "filesystem",
    "netdev",
    "loadavg",
  ]
  filesystem {
    fs_types_exclude     = "^(autofs|binfmt_misc|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|sysfs|tracefs)$"
    mount_points_exclude = "^/(dev|proc|sys|var/lib/docker/.+)($|/)"
  }
}

prometheus.scrape "host_metrics" {
  targets         = prometheus.exporter.unix.host.targets
  forward_to      = [prometheus.remote_write.metrics_service.receiver]
  scrape_interval = "60s"
}

prometheus.exporter.cadvisor "docker" {
  docker_only = true
}

discovery.relabel "cadvisor_containers" {
  targets = prometheus.exporter.cadvisor.docker.targets
  rule {
    target_label = "job"
    replacement  = "integrations/docker"
  }
}

prometheus.scrape "container_metrics" {
  targets         = discovery.relabel.cadvisor_containers.output
  forward_to      = [prometheus.relabel.cadvisor_filter.receiver]
  scrape_interval = "60s"
}

prometheus.relabel "cadvisor_filter" {
  forward_to = [prometheus.remote_write.metrics_service.receiver]

  rule {
    source_labels = ["__name__"]
    regex         = "container_(cpu|memory|network|blkio)_.*"
    action        = "keep"
  }
  rule {
    action = "labeldrop"
    regex  = "container_label_com_docker_compose_config_hash|container_label_com_docker_compose_image|container_label_com_docker_compose_project_config_files|container_label_com_docker_compose_project_working_dir"
  }
  rule {
    source_labels = ["container_label_com_docker_compose_project"]
    regex         = ""
    action        = "drop"
  }
}

discovery.docker "containers" {
  host             = "unix:///var/run/docker.sock"
  refresh_interval = "15s"
}

discovery.relabel "docker_logs" {
  targets = []
  rule {
    target_label = "job"
    replacement  = constants.hostname
  }
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
}

loki.source.docker "containers" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.containers.targets
  relabel_rules = discovery.relabel.docker_logs.rules
  forward_to    = [loki.write.grafana_cloud_loki.receiver]
}
EOF

# --- 4. systemd env override: API key + collector ID для Fleet Management ---
echo ">> Настраиваю systemd override (env + root)"
mkdir -p /etc/systemd/system/alloy.service.d
cat > /etc/systemd/system/alloy.service.d/env.conf << EOF
[Service]
Environment=GCLOUD_RW_API_KEY=${GCLOUD_RW_API_KEY}
Environment=GCLOUD_FM_COLLECTOR_ID=${HOSTNAME_ID}
EOF

cat > /etc/systemd/system/alloy.service.d/override.conf << 'EOF'
[Service]
User=root
Group=root
EOF

# --- 5. Запуск ---
echo ">> Перезапускаю Alloy"
systemctl daemon-reload
systemctl enable alloy
systemctl restart alloy

sleep 3
systemctl status alloy --no-pager || true

echo ""
echo ">> Готово. Проверь:"
echo "   curl http://localhost:12345/-/ready"
echo "   и в Grafana Cloud Explore: node_uname_info{instance=\"${HOSTNAME_ID}\"}"
