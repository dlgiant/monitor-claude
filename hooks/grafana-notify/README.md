# Grafana → desktop notifier

Tiny webhook receiver that turns Grafana alert deliveries into local
`notify-send` desktop popups. Bridges Grafana OSS (which has no native
"shell command" contact point) and your Linux desktop session.

## Run

```bash
./run.sh
```

Backgrounds the receiver, logs to `/tmp/grafana-notify.log`, and survives
shell exit (`disown`). To stop: `pkill -f notify-receiver.py`.

## How it's wired

- `grafana/provisioning/alerting/contact-points.yaml` defines a `webhook`
  contact point at `http://host.docker.internal:5678/grafana-webhook`.
- `docker-compose.yml` adds `extra_hosts: host.docker.internal:host-gateway`
  to the grafana service so the container can reach the host.
- The receiver binds `0.0.0.0:5678` with a peer-IP allowlist (`127.*`, `172.*`)
  so only loopback and docker-bridge sources can post.

## Alert that fires this

`grafana/provisioning/alerting/rules.yaml` defines:

```
topk(1, sum by (prompt_id) (count_over_time({service_name="claude-code"}
                                              | event_name = `api_request` [5m])))
```

with threshold `> 15` for 1 minute. Fires when any active prompt has
accumulated 15+ API requests in a 5-minute window — the live-running
counterpart to the dashboard's stuck-turn detector table.

## Add other channels

Edit `grafana/provisioning/alerting/contact-points.yaml` to add Slack,
Discord, email, etc. Update `policies.yaml` to route specific alerts
elsewhere.
