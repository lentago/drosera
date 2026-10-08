"""CLI: ``python3 -m pipeline_producer [--config PATH] [--once] [--no-push] [--out PATH|-]``.

Without ``--once`` it runs as the long-lived service: a compute loop every
``--interval`` and the HTTP server on ``listen:port``. ``--once`` computes one
document, writes it to ``--out`` and exits 1 if the Loki read failed.
"""

import argparse
import logging
import signal
import sys
import threading

from .config import DEFAULT_CONFIG_PATH, Config, ConfigError, load_secrets
from .loki import LokiPusher, LokiReader
from .producer import Producer, make_server


def main(argv=None):
    parser = argparse.ArgumentParser(prog="pipeline_producer", description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG_PATH)
    parser.add_argument("--check-config", action="store_true",
                        help="validate the config file and exit (no secrets, no network)")
    parser.add_argument("--once", action="store_true", help="compute one document and exit")
    parser.add_argument("--no-push", action="store_true",
                        help="don't write change_pipeline_state back to Loki (dry run)")
    parser.add_argument("--out", help="also write each document to PATH ('-' = stdout)")
    parser.add_argument("--interval", help="override the config interval, e.g. 30s")
    parser.add_argument("--window", help="override the config window, e.g. 24h")
    parser.add_argument("--port", type=int, help="override the config port")
    args = parser.parse_args(argv)
    # Logs go to stderr so `--once --out -` leaves stdout as clean JSON.
    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="[drosera-pipeline] %(levelname)s %(message)s")
    log = logging.getLogger("drosera-pipeline")

    try:
        cfg = Config.load(args.config).with_overrides(args.interval, args.window)
        if args.check_config:
            log.info("config OK: interval %s, window %s, %s:%d, cluster %s, %d terraform repo(s)",
                     cfg.interval, cfg.window, cfg.listen, cfg.port, cfg.cluster, len(cfg.terraform_repos))
            return 0
        secrets = load_secrets(push=not args.no_push)
    except ConfigError as exc:
        log.error("%s", exc)
        return 1

    reader = LokiReader(secrets["DROSERA_LOKI_URL"], secrets["DROSERA_LOKI_USER"], secrets["DROSERA_LOKI_TOKEN"])
    pusher = None if args.no_push else LokiPusher(
        secrets["GRAFANA_CLOUD_LOGS_URL"], secrets["GRAFANA_CLOUD_LOGS_USER"], secrets["GRAFANA_CLOUD_LOGS_TOKEN"])
    producer = Producer(cfg, reader, pusher, out=args.out)

    if args.once:
        return 0 if producer.tick() is not None else 1

    server = make_server(producer, cfg.listen, args.port or cfg.port)
    threading.Thread(target=server.serve_forever, name="http", daemon=True).start()
    log.info("serving on %s:%d, computing every %s over %s%s", cfg.listen, server.server_address[1],
             cfg.interval, cfg.window, " (no push)" if args.no_push else "")
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    producer.run(stop)
    server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
