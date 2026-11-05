#!/usr/bin/env python3
"""Integration test on disposable PostgreSQL 18 primary/standby; requires Docker + PyYAML.
No host ports, production credentials or production database connections are used.
"""
import json
from pathlib import Path
import re
import subprocess
import time
import uuid
import yaml

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / 'configs/postgres/sql-exporter.yml'
RUN = 'pg-monitor-test-' + uuid.uuid4().hex[:10]
PRIMARY, STANDBY = RUN + '-primary', RUN + '-standby'
containers = []
network_created = False


def docker(*args, input=None, check=True):
    return subprocess.run(['docker', *args], input=input, text=True, capture_output=True,
                          check=check).stdout.strip()


def start(name, *args):
    containers.append(name)
    return docker('run', '-d', '--name', name, '--network', RUN, *args)


def sql(target, query, monitor=False):
    return docker('exec', target, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1',
                  '-U', 'observability_monitor' if monitor else 'postgres',
                  '-d', 'postgres', '-c', query)


def wait_for(fn, message, timeout=60):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            last = fn()
            if last:
                return last
        except (subprocess.CalledProcessError, ValueError) as exc:
            last = str(exc)
        time.sleep(0.5)
    raise AssertionError(f'{message}: {last}')


def query_metrics(target):
    result = {}
    for metric in yaml.safe_load(CONFIG.read_text())['collectors'][0]['metrics']:
        raw = sql(target, 'SELECT row_to_json(q) FROM (' + metric['query'] + ') q', monitor=True)
        result[metric['metric_name']] = [json.loads(row) for row in raw.splitlines()]
    return result


def value(metrics, name):
    return max((float(row['value']) for row in metrics[name]), default=0)


def async_sql(query):
    # psql process stays connected inside the disposable primary until terminated below.
    return subprocess.Popen(['docker', 'exec', PRIMARY, 'psql', '-X', '-qAt', '-v',
                             'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres', '-c', query],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


workers = []
try:
    docker('network', 'create', '--internal', RUN)
    network_created = True
    start(PRIMARY, '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', 'postgres:18-alpine')
    wait_for(lambda: docker('exec', PRIMARY, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'), 'primary TCP startup')
    wait_for(lambda: sql(PRIMARY, 'SELECT 1') == '1', 'primary SQL startup')
    role_sql = (ROOT / 'scripts/postgres-monitoring-role.sql').read_text().split('\\password')[0]
    sql(PRIMARY, role_sql)
    assert sql(PRIMARY, 'SHOW default_transaction_read_only', monitor=True) == 'on'
    sql(PRIMARY, 'CREATE TABLE monitor_test (id int PRIMARY KEY, value int); '
                 'INSERT INTO monitor_test VALUES (1,0), (2,0);')
    docker('exec', PRIMARY, 'sh', '-c',
           'printf "host replication postgres all trust\\n" >> "$PGDATA/pg_hba.conf"')
    sql(PRIMARY, 'SELECT pg_reload_conf()')
    start(STANDBY, '--user', 'postgres', '--entrypoint', 'sh', 'postgres:18-alpine', '-ec',
          f'pg_basebackup -d "host={PRIMARY} user=postgres application_name=monitor-test-replica" '
          '-D /tmp/standby-data -R -X stream -C -S monitor_test_replica; '
          'exec postgres -D /tmp/standby-data')
    wait_for(lambda: sql(STANDBY, 'SELECT pg_is_in_recovery()') == 't', 'standby startup')
    wait_for(lambda: sql(PRIMARY, "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'") == '1',
             'streaming replication')
    for target, primary in [(PRIMARY, 1), (STANDBY, 0)]:
        metrics = query_metrics(target)
        assert value(metrics, 'pg_internal_primary') == primary
        assert value(metrics, 'pg_internal_connection_limit') > 0
        assert value(metrics, 'pg_internal_blocked_sessions') == 0
        assert value(metrics, 'pg_internal_oldest_transaction_seconds') == 0
        assert value(metrics, 'pg_internal_wal_receiver_streaming') == 1 - primary
        print(f'PASS: all SQL queries with pg_monitor privileges on {target}', flush=True)

    # Pin both tested images to the versions deployed in the manifests.
    exporter_image = re.search(r'image: (burningalchemist/sql_exporter:[^\s]+)',
                               (ROOT / 'kube/postgres-exporter.yaml').read_text())[1]
    for target in [PRIMARY, STANDBY]:
        name = target + '-exporter'
        containers.append(name)
        docker('create', '--name', name, '--network', RUN,
               '-e', f'SQLEXPORTER_TARGET_DSN=postgresql://observability_monitor@{target}:5432/postgres?sslmode=disable&application_name=observability-postgres',
               exporter_image, '-config.file=/tmp/sql-exporter.yml')
        docker('cp', str(CONFIG), name + ':/tmp/sql-exporter.yml')
        docker('start', name)
        body = wait_for(lambda: docker('exec', name, 'wget', '-qO-', 'http://localhost:9399/metrics'),
                        'exporter scrape')
        assert 'pg_internal_primary ' + ('1' if target == PRIMARY else '0') in body
        assert 'pg_internal_connection_limit ' in body
        print(f'PASS: real exporter HTTP scrape on {target}', flush=True)

    holder = async_sql("SET application_name='monitor-test-holder'; BEGIN; "
                       "UPDATE monitor_test SET value=1 WHERE id=1; SELECT pg_sleep(60);")
    workers.append(holder)
    wait_for(lambda: sql(PRIMARY, "SELECT count(*) FROM pg_stat_activity WHERE application_name='monitor-test-holder' AND wait_event='PgSleep'") == '1', 'lock holder')
    waiter = async_sql("SET application_name='monitor-test-waiter'; UPDATE monitor_test SET value=2 WHERE id=1;")
    workers.append(waiter)
    wait_for(lambda: value(query_metrics(PRIMARY), 'pg_internal_blocked_sessions') == 1, 'blocked session')
    time.sleep(1)
    metrics = query_metrics(PRIMARY)
    assert value(metrics, 'pg_internal_oldest_lock_wait_seconds') > 0.5
    assert value(metrics, 'pg_internal_oldest_transaction_seconds') > 0.5
    sql(PRIMARY, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name LIKE 'monitor-test-%'")
    for worker in workers:
        worker.communicate(timeout=10)
    print('PASS: blocked session, actual lock wait and long transaction', flush=True)

    first = async_sql("BEGIN; UPDATE monitor_test SET value=3 WHERE id=1; SELECT pg_sleep(2); UPDATE monitor_test SET value=3 WHERE id=2; COMMIT;")
    second = async_sql("BEGIN; UPDATE monitor_test SET value=4 WHERE id=2; SELECT pg_sleep(2); UPDATE monitor_test SET value=4 WHERE id=1; COMMIT;")
    workers.extend([first, second])
    first.communicate(timeout=15)
    second.communicate(timeout=15)
    assert (first.returncode == 0) != (second.returncode == 0), 'Exactly one deadlocked transaction must fail'
    wait_for(lambda: value(query_metrics(PRIMARY), 'pg_internal_deadlocks_total') >= 1, 'deadlock counter')
    print('PASS: real deadlock detected', flush=True)

    sql(PRIMARY, "SELECT pg_create_physical_replication_slot('monitor_test_idle', true)")
    sql(STANDBY, 'SELECT pg_wal_replay_pause()')
    sql(PRIMARY, 'CREATE TABLE monitor_test_wal AS SELECT i, repeat(md5(i::text), 8) AS data FROM generate_series(1, 10000) i;')
    sql(PRIMARY, 'SELECT pg_switch_wal()')
    wait_for(lambda: value(query_metrics(PRIMARY), 'pg_internal_replication_replay_lag_bytes') > 0, 'replication backlog')
    assert value(query_metrics(PRIMARY), 'pg_internal_slot_retained_wal_bytes') > 0
    print('PASS: replication backlog and retained WAL', flush=True)
    sql(STANDBY, 'SELECT pg_wal_replay_resume()')
    docker('stop', '-t', '2', STANDBY)
    wait_for(lambda: value(query_metrics(PRIMARY), 'pg_internal_streaming_replicas') == 0, 'disconnected replica')
    print('PASS: disconnected replica detected independently of lag series', flush=True)
    docker('stop', '-t', '2', PRIMARY)
    # The readiness/liveness endpoint stays healthy; SQL collection must fail.
    assert docker('exec', PRIMARY + '-exporter', 'wget', '-qO-', 'http://localhost:9399/')
    failed_scrape = subprocess.run(['docker', 'exec', PRIMARY + '-exporter', 'wget', '-qO-',
                                   'http://localhost:9399/metrics'], capture_output=True)
    assert failed_scrape.returncode != 0, 'DB failure must fail Prometheus scrape'
    print('PASS: database outage fails metrics scrape without failing HTTP health probe', flush=True)
finally:
    for worker in workers:
        if worker.poll() is None:
            worker.terminate()
    for container in reversed(containers):
        docker('rm', '-f', '-v', container, check=False)
    if network_created:
        docker('network', 'rm', RUN, check=False)
