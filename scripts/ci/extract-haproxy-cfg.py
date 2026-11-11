"""Extract haproxy.cfg from a rendered manifest stream so it can be checked with
`haproxy -c`. Substitutes the REPLACE_ANNOUNCE<i> placeholders the chart's
haproxy_init.sh would fill in at runtime.

usage: extract-haproxy-cfg.py <rendered.yaml> <out.cfg>
"""
import pathlib
import sys

import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8-sig")) if d]
cms = [d for d in docs if d.get("kind") == "ConfigMap" and "haproxy.cfg" in (d.get("data") or {})]
if not cms:
    sys.exit("no ConfigMap with haproxy.cfg found")
cfg = cms[0]["data"]["haproxy.cfg"]
for i in range(16):
    cfg = cfg.replace(f"REPLACE_ANNOUNCE{i}", f"10.0.0.{i + 1}")
pathlib.Path(sys.argv[2]).write_text(cfg, encoding="utf-8", newline="\n")
