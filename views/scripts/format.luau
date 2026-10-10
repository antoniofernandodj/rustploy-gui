--!strict
-- format.luau — fachada: reexporta os builders de views/scripts/fmt_*.luau sob um
-- único módulo, para os handlers seguirem fazendo `local format = require("format")`
-- + `format.foo(...)` sem precisar saber em qual submódulo cada builder mora.
-- Reimplementação Luau de `src/app/net/view.rs` (Rust pré-migração).

local Time = require("format/time")
local Util = require("format/util")
local Dashboard = require("format/dashboard")
local ServiceDetail = require("format/service_detail")
local Git = require("format/git")
local Jobs = require("format/jobs")
local Registry = require("format/registry")
local DockerCleanup = require("format/docker_cleanup")

local M = {}

-- Tempo / números (format/time.luau)
M.time_hms = Time.time_hms
M.date_day_month_hour_minute = Time.date_day_month_hour_minute
M.date_day_month_hour_minute_second = Time.date_day_month_hour_minute_second
M.format_seconds = Time.format_seconds
M.format_uptime = Time.format_uptime
M.format_bytes = Time.format_bytes
M.hour_minute_join = Time.hour_minute_join
M.hour_minute_split = Time.hour_minute_split
M.WEEKDAYS_JSON = Time.WEEKDAYS_JSON

-- Busca / codificação / estado (format/util.luau)
M.matches = Util.matches
M.ellipsis = Util.ellipsis
M.short_reason = Util.short_reason
M.encode_array = Util.encode_array
M.status_label_color = Util.status_label_color
M.service_pair_list = Util.service_pair_list

-- Dashboard: deployments/projects/services/docker/ingress/monitoring/engine
-- (format/dashboard.luau)
M.deployments = Dashboard.deployments
M.services = Dashboard.services
M.service_rows = Dashboard.service_rows
M.projects = Dashboard.projects
M.project_rows = Dashboard.project_rows
M.docker_rows = Dashboard.docker_rows
M.docker_containers = Dashboard.docker_containers
M.docker_images = Dashboard.docker_images
M.docker_volumes = Dashboard.docker_volumes
M.docker_networks = Dashboard.docker_networks
M.ingress = Dashboard.ingress
M.host_ports = Dashboard.host_ports
M.monitoring = Dashboard.monitoring
M.deploy_engine_active = Dashboard.deploy_engine_active
M.deploy_engine_detail = Dashboard.deploy_engine_detail
M.deploy_engine_detail_steps = Dashboard.deploy_engine_detail_steps
M.deploy_engine_queued = Dashboard.deploy_engine_queued
M.deploy_engine_recent = Dashboard.deploy_engine_recent

-- Service detail: source/healthcheck/env/logs/deployments/domains/connection
-- (fmt_service_detail.luau)
M.source_summary_parts = ServiceDetail.source_summary_parts
M.healthcheck_summary = ServiceDetail.healthcheck_summary
M.env_json_with_comments = ServiceDetail.env_json_with_comments
M.secret_rows = ServiceDetail.secret_rows
M.env_dotenv_with_comments = ServiceDetail.env_dotenv_with_comments
M.logs_json = ServiceDetail.logs_json
M.build_logs_json = ServiceDetail.build_logs_json
M.join_log_lines = ServiceDetail.join_log_lines
M.deployments_detail = ServiceDetail.deployments_detail
M.domains_json = ServiceDetail.domains_json
M.safe_name = ServiceDetail.safe_name
M.internal_url = ServiceDetail.internal_url
M.compose_host = ServiceDetail.compose_host
M.external_url = ServiceDetail.external_url
M.containers = ServiceDetail.containers

-- Git providers/repos/branches (format/git.luau)
M.git_providers = Git.git_providers
M.git_repos = Git.git_repos
M.git_branches = Git.git_branches

-- Jobs one-shot (format/jobs.luau)
M.job_recurrence_label = Jobs.recurrence_label
M.job_summaries = Jobs.summaries
M.job_runs = Jobs.runs
M.pre_deploy_queue = Jobs.pre_deploy_queue
M.pre_deploy_available = Jobs.pre_deploy_available

-- Limpeza automática de Docker (format/docker_cleanup.luau)
M.docker_cleanup_resource_label = DockerCleanup.resource_label
M.docker_cleanup_last_run_summary = DockerCleanup.last_run_summary

-- Registry OCI embutido (format/registry.luau)
M.registry_repos = Registry.repos
M.registry_tags = Registry.tags
M.registry_tokens = Registry.tokens

return M
